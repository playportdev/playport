# SPDX-License-Identifier: GPL-3.0-or-later
"""What every device driver and `pp` share: the socket, the device lock, the
installed app, and a stream of structured events.

Events. A driver reports progress as JSON objects, one per line, on stdout and
in <out>/events.jsonl: {"t": <unix time>, "event": "<name>", ...}. The last
line is always {"event": "result", "ok": ..., "exit": ...}. An agent runs a
driver in the background (or under Monitor) and acts on the lines; it never
needs to poll files or sleep.

The lock. One job drives the phone at a time: an exclusive flock on
DEVICE_DIR/device.lock. DEVICE_DIR ($PLAYPORT_DEVICE_DIR, default the build
area, .work) holds the one lock and the one install record: every job on this
machine, a pp sync candidate's included, shares them. The
holder writes device.holder.json beside it (pid, what, cmd, checkout, session,
since, and expected_end when the job knows its length), so a waiter prints who
it waits for, then blocks in the kernel until the lock is free (no polling),
repeating its lock-wait event every LOCK_WAIT_EVERY_S with the time waited. A
holder exports PLAYPORT_DEVICE_LOCK_HELD=1 and its PLAYPORT_DEVICE_SESSION, so
the tools it starts (pp install, the drivers) use its lock instead of waiting
for themselves; a HELD claim whose session is not the live holder's is ignored.

The session. One hold of the lock is one session: `pp phone lock -- CMD`
makes everything CMD runs one session. The UI driver passes the session to the
app (UI_SESSION), and the app undoes the settings driven runs changed
(set:, hud:, --settings) at its first launch outside that session
(app/Sources/S1Probe/Dev/DriverUndo.swift), so the next session starts from
the settings a person left.

The install record. DEVICE_DIR/device-state.json says which IPA `pp install`
put on the phone, from which checkout. `pp ui` refuses to drive a build
another checkout installed (installed_check).

The app. The one XTL-<team>.dev.playport.app on the phone; no other
bundle ID is ever driven. The app writes Documents/run-events.jsonl during a
driven launch (app/Sources/S1Probe/Dev/RunEvents.swift): marks such as
`first frame`, UI actions, and the done line.
"""

import contextlib
import datetime
import fcntl
import glob
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
BUILD = os.environ.get("PLAYPORT_BUILD") or os.path.join(REPO, ".work")
sys.path.insert(0, os.path.join(REPO, "build"))
import inputs  # noqa: E402

# netmuxd's socket (pp setup records it; build/install reads the same variable).
SOCK = inputs.get("PLAYPORT_USBMUX_SOCKET")
DEVICE_DIR = os.environ.get("PLAYPORT_DEVICE_DIR") or str(inputs.BUILD)  # as inputs.DEVICE_DIR
LOCK = os.environ.get("PLAYPORT_DEVICE_LOCK") or os.path.join(DEVICE_DIR, "device.lock")
HOLDER = os.path.join(os.path.dirname(LOCK), "device.holder.json")
STATE = os.path.join(DEVICE_DIR, "device-state.json")
BID_RE = re.compile(r"^XTL-[A-Z0-9]+\.dev\.playport\.app$")
PLACEHOLDER_BID = "XTL-TEAMIDXXXX.dev.playport.app"
EXECUTABLES = ("S1Probe", "Playport")


class PhoneError(RuntimeError):
    """A device step failed; the message says what to do."""


def pmd_env():
    if not SOCK:
        raise PhoneError("PLAYPORT_USBMUX_SOCKET is not set: run ./pp setup")
    return dict(os.environ, USBMUXD_SOCKET_ADDRESS=SOCK)


def pmd_python():
    """pymobiledevice3's own Python: the interpreter its launcher on PATH names."""
    exe = shutil.which("pymobiledevice3")
    if not exe:
        raise PhoneError("pymobiledevice3 is not on PATH (docs/DEVICE.md)")
    with open(exe, "rb") as f:
        line = f.readline()
    if not line.startswith(b"#!"):
        raise PhoneError(f"{exe} has no #! line naming its Python")
    return shlex.split(line[2:].decode())[0]


class Events:
    """JSON lines to stdout (echo) and to <out>/events.jsonl."""

    def __init__(self, out=None, echo=True):
        self.path = os.path.join(out, "events.jsonl") if out else None
        self.echo = echo
        self.t0 = time.time()

    def __call__(self, event, **fields):
        o = {"t": round(time.time(), 3), "event": event, **fields}
        line = json.dumps(o, sort_keys=False)
        if self.path:
            with open(self.path, "a") as f:
                f.write(line + "\n")
        if self.echo:
            print(line, flush=True)
        return o

    def result(self, ok, exit_code, **fields):
        self("result", ok=ok, exit=exit_code, **fields)
        return exit_code


def holder():
    """The current holder record, with "alive" (its pid runs), or None."""
    try:
        with open(HOLDER) as f:
            h = json.load(f)
    except (OSError, ValueError):
        return None
    try:
        os.kill(int(h.get("pid", 0)), 0)
        h["alive"] = True
    except (OSError, ValueError):
        h["alive"] = False
    return h


def holds_lock():
    """This process runs under a live hold of the lock: the HELD claim, and the holder
    record names the same session with a running pid."""
    if os.environ.get("PLAYPORT_DEVICE_LOCK_HELD") != "1":
        return False
    h = holder()
    return bool(h and h.get("alive") and h.get("session")
                and h.get("session") == os.environ.get("PLAYPORT_DEVICE_SESSION"))


def session():
    """The session of the hold this process runs under, or None."""
    return os.environ.get("PLAYPORT_DEVICE_SESSION") if holds_lock() else None


LOCK_WAIT_EVERY_S = 60


@contextlib.contextmanager
def device_lock(what, wait=None, events=None, expect_s=None):
    """Hold the device lock for the block. wait: seconds, None for as long as it takes.
    expect_s: about how long the job will hold it (the holder record's expected_end)."""
    if holds_lock():
        yield
        return
    events = events or Events(echo=False)
    os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    fd = open(LOCK, "a")
    mine = False
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            events("lock-wait", holder=holder(), wait=wait)
            # the kernel wait below says nothing, so a waiter repeats who it waits for
            t_wait, waited = time.monotonic(), threading.Event()

            def remind():
                while not waited.wait(LOCK_WAIT_EVERY_S):
                    events("lock-wait", holder=holder(), wait=wait, waited_s=round(time.monotonic() - t_wait))
            threading.Thread(target=remind, daemon=True).start()
            if wait is not None:
                def expired(*_):
                    raise TimeoutError
                old = signal.signal(signal.SIGALRM, expired)
                signal.alarm(max(1, int(wait)))
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
            except TimeoutError:
                raise PhoneError(f"the phone stayed busy for {wait} s: {holder()}") from None
            finally:
                waited.set()
                if wait is not None:
                    signal.alarm(0)
                    signal.signal(signal.SIGALRM, old)
        sid = secrets.token_hex(6)
        now = datetime.datetime.now().astimezone()
        rec = {"pid": os.getpid(), "what": what, "cmd": shlex.join(sys.argv)[:400], "checkout": REPO,
               "session": sid, "since": now.isoformat(timespec="seconds")}
        if expect_s:
            rec["expected_end"] = (now + datetime.timedelta(seconds=expect_s)).isoformat(timespec="seconds")
        with open(HOLDER + ".tmp", "w") as f:
            json.dump(rec, f)
        os.replace(HOLDER + ".tmp", HOLDER)
        os.environ["PLAYPORT_DEVICE_LOCK_HELD"] = "1"
        os.environ["PLAYPORT_DEVICE_SESSION"] = sid
        mine = True
        events("lock", what=what, session=sid)
        yield
    finally:
        if mine:
            os.environ.pop("PLAYPORT_DEVICE_LOCK_HELD", None)
            os.environ.pop("PLAYPORT_DEVICE_SESSION", None)
            h = holder()
            if h and h.get("pid") == os.getpid():
                with contextlib.suppress(OSError):
                    os.remove(HOLDER)
        fd.close()


def installed():
    """What the last `pp install` put on the phone (DEVICE_DIR/device-state.json), or None."""
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def same_checkout(rec, path=REPO):
    """Whether a holder or install record names the checkout at path (a record without one names none)."""
    return bool((rec or {}).get("checkout")) and os.path.realpath(rec["checkout"]) == os.path.realpath(path)


def newest_ipa(variant="dev"):
    """This checkout's newest verified IPA of the variant, or None."""
    out = os.environ.get("PLAYPORT_OUT") or os.path.join(BUILD, "out")
    ipas = [p for p in glob.glob(os.path.join(out, "*", "Playport-*.ipa"))
            if ("-release-" in os.path.basename(p)) == (variant == "release")]
    return max(ipas, key=os.path.getmtime) if ipas else None


def installed_check(expect=None, any_build=False, events=None):
    """Whether this checkout may drive what the phone has installed: (ok, message, record).
    expect: an IPA sha256 or an IPA file the record must name. Otherwise the record
    must come from this checkout, unless any_build. A newer verified IPA in this
    checkout than the installed one is reported (an `installed-stale` event), not refused."""
    rec = installed()
    events = events or Events(echo=False)
    if expect:
        want = expect.lower()
        if os.path.isfile(expect):
            import hashlib
            h = hashlib.sha256()
            with open(expect, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            want = h.hexdigest()
        elif not re.fullmatch(r"[0-9a-f]{8,64}", want):
            return False, f"--expect-ipa takes an IPA file or at least 8 hex digits of its sha256, not {expect!r}", rec
        have = (rec or {}).get("ipa_sha256") or ""
        if not have or not have.startswith(want):
            return False, (f"the phone has IPA {have[:12] or 'unknown'} (from {(rec or {}).get('checkout', '?')}), "
                           f"not {want[:12]}: pp install it first"), rec
        return True, None, rec
    if any_build:
        return True, None, rec
    if not rec or not rec.get("ipa_sha256"):
        return False, (f"no record of what the phone has installed ({STATE}); an install may have been cut "
                       "short. pp install, or pass --any-build to drive it anyway"), rec
    if not same_checkout(rec):
        src = f"{rec['checkout']}'s IPA" if rec.get("checkout") else "an IPA from an unknown checkout"
        detail = ", ".join(x for x in (rec.get("head"), rec.get("installed_at") and f"installed {rec['installed_at']}") if x)
        return False, (f"the phone has {src}{f' ({detail})' if detail else ''}, not this checkout's: "
                       "pp install --no-build installs yours; --any-build drives the installed one anyway"), rec
    newest = newest_ipa(rec.get("variant") or "dev")
    if newest and os.path.realpath(newest) != os.path.realpath(rec.get("ipa", "")) \
            and os.path.getmtime(newest) > os.path.getmtime(STATE):
        events("installed-stale", installed=rec.get("ipa"), newest=newest,
               note="this checkout built a newer IPA than the phone has; pp install --no-build installs it")
    return True, None, rec


# netmuxd is the machine's, shared by every agent's session (and by any other project the
# same unit serves): a restart drops every connection through it. At most one per this
# many seconds, recorded in DEVICE_DIR so every job sees it.
NETMUXD_RESTART_EVERY_S = 300
NETMUXD_RESTARTED = os.path.join(DEVICE_DIR, "netmuxd-restart.json")


def netmuxd_unit_socket():
    """The --socket-path of the netmuxd user unit, or None (no unit, no systemd)."""
    try:
        r = subprocess.run(["systemctl", "--user", "show", "netmuxd", "-p", "ExecStart", "--value"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"--socket-path (\S+)", r.stdout)
    return m.group(1) if m else None


def netmuxd_restart():
    """Restart the netmuxd user unit, once, if that is safe: (restarted, why).
    Safe only for a hold of the device lock (no other agent's session is using the
    phone), when this checkout's socket is the one the unit serves (a test's or a
    mistyped socket restarts nothing), and when no one restarted it in the last
    NETMUXD_RESTART_EVERY_S seconds (a phone that is off or asleep is not cured by
    restarting again)."""
    if not holds_lock():
        return False, "not under the device lock: another agent may be using netmuxd"
    unit = netmuxd_unit_socket()
    if not unit or not SOCK or os.path.realpath(unit) != os.path.realpath(SOCK):
        return False, f"the netmuxd unit serves {unit or 'no socket'}, not {SOCK}: not ours to restart"
    try:
        with open(NETMUXD_RESTARTED) as f:
            last = json.load(f)
        ago = time.time() - float(last.get("t", 0))
    except (OSError, ValueError, TypeError, AttributeError):
        last, ago = None, None
    if ago is not None and 0 <= ago < NETMUXD_RESTART_EVERY_S:
        return False, (f"restarted {int(ago)} s ago by {last.get('what')} ({last.get('checkout')}); "
                       f"not again within {NETMUXD_RESTART_EVERY_S} s")
    rec = {"t": time.time(), "what": (holder() or {}).get("what"), "checkout": REPO}
    os.makedirs(os.path.dirname(NETMUXD_RESTARTED), exist_ok=True)
    with open(NETMUXD_RESTARTED + ".tmp", "w") as f:
        json.dump(rec, f)
    os.replace(NETMUXD_RESTARTED + ".tmp", NETMUXD_RESTARTED)
    r = subprocess.run(["systemctl", "--user", "restart", "netmuxd"], check=False)
    if r.returncode != 0:
        return False, f"systemctl --user restart netmuxd failed (exit {r.returncode})"
    return True, "no phone listed"


class Phone:
    """One paired phone over netmuxd, and the Playport app on it."""

    def __init__(self, out=None, dry=False, events=None):
        self.out = out or os.path.join(_scratch(), "phone")  # command output of a run without its own directory
        self.cmd_dir = os.path.join(self.out, "cmd")
        os.makedirs(self.cmd_dir, exist_ok=True)
        self.dry = dry
        self.events = events or Events(echo=False)
        self._bid = None

    # -- commands
    def run(self, name, args, secs, check=True, env=None):
        """One bounded command; its output is kept in <out>/cmd/NAME.{out,err}."""
        cmd = ["timeout", str(secs), *args]
        if self.dry:
            print("DRY " + shlex.join(["env", f"USBMUXD_SOCKET_ADDRESS={SOCK}", *cmd]), flush=True)
            return ""
        r = subprocess.run(cmd, capture_output=True, text=True, env=env or pmd_env())
        with open(os.path.join(self.cmd_dir, name + ".out"), "w") as o:
            o.write(r.stdout)
        with open(os.path.join(self.cmd_dir, name + ".err"), "w") as e:
            e.write(r.stderr)
        if check and r.returncode != 0:
            tail = (r.stderr.strip().splitlines() or [""])[-1][:200]
            raise PhoneError(f"{name} failed (exit {r.returncode}): {tail}; see {self.cmd_dir}/{name}.err")
        return r.stdout + r.stderr

    def pmd(self, name, *args, secs=60, check=True):
        return self.run(name, ["pymobiledevice3", *args], secs, check)

    def afc(self, name, *args, data=None, secs=120, check=True):
        """afc.py on the app's container, under pymobiledevice3's own Python; data goes to stdin."""
        cmd = ["timeout", str(secs), pmd_python(), os.path.join(HERE, "afc.py"), self.bundle_id(), *args]
        if self.dry:
            print("DRY " + shlex.join(cmd), flush=True)
            return ""
        r = subprocess.run(cmd, input=data, capture_output=True, env=pmd_env())
        if check and r.returncode != 0:
            tail = (r.stderr.decode(errors="replace").strip().splitlines() or [""])[-1][:200]
            raise PhoneError(f"afc {name} failed (exit {r.returncode}): {tail}")
        return r.stdout.decode(errors="replace")

    # -- the phone
    def devices(self):
        text = self.pmd("usbmux", "usbmux", "list", secs=30, check=False)
        if self.dry:
            return [{}]
        with contextlib.suppress(OSError):
            os.remove(os.path.join(self.cmd_dir, "usbmux.out"))  # it carries the UDID
        try:
            return json.loads(text[text.index("["):text.rindex("]") + 1])
        except ValueError:
            return []

    def ensure(self):
        """Exactly one phone answers; when none does, restarts netmuxd once if netmuxd_restart
        allows it (under the device lock, this checkout's socket, not restarted lately)."""
        n = len(self.devices())
        if n == 0 and not self.dry:
            # A netmuxd started before the network had a route never lists the phone again.
            ok, why = netmuxd_restart()
            self.events("netmuxd-restart" if ok else "netmuxd-restart-skipped", why=why)
            for _ in range(20 if ok else 0):
                time.sleep(3)
                n = len(self.devices())
                if n:
                    break
        if n != 1:
            raise PhoneError(f"expected one phone on {SOCK}, found {n}: wake and unlock it, "
                             "check it is on the same network (or cabled), then retry")
        return self

    def bundle_id(self):
        if self._bid or self.dry:
            return self._bid or PLACEHOLDER_BID
        text = self.pmd("apps", "apps", "list", "-t", "User")
        found = [b for b in json.loads(text[text.index("{"):text.rindex("}") + 1]) if BID_RE.match(b)]
        if len(found) != 1:
            raise PhoneError(f"expected one installed XTL-<team>.dev.playport.app, found {len(found)} "
                             "(pp install)")
        self._bid = found[0]
        return self._bid

    def pid(self):
        """The app's pid, or None when it is not running."""
        if self.dry:
            return None
        text = self.pmd("pid", "developer", "dvt", "process-id-for-bundle-id", self.bundle_id(), check=False)
        nums = [int(x) for x in re.findall(r"^-?\d+$", text, re.M)]
        return nums[-1] if nums and nums[-1] > 0 else None

    def kill(self):
        """End the app if it runs (by its bundle ID, never by process name); True if it did."""
        pid = self.pid()
        if not pid:
            return False
        self.pmd("kill", "developer", "dvt", "kill", str(pid), check=False)
        for _ in range(10):
            if not self.pid():
                break
            time.sleep(1)
        self.events("killed", pid=pid)
        return True

    # A launch returns in 2-3 s. On a locked phone iOS asks for the passcode and the
    # launch waits for it, so a launch still pending after this is a locked phone.
    LAUNCH_S = 20

    def launch(self, envs):
        args = ["developer", "dvt", "launch", *[x for kv in envs for x in ("--env", kv)], self.bundle_id()]
        text = self.pmd("launch", *args, secs=self.LAUNCH_S, check=False)
        if not self.dry and not re.search(r"pid \d+", text):
            raise PhoneError(f"the app did not launch within {self.LAUNCH_S} s: the phone is most likely locked "
                             "(a launch waits for its passcode). Unlock it, keep it awake, and run again; "
                             f"see {self.cmd_dir}/launch.err")
        pid = int((re.findall(r"pid (\d+)", text) or ["0"])[-1])
        return pid

    def pull(self, remote, dest):
        """One named file into DEST (a directory); its path, or None, with the reason in
        self.pull_error. Never a directory: Documents holds the prefix, whose z: drive links to /."""
        os.makedirs(dest, exist_ok=True)
        local = os.path.join(dest, os.path.basename(remote))
        with contextlib.suppress(OSError):
            os.remove(local)
        name = "pull-" + os.path.basename(remote)
        self.pmd(name, "apps", "pull", self.bundle_id(), remote, dest, secs=300, check=False)
        self.pull_error = None
        if os.path.exists(local):
            return local
        try:
            with open(os.path.join(self.cmd_dir, name + ".err"), errors="replace") as f:
                tail = [x.strip() for x in f if x.strip()]
        except OSError:
            tail = []
        self.pull_error = (tail[-1][:300] if tail else "no file came back") + f" (see {self.cmd_dir}/{name}.err)"
        return None

    def pull_bundle(self, remote, dest):
        """A Metal .gputrace (a directory) whole into DEST/<its name>, its links kept as
        links (afc.py pull-bundle); the local path. GPU capture (Settings, dev) writes
        one into the game's folder."""
        os.makedirs(dest, exist_ok=True)
        self.afc("pull-bundle", "pull-bundle", remote, os.path.abspath(dest), secs=1800)
        return os.path.join(dest, os.path.basename(remote.rstrip("/")))

    def stat(self, remote):
        """("file", size), ("dir", None), ("link", target) or ("absent", None), in one AFC call."""
        k, _, v = self.afc("stat", "stat", remote).strip().partition(" ")
        return k, (int(v) if k == "file" else v or None)

    def ls(self, remote):
        """The entries of a directory in the container, as afc.py ls prints them."""
        return self.afc("ls", "ls", remote, secs=300).splitlines()

    def battery(self):
        """{"pct", "external_power", "charging"} from the battery gauge, or {} when it
        could not be read (pp perf records the same in power.txt)."""
        text = self.pmd("battery", "diagnostics", "battery", "single", secs=20, check=False)
        with contextlib.suppress(OSError):
            os.remove(os.path.join(self.cmd_dir, "battery.out"))  # it carries the battery's serial
        try:
            j = json.loads(text[text.index("{"):text.rindex("}") + 1])
        except ValueError:
            return {}
        return battery_of(j)

    def push(self, local, remote):
        self.pmd("push-" + os.path.basename(remote), "apps", "push", self.bundle_id(), local, remote, secs=300)

    def rotate_log(self):
        """Move s1-host.log aside (to s1-host.prev.log), so this run's log is the whole file."""
        if self.dry:
            return
        self.afc("rotate-log", "rotate-log", check=False)

    def screenshot(self, path, max_side=1600):
        """The screen as an 8-bit RGB PNG, scaled so its longer side is at most max_side."""
        raw = path + ".raw.png"
        self.pmd("screenshot-" + os.path.basename(path), "developer", "dvt", "screenshot", raw, secs=120, check=False)
        if self.dry or not os.path.exists(raw):
            return None
        try:
            from PIL import Image
            im = Image.open(raw)
            if im.mode != "RGB":
                im = im.convert("RGB")
            if max_side and max(im.size) > max_side:
                k = max_side / max(im.size)
                im = im.resize((round(im.width * k), round(im.height * k)))
            im.save(path)
            os.remove(raw)
        except ImportError:
            os.replace(raw, path)
        return path

    def crashes(self, dest, since=None):
        """The app's crash reports (dev or release) newer than `since` (unix time) into DEST."""
        os.makedirs(dest, exist_ok=True)
        day = time.strftime("%Y-%m-%d", time.localtime(since or time.time()))
        before = set(os.listdir(dest))
        for exe in EXECUTABLES:
            self.pmd("crash-" + exe, "crash", "pull", "--match", f"^{exe}-{day}", dest, secs=300, check=False)
        new = []
        for n in sorted(set(os.listdir(dest)) - before):
            p = os.path.join(dest, n)
            if since is None or os.path.getmtime(p) >= since - 60:
                new.append(p)
        return new

    def put(self, remote, data):
        """Write bytes to a file in the container, whole, in one AFC call (no temporary file)."""
        self.afc("put", "put", remote, data=data)

    def run_events(self, nonce):
        """This launch's events from the app's Documents/run-events.jsonl ([] if none yet)."""
        local = self.pull("Documents/run-events.jsonl", os.path.join(self.out, "pull"))
        out = []
        if local:
            for line in open(local, errors="replace"):
                with contextlib.suppress(ValueError):
                    o = json.loads(line)
                    if o.get("nonce") == nonce:
                        out.append(o)
        return out


LOW_BATTERY_PCT = 30


def battery_of(j):
    """The charge fields of a `diagnostics battery single` object, and a warning below
    LOW_BATTERY_PCT on no charger: a phone near empty parks its P cores and ends runs."""
    b = {"pct": j.get("CurrentCapacity"), "external_power": j.get("ExternalConnected"),
         "charging": j.get("IsCharging")}
    b = {k: v for k, v in b.items() if v is not None}
    if b.get("pct") is not None and b["pct"] < LOW_BATTERY_PCT and not b.get("external_power"):
        b["warning"] = f"battery at {b['pct']}% with no charger: charge the phone (ask the person at it)"
    return b


def _scratch():
    d = os.path.join(BUILD, "tmp")
    os.makedirs(d, exist_ok=True)
    return d


def run_dir(kind, out=None):
    """out, or $PLAYPORT_BUILD/<kind>/<time>, with argv.txt: the command that made it,
    where it ran, and the checkout's HEAD (a later session reads what produced a run)."""
    d = out or os.path.join(BUILD, kind, time.strftime("%Y%m%dT%H%M%S"))
    os.makedirs(d, exist_ok=True)
    git = lambda *a: subprocess.run(["git", "-C", REPO, *a], capture_output=True, text=True).stdout.strip()  # noqa: E731
    with contextlib.suppress(OSError):
        with open(os.path.join(d, "argv.txt"), "w") as f:
            f.write(f"argv: {shlex.join(sys.argv)}\ncwd: {os.getcwd()}\ncheckout: {REPO}\n"
                    f"head: {git('rev-parse', '--short', 'HEAD')}{' (dirty)' if git('status', '--porcelain', '-uno') else ''}\n"
                    f"at: {datetime.datetime.now().astimezone().isoformat(timespec='seconds')}\n")
    return d


def parse_until(spec):
    """'done' | 'first-frame[+S]' | 'mark:<text>[+S]' | 'event:<name>[+S]' -> (kind, arg, extra_s)."""
    m = re.fullmatch(r"(done|first-frame|mark:[^+]+|event:[^+]+)(?:\+(\d+(?:\.\d+)?))?", spec or "done")
    if not m:
        raise ValueError(f"--until takes done, first-frame[+S], mark:<text>[+S] or event:<name>[+S], not {spec!r}")
    what, extra = m.group(1), float(m.group(2) or 0)
    if what == "first-frame":
        return ("mark", "first frame", extra)
    if ":" in what:
        k, v = what.split(":", 1)
        return (k, v, extra)
    return ("done", None, extra)


def watch_launch(phone, events, nonce, pid, until, wait, poll=3, done_events=("title-done",),
                 is_done=None, quiet=False, on_event=None):
    """Follow a driven launch through the app's run-events until `until` holds, the app
    exits, or `wait` seconds pass. Relays each app event. quiet: once `until` has
    matched, read nothing from the phone until its extra seconds are over (a measured
    run). Returns (why, last_done_event): why is "until", "done", "exited" or "timeout"."""
    kind, arg, extra = until
    deadline = time.monotonic() + wait
    seen, done, hit_at = 0, None, None
    misses, alive_check = 0, time.monotonic() + 10
    while time.monotonic() < deadline:
        evs = phone.run_events(nonce)
        for e in evs[seen:]:
            events("app:" + str(e.get("event")), **{k: v for k, v in e.items() if k not in ("nonce", "event")})
            if on_event:
                on_event(e)
            if e.get("event") in done_events and (is_done is None or is_done(e)):
                done = e
            if hit_at is None and ((kind == "mark" and e.get("event") == "mark" and e.get("what") == arg)
                                   or (kind == "event" and e.get("event") == arg)):
                hit_at = time.monotonic()
                events("until", what=f"{kind}:{arg}", extra_s=extra)
                if quiet:
                    time.sleep(max(0, min(deadline, hit_at + extra) - time.monotonic()))
        seen = len(evs)
        if done is not None:
            return "done", done
        if hit_at is not None and time.monotonic() >= hit_at + extra:
            return "until", None
        if pid and time.monotonic() >= alive_check:  # a dvt call each time: every 10 s
            alive_check = time.monotonic() + 10
            if phone.pid() is None:
                misses += 1
                if misses >= 2:
                    return "exited", None
            else:
                misses = 0
        time.sleep(poll if hit_at is None else min(poll, max(0.5, hit_at + extra - time.monotonic())))
    return "timeout", None


def summarize_log(log, out, app_events=()):
    """timeline.txt: the run's title:, jit: and ui: lines (the log is this run's alone),
    plus each mark from the app's events that the log lacks."""
    lines = []
    if log and os.path.exists(log):
        with open(log, "rb") as f:
            for raw in f:
                s = raw.decode("utf-8", "replace").rstrip("\n")
                if re.search(r"(^|[\] ])(title|jit|ui): ", s):
                    lines.append(s)
    for e in app_events:
        if e.get("event") == "mark":
            line = "title: +%.2f s %s" % (e.get("s", 0), e.get("what"))
            if line not in lines:
                lines.append(line + "  (from run-events.jsonl)")
    with open(os.path.join(out, "timeline.txt"), "w") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))
    return lines


def fail(events, msg, code=1):
    events("error", message=msg)
    print(msg, file=sys.stderr)
    return events.result(False, code)


if __name__ == "__main__":
    # build/install's restart, under the same guards: prints why, exits 0 only if it restarted.
    # Outside a hold it takes the lock for the restart alone, if no other job holds it.
    if sys.argv[1:] != ["netmuxd-restart"]:
        sys.exit("usage: phonelib.py netmuxd-restart")
    try:
        with device_lock("netmuxd restart (pp install)", wait=1):
            restarted, why = netmuxd_restart()
    except PhoneError:
        h = holder() or {}
        restarted, why = False, f"another job holds the phone: {h.get('what', '?')} ({h.get('checkout', '?')})"
    print(why)
    sys.exit(0 if restarted else 1)
