# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/phonelib.py (events, --until, the device lock) and build/lib.sh
ensure_series (a patch edited in place is reapplied). No phone is touched."""

import importlib
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def spit(path, mode, data):
    with open(path, mode) as f:
        f.write(data)


def slurp(path):
    with open(path) as f:
        return f.read()


def load_phonelib(build, device_dir=None):
    os.environ["PLAYPORT_BUILD"] = build
    if device_dir:
        os.environ["PLAYPORT_DEVICE_DIR"] = device_dir
    else:
        os.environ.pop("PLAYPORT_DEVICE_DIR", None)
    os.environ.pop("PLAYPORT_DEVICE_LOCK", None)
    os.environ.pop("PLAYPORT_DEVICE_LOCK_HELD", None)
    os.environ.pop("PLAYPORT_DEVICE_SESSION", None)
    sys.path.insert(0, os.path.join(REPO, "tools"))
    import phonelib
    return importlib.reload(phonelib)


class PhonelibTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.saved = os.environ.get("PLAYPORT_BUILD")
        self.saved_dir = os.environ.get("PLAYPORT_DEVICE_DIR")
        # Never the real phone's lock: the device directory is the test's own.
        self.pl = load_phonelib(self.tmp, self.tmp)

    def tearDown(self):
        os.environ.pop("PLAYPORT_DEVICE_LOCK_HELD", None)
        os.environ.pop("PLAYPORT_DEVICE_SESSION", None)
        if self.saved_dir is None:
            os.environ.pop("PLAYPORT_DEVICE_DIR", None)
        else:
            os.environ["PLAYPORT_DEVICE_DIR"] = self.saved_dir
        if self.saved is None:
            os.environ.pop("PLAYPORT_BUILD", None)
        else:
            os.environ["PLAYPORT_BUILD"] = self.saved
        load_phonelib(os.environ.get("PLAYPORT_BUILD") or os.path.join(REPO, ".work"), self.saved_dir)
        shutil.rmtree(self.tmp)

    def test_until(self):
        p = self.pl.parse_until
        self.assertEqual(p("done"), ("done", None, 0))
        self.assertEqual(p("first-frame+10"), ("mark", "first frame", 10))
        self.assertEqual(p("mark:runtime started"), ("mark", "runtime started", 0))
        self.assertEqual(p("event:ui-done+2.5"), ("event", "ui-done", 2.5))
        with self.assertRaises(ValueError):
            p("frame")

    def test_events_end_with_a_result(self):
        ev = self.pl.Events(self.tmp, echo=False)
        ev("launched", pid=1)
        self.assertEqual(ev.result(False, 2, why="x"), 2)
        with open(os.path.join(self.tmp, "events.jsonl")) as f:
            lines = [json.loads(l) for l in f]
        self.assertEqual([l["event"] for l in lines], ["launched", "result"])
        self.assertEqual(lines[-1]["exit"], 2)

    def test_lock_records_its_holder_and_a_waiter_sees_it(self):
        pl = self.pl
        with pl.device_lock("first job"):
            h = pl.holder()
            self.assertEqual((h["what"], h["pid"], h["alive"]), ("first job", os.getpid(), True))
            # A second process waits in the kernel and names the holder.
            code = ("import sys; sys.path.insert(0, %r); import phonelib\n"
                    "with phonelib.device_lock('second', wait=1, events=phonelib.Events()): pass\n"
                    % os.path.join(REPO, "tools"))
            env = dict(os.environ)
            env.pop("PLAYPORT_DEVICE_LOCK_HELD")
            r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env=env)
            self.assertNotEqual(r.returncode, 0)
            wait = json.loads(r.stdout.splitlines()[0])
            self.assertEqual((wait["event"], wait["holder"]["what"]), ("lock-wait", "first job"))
            self.assertIn("stayed busy", r.stderr)
            # A tool started by the holder uses its lock.
            with pl.device_lock("nested"):
                pass
        self.assertIsNone(pl.holder())

    def test_lock_waiter_gets_it_when_freed(self):
        pl = self.pl
        got = []
        with pl.device_lock("holder"):
            env = dict(os.environ)
            env.pop("PLAYPORT_DEVICE_LOCK_HELD")
            code = ("import sys; sys.path.insert(0, %r); import phonelib\n"
                    "with phonelib.device_lock('waiter', wait=30): print('got')\n"
                    % os.path.join(REPO, "tools"))
            p = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, text=True, env=env)
            t = threading.Thread(target=lambda: got.append(p.communicate()[0]))
            t.start()
            time.sleep(0.5)
            self.assertEqual(got, [])
        t.join(10)
        self.assertEqual(got, ["got\n"])


    def test_a_waiter_repeats_whom_it_waits_for(self):
        """The holder record names the command and expected end; the waiter says so again
        every LOCK_WAIT_EVERY_S while the kernel keeps it waiting."""
        pl = self.pl
        with pl.device_lock("long job", expect_s=600):
            h = pl.holder()
            self.assertIn("cmd", h)
            self.assertIn("expected_end", h)
            code = ("import sys; sys.path.insert(0, %r); import phonelib\n"
                    "phonelib.LOCK_WAIT_EVERY_S = 0.3\n"
                    "with phonelib.device_lock('waiter', wait=2, events=phonelib.Events()): pass\n"
                    % os.path.join(REPO, "tools"))
            env = dict(os.environ)
            env.pop("PLAYPORT_DEVICE_LOCK_HELD")
            r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env=env)
        waits = [json.loads(x) for x in r.stdout.splitlines() if '"lock-wait"' in x]
        self.assertGreaterEqual(len(waits), 3)
        self.assertNotIn("waited_s", waits[0])
        self.assertEqual(waits[-1]["holder"]["what"], "long job")
        self.assertGreater(waits[-1]["waited_s"], 0)

    def test_a_run_dir_records_its_command(self):
        d = self.pl.run_dir("ui-runs", os.path.join(self.tmp, "run"))
        with open(os.path.join(d, "argv.txt")) as f:
            text = f.read()
        for k in ("argv:", "cwd:", "checkout:", "head:", "at:"):
            self.assertIn(k, text)

    def test_battery(self):
        b = self.pl.battery_of
        self.assertEqual(b({"CurrentCapacity": 80, "ExternalConnected": False}),
                         {"pct": 80, "external_power": False})
        self.assertIn("warning", b({"CurrentCapacity": 12, "ExternalConnected": False}))
        self.assertNotIn("warning", b({"CurrentCapacity": 12, "ExternalConnected": True, "IsCharging": True}))
        self.assertEqual(b({}), {})

    def test_a_held_claim_without_its_live_holder_is_ignored(self):
        pl = self.pl
        # An environment that says HELD (a shell left from an old session) takes the lock itself.
        os.environ["PLAYPORT_DEVICE_LOCK_HELD"] = "1"
        os.environ["PLAYPORT_DEVICE_SESSION"] = "stale"
        self.assertFalse(pl.holds_lock())
        with pl.device_lock("real"):
            h = pl.holder()
            self.assertEqual(h["what"], "real")
            self.assertNotEqual(h["session"], "stale")
            self.assertEqual(pl.session(), h["session"])
        self.assertIsNone(pl.holder())

    def test_each_hold_is_a_new_session(self):
        pl = self.pl
        with pl.device_lock("one"):
            first = pl.session()
            with pl.device_lock("nested"):
                self.assertEqual(pl.session(), first)
        with pl.device_lock("two"):
            self.assertNotEqual(pl.session(), first)
        self.assertIsNone(pl.session())

    def write_state(self, **rec):
        with open(self.pl.STATE, "w") as f:
            json.dump(rec, f)

    def test_installed_check(self):
        pl = self.pl
        ok, why, _ = pl.installed_check()
        self.assertFalse(ok)
        self.assertIn("no record", why)
        self.assertTrue(pl.installed_check(any_build=True)[0])
        sha = "ab" * 32
        self.write_state(ipa="/x/Playport-26.5-abababab.ipa", ipa_sha256=sha, variant="dev",
                         checkout="/elsewhere/checkout", head="1234567", installed_at="t")
        ok, why, rec = pl.installed_check()
        self.assertFalse(ok)
        self.assertIn("/elsewhere/checkout", why)
        self.assertTrue(pl.installed_check(any_build=True)[0])
        self.assertTrue(pl.installed_check(expect=sha[:12])[0])
        self.assertFalse(pl.installed_check(expect="cd" * 6)[0])
        self.assertIn("hex digits", pl.installed_check(expect="abc")[1])
        ipa = os.path.join(self.tmp, "x.ipa")
        spit(ipa, "wb", b"ipa")
        self.assertFalse(pl.installed_check(expect=ipa)[0])
        self.write_state(ipa=ipa, ipa_sha256=sha, variant="dev", checkout=REPO, head="1234567", installed_at="t")
        self.assertTrue(pl.installed_check()[0])

    def test_a_record_without_a_checkout_names_none(self):
        pl = self.pl
        self.write_state(ipa="/x.ipa", ipa_sha256="ab" * 32, variant="dev", head="1234567", installed_at="t")
        self.assertFalse(pl.installed_check()[0])

    def test_a_newer_build_than_the_installed_one_is_reported(self):
        pl = self.pl
        self.write_state(ipa="/old.ipa", ipa_sha256="ab" * 32, variant="dev", checkout=REPO)
        d = os.path.join(self.tmp, "out", "20990101-000000-cdcdcdcd")
        os.makedirs(d)
        newest = os.path.join(d, "Playport-26.5-cdcdcdcd.ipa")
        open(newest, "w").close()
        os.utime(pl.STATE, (time.time() - 60,) * 2)
        ev = pl.Events(self.tmp, echo=False)
        self.assertTrue(pl.installed_check(events=ev)[0])
        lines = [json.loads(l) for l in slurp(os.path.join(self.tmp, "events.jsonl")).splitlines()]
        self.assertEqual([(l["event"], l["newest"]) for l in lines], [("installed-stale", newest)])


class NetmuxdRestartTest(unittest.TestCase):
    """The shared netmuxd is restarted only under the device lock, only when it serves
    this checkout's socket, and at most once per NETMUXD_RESTART_EVERY_S. A stub
    systemctl records what would have run: no test restarts the machine's netmuxd."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.saved = {k: os.environ.get(k) for k in ("PLAYPORT_BUILD", "PLAYPORT_DEVICE_DIR", "PATH",
                                                      "PLAYPORT_USBMUX_SOCKET")}
        self.sock = os.path.join(self.tmp, "nm.sock")
        self.calls = os.path.join(self.tmp, "calls")
        stub = os.path.join(self.tmp, "bin")
        os.makedirs(stub)
        # systemctl: `show` prints the unit's ExecStart (UNIT_SOCK), `restart` is recorded.
        with open(os.path.join(stub, "systemctl"), "w") as f:
            f.write('#!/bin/sh\necho "$@" >> "%s"\n'
                    'case "$*" in *show*) echo "{ path=/usr/bin/netmuxd ; argv[]=/usr/bin/netmuxd '
                    '--socket-path $UNIT_SOCK --disable-usb ; }" ;; *restart*) exit "${RESTART_EXIT:-0}" ;; esac\n' % self.calls)
        # pymobiledevice3: no phone listed.
        with open(os.path.join(stub, "pymobiledevice3"), "w") as f:
            f.write("#!/bin/sh\necho '[]'\n")
        for n in ("systemctl", "pymobiledevice3"):
            os.chmod(os.path.join(stub, n), 0o755)
        os.environ["PATH"] = stub + os.pathsep + os.environ["PATH"]
        os.environ["PLAYPORT_USBMUX_SOCKET"] = self.sock
        os.environ["UNIT_SOCK"] = self.sock
        self.pl = load_phonelib(self.tmp, self.tmp)

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        os.environ.pop("UNIT_SOCK", None)
        os.environ.pop("RESTART_EXIT", None)
        os.environ.pop("PLAYPORT_DEVICE_LOCK_HELD", None)
        os.environ.pop("PLAYPORT_DEVICE_SESSION", None)
        load_phonelib(os.environ.get("PLAYPORT_BUILD") or os.path.join(REPO, ".work"),
                      os.environ.get("PLAYPORT_DEVICE_DIR"))
        shutil.rmtree(self.tmp)

    def restarts(self):
        try:
            with open(self.calls) as f:
                return sum(1 for line in f if line.startswith("--user restart netmuxd"))
        except OSError:
            return 0

    def test_not_outside_the_lock(self):
        ok, why = self.pl.netmuxd_restart()
        self.assertFalse(ok)
        self.assertIn("device lock", why)
        self.assertEqual(self.restarts(), 0)

    def test_not_for_another_socket(self):
        os.environ["UNIT_SOCK"] = os.path.join(self.tmp, "someone-elses.sock")
        with self.pl.device_lock("t"):
            ok, why = self.pl.netmuxd_restart()
        self.assertFalse(ok)
        self.assertIn("not ours", why)
        self.assertEqual(self.restarts(), 0)

    def test_once_per_period_across_holds(self):
        with self.pl.device_lock("first"):
            self.assertEqual(self.pl.netmuxd_restart(), (True, "no phone listed"))
        with self.pl.device_lock("second"):
            ok, why = self.pl.netmuxd_restart()
        self.assertFalse(ok)
        self.assertIn("by first", why)
        self.assertEqual(self.restarts(), 1)
        # Once the period is over it may restart again.
        with open(self.pl.NETMUXD_RESTARTED) as f:
            rec = json.load(f)
        rec["t"] -= self.pl.NETMUXD_RESTART_EVERY_S + 1
        with open(self.pl.NETMUXD_RESTARTED, "w") as f:
            json.dump(rec, f)
        with self.pl.device_lock("third"):
            self.assertTrue(self.pl.netmuxd_restart()[0])
        self.assertEqual(self.restarts(), 2)

    def test_failed_restart_is_reported_and_recorded(self):
        os.environ["RESTART_EXIT"] = "5"
        phone = self.pl.Phone(os.path.join(self.tmp, "run"), events=self.pl.Events(self.tmp, echo=False))
        t0 = time.monotonic()
        with self.pl.device_lock("first"):
            with self.assertRaises(self.pl.PhoneError):
                phone.ensure()
        self.assertLess(time.monotonic() - t0, 3)
        with open(os.path.join(self.tmp, "events.jsonl")) as f:
            skipped = [e for e in map(json.loads, f) if e["event"].startswith("netmuxd-restart")]
        self.assertEqual([(e["event"], e["why"]) for e in skipped],
                         [("netmuxd-restart-skipped", "systemctl --user restart netmuxd failed (exit 5)")])
        self.assertEqual(self.restarts(), 1)
        with self.pl.device_lock("second"):
            ok, why = self.pl.netmuxd_restart()
        self.assertFalse(ok)
        self.assertIn("by first", why)
        self.assertEqual(self.restarts(), 1)

    def test_ensure_outside_the_lock_fails_without_a_restart(self):
        phone = self.pl.Phone(os.path.join(self.tmp, "run"), events=self.pl.Events(self.tmp, echo=False))
        with self.assertRaises(self.pl.PhoneError):
            phone.ensure()
        self.assertEqual(self.restarts(), 0)
        with open(os.path.join(self.tmp, "events.jsonl")) as f:
            self.assertEqual([json.loads(line)["event"] for line in f], ["netmuxd-restart-skipped"])

    def install_check(self, held=True):
        """build/install --check --no-build up to its phone check, with stubs: netmuxd on PATH,
        a socket at PLAYPORT_USBMUX_SOCKET, and a phone listed only after a restart."""
        stub = os.path.join(self.tmp, "bin")
        with open(os.path.join(stub, "netmuxd"), "w") as f:
            f.write("#!/bin/sh\n")
        with open(os.path.join(stub, "pymobiledevice3"), "w") as f:
            f.write('#!/bin/sh\nif grep -q "restart netmuxd" "%s" 2>/dev/null; then echo \'[{"Identifier": "u"}]\'; '
                    "else echo '[]'; fi\n" % self.calls)
        for n in ("netmuxd", "pymobiledevice3"):
            os.chmod(os.path.join(stub, n), 0o755)
        s = socket.socket(socket.AF_UNIX)
        s.bind(self.sock)
        self.addCleanup(s.close)
        return subprocess.run([os.path.join(REPO, "build", "install"), "--check", "--no-build"],
                              env=self.env(held), capture_output=True, text=True, timeout=120)

    def env(self, held=True):
        """The environment of a child; held=False: a process outside this test's hold."""
        env = dict(os.environ, PLAYPORT_BUILD=self.tmp, PLAYPORT_DEVICE_DIR=self.tmp)
        if not held:
            env.pop("PLAYPORT_DEVICE_LOCK_HELD", None)
            env.pop("PLAYPORT_DEVICE_SESSION", None)
        return env

    def cli(self, held=True):
        return subprocess.run([sys.executable, os.path.join(REPO, "tools", "phonelib.py"), "netmuxd-restart"],
                              env=self.env(held), capture_output=True, text=True, timeout=30)

    def test_cli_takes_the_free_lock_and_restarts_once(self):
        r = self.cli()
        self.assertEqual((r.returncode, r.stdout), (0, "no phone listed\n"), r.stderr)
        self.assertEqual(self.restarts(), 1)
        with open(self.pl.NETMUXD_RESTARTED) as f:
            self.assertEqual(json.load(f)["what"], "netmuxd restart (pp install)")
        self.assertIsNone(self.pl.holder())

    def test_cli_does_not_restart_while_another_job_holds_the_phone(self):
        with self.pl.device_lock("other agent's play"):
            r = self.cli(held=False)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout, f"another job holds the phone: other agent's play ({REPO})\n")
        self.assertEqual(self.restarts(), 0)

    def test_install_with_the_lock_free_restarts_once(self):
        r = self.install_check()
        self.assertEqual(self.restarts(), 1)
        self.assertIn("restarted netmuxd once", r.stderr)
        self.assertNotIn("expected exactly one phone", r.stderr)

    def test_install_while_another_job_holds_the_phone_fails_without_a_restart(self):
        with self.pl.device_lock("other agent's play"):
            r = self.install_check(held=False)
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("expected exactly one phone", r.stderr)
        self.assertIn("netmuxd not restarted: another job holds the phone: other agent's play", r.stderr)
        self.assertEqual(self.restarts(), 0)

    def test_install_stops_when_the_restart_fails(self):
        os.environ["RESTART_EXIT"] = "5"
        t0 = time.monotonic()
        with self.pl.device_lock("install"):
            r = self.install_check()
        self.assertLess(time.monotonic() - t0, 30)
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("netmuxd not restarted: systemctl --user restart netmuxd failed (exit 5)", r.stderr)
        self.assertEqual(self.restarts(), 1)

    def test_install_under_the_lock_restarts_once(self):
        with self.pl.device_lock("install"):
            r = self.install_check()
        self.assertEqual(self.restarts(), 1)
        self.assertIn("restarted netmuxd once", r.stderr)
        self.assertNotIn("expected exactly one phone", r.stderr)


class BuildAreaTest(unittest.TestCase):
    """inputs.local and the phone's device directory are the build area's, from Python
    (build/inputs.py) and from the shell (build/lib.sh) alike; PLAYPORT_BUILD moves both,
    which is how a pp sync candidate shares this checkout's."""

    def test_the_build_area_holds_inputs_and_the_device_dir(self):
        with tempfile.TemporaryDirectory() as t:
            repo, area = os.path.join(t, "repo"), os.path.join(t, "area")
            os.makedirs(os.path.join(repo, "build"))
            for f in ("env.sh", "lib.sh", "inputs.py"):
                shutil.copy(os.path.join(REPO, "build", f), os.path.join(repo, "build", f))
            for d, sock in ((os.path.join(repo, ".work"), "/run/own"), (area, "/run/shared")):
                os.makedirs(d)
                spit(os.path.join(d, "inputs.local"), "w", f"PLAYPORT_USBMUX_SOCKET={sock}\n")
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith("PLAYPORT_") and k not in ("LLVM_MINGW", "DARWIN_SDK")}

            def both(env):
                sh = subprocess.run(["bash", "-c", f". {repo}/build/lib.sh; echo \"$PLAYPORT_DEVICE_DIR|$PLAYPORT_USBMUX_SOCKET\""],
                                    capture_output=True, text=True, env=env, check=True).stdout.strip()
                py = subprocess.run([sys.executable, "-c", f"import sys; sys.path.insert(0, {os.path.join(repo, 'build')!r}); "
                                     "import inputs; print(f'{inputs.DEVICE_DIR}|{inputs.get(\"PLAYPORT_USBMUX_SOCKET\")}')"],
                                    capture_output=True, text=True, env=env, check=True).stdout.strip()
                return sh, py

            want = f"{repo}/.work|/run/own"
            self.assertEqual(both(env), (want, want))
            want = f"{area}|/run/shared"
            self.assertEqual(both(dict(env, PLAYPORT_BUILD=area)), (want, want))


def git(cwd, *args):
    return subprocess.run(["git", "-C", cwd, *args], check=True, capture_output=True, text=True,
                          env=dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@x", GIT_COMMITTER_NAME="t",
                                   GIT_COMMITTER_EMAIL="t@x")).stdout.strip()


class EnsureSeriesTest(unittest.TestCase):
    """A tree whose commits match the series by count but not by content is rebuilt."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(os.path.join(self.repo, "build"))
        for f in ("env.sh", "lib.sh"):
            shutil.copy(os.path.join(REPO, "build", f), os.path.join(self.repo, "build", f))
        up = os.path.join(self.tmp, "up")
        os.makedirs(up)
        git(up, "init", "-q")
        spit(os.path.join(up, "f"), "w", "one\n")
        git(up, "add", "f")
        git(up, "commit", "-qm", "base")
        self.pin = git(up, "rev-parse", "HEAD")
        spit(os.path.join(up, "f"), "w", "one\ntwo\n")
        git(up, "commit", "-qam", "add two")
        pdir = os.path.join(self.repo, "patches", "t")
        os.makedirs(pdir)
        git(up, "format-patch", "-q", "-1", "-o", pdir)
        self.patch = os.path.join(pdir, os.listdir(pdir)[0])
        spit(os.path.join(pdir, "series"), "w", os.path.basename(self.patch) + "\n")
        self.tree = os.path.join(self.tmp, "tree")
        git(self.tmp, "clone", "-q", up, self.tree)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def sh(self, fn):
        r = subprocess.run(["bash", "-c", f'. build/lib.sh; {fn} "{self.tree}" t {self.pin}'], cwd=self.repo,
                           capture_output=True, text=True, env=dict(os.environ, PLAYPORT_BUILD=self.tmp))
        return r.returncode, r.stdout + r.stderr

    def test_edited_patch_is_reapplied(self):
        self.assertEqual(self.sh("ensure_series")[0], 0)
        self.assertEqual(self.sh("check_series")[0], 0)
        body = slurp(self.patch).replace("+two", "+TWO")
        spit(self.patch, "w", body)
        self.assertNotEqual(self.sh("check_series")[0], 0)   # same count, other content
        st, out = self.sh("ensure_series")
        self.assertEqual(st, 0, out)
        self.assertIn("(re)applying", out)
        self.assertEqual(slurp(os.path.join(self.tree, "f")), "one\nTWO\n")


if __name__ == "__main__":
    unittest.main()
