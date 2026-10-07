#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""pp: the one tool for Playport: build, ship, test, drive the phone. AGENTS.md has the loop.

Build and ship
  pp setup [--check]              record where this machine's toolchains and netmuxd socket are (once)
  pp build [--variant dev|release] [--unsigned] [--clean | --from STAGE] [--to STAGE] [--keep-outputs N] [--plan]
                                  build what changed into a verified IPA (keeps the newest 3;
                                  --plan: which stages would run and why, building nothing;
                                  --unsigned: a release's IPA, ad hoc signed, no profile)
  pp install [--no-build] [--ipa IPA] [--variant V] [--force] [--check]
                                  build what changed, then install it on the phone in place
                                  (--check: the host, account, phone and IPA checks only)
  pp check [--variant dev|release]  compile the app unsigned: Swift errors, no IPA (~10 s once the
                                  trees and notices are built; it first builds what changed, and says so)
  pp verify IPA [--variant V] [--same-device-as OLD.ipa | --unsigned]
                                  the IPA checks the build's last stage runs
  pp release VERSION [--clean | --no-build] [--no-github]
                                  the unsigned release build of HEAD (reused, or built
                                  incrementally; --clean: every tree afresh), the gates, and a
                                  GitHub draft pre-release (never published; decisions 0038, 0050)

Test on the host
  pp test [--quick]               names, secrets, the pin and patch series (trailers), tools/tests,
                                  the host C tests, Swift package tests (--quick: no Swift; CI runs it)
          [--swift PKG [--filter X]]  only PKG's Swift tests (PlayportKit, HostIOKit, SteamClient)
  pp names [COMMIT]               the name gate alone (pp test and CI run it)
  pp secrets                      no token, Steam ID, key, UDID or team ID in the tracked files

Drive the phone (dev app)
  pp ui [OPTIONS]                 do things through the app's UI: --action open:settings,
                                  --play app-367520 --until first-frame+10 --shot, ...
  pp perf [OPTIONS]               a measured play: FPS, frame and GPU time, CPU, thermal budget
  pp gpu capture --frame N | validate | read BUNDLE | passes RUN | names [--fetch]
                                  GPU debugging: a frame as a Metal capture, read here; Metal
                                  validation; GPU time per pass (docs/GPU-DEBUGGING.md)
  pp pad send STEP... | push SCRIPT | rest [--shot FILE]
                                  press buttons on the scripted pad of a running title
  pp phone status | kill | log [DIR] | ls REMOTE | pull REMOTE [DIR] | shot [FILE] | crashes [DIR] [--since T]
  pp phone lock [--wait S] -- CMD run CMD under one hold of the lock: one session for a sequence
                                  (install, then plays, a pad) that no other agent may split
  pp phone unattended on [--hours N] | off | status
                                  nobody watches the phone: each release of the lock leaves the dev
                                  app's black screen up (lowest brightness) when the app is not
                                  running, to spare the OLED (default 12 h; off ends it)
  pp phone rest [--if-unattended] the black screen now (as above; build/install's hook)

Upstream and review
  pp sync [<madeira-sha>] [--replay]
                                  watch Madeira past the frozen pin (decision 0054): its commits
                                  that touch what Playport builds; never moves a pin
  pp rebase TARGET NEW [--trial] | --continue | --abort | --write [--pins]
                                  move one series stack onto a new upstream commit in a scratch
                                  clone: conflict trial, rerere, range-diff, re-export (UPSTREAM-SYNC.md)
  pp slots [DXMT_TREE]            every winemetal thunk against its unix call slot (after a DXMT rebase)
  pp shaders TITLE_DIR OUT [...]  run a title's DXBC shaders through a host airconv (built on first use)
  pp registry [--check]           regenerate the prefix registry seed (app/registry) from the staged DLLs
  pp notices OUT                  copy the licence and notice files of the pinned trees (DISTRIBUTION.md)
  pp notices --prepare-rust-cache OUT  prepare separate pristine locked crate inputs (NOTICES.md)
  pp notices --app NOTICES OUT    select the app's Licenses/ from a notices output (build/app-notices.json)
  pp source OUT [--build DIR | --rev REV] [--offline]
                                  pack a build's Corresponding Source from its exact commits (DISTRIBUTION.md)

`pp <command> --help` gives each command's options. Every phone command takes
the device lock itself (and says whom it waits for); the lock and the install
record are in .work (or $PLAYPORT_DEVICE_DIR). Long ones print JSON events, one per line; the last is a
`result` line with the run directory.
"""

import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(REPO, "tools"))
import checks  # noqa: E402
import phonelib  # noqa: E402
from checks import SWIFT_PACKAGES  # noqa: E402
# The app's C pieces that run on this host (app/tests): (name, sources, extra flags).
# A test whose sources include the Madeira checkout (upstream/madeira) is skipped
# where it is not checked out: CI clones without submodules.
PADS = ["app/tests/pads_test.c", "app/Sources/HostIO/hio_pads.c", "upstream/madeira/app/Madeira/Winios/WiniosGamepad.c"]
PADS_FLAGS = ["-Iupstream/madeira/app/Madeira/Winios", "-pthread"]
C_TESTS = [
    ("pads", PADS, PADS_FLAGS),
    ("pads (ThreadSanitizer)", PADS, PADS_FLAGS + ["-fsanitize=thread", "-O1", "-g"]),
    ("host log", ["app/tests/host_log_test.c", "app/Sources/HostIO/host_log.c"], ["-D_DEFAULT_SOURCE"]),
    ("title path", ["app/tests/title_path_test.c", "app/Sources/WineHost/title_path.c"], ["-D_DEFAULT_SOURCE"]),
    ("self-check", ["app/tests/selfcheck_test.c", "app/Sources/WineHost/selfcheck.c"], []),
    ("session protocol", ["app/tests/session_protocol_test.c"], []),
    ("steam tickets", ["app/tests/steam_ticket_test.c", "app/Sources/WineHost/steam_ticket.c"], []),
]


def run(args, **kw):
    return subprocess.call(args, cwd=kw.pop("cwd", REPO), **kw)


def handoff(args):
    """Become ARGS (in the repository): a signal sent to pp (timeout, a harness stopping
    a job) then reaches the tool itself, whose handlers end the app and print a result."""
    sys.stdout.flush()
    sys.stderr.flush()
    os.chdir(REPO)
    os.execvp(args[0], args)


def py(script, args):
    return handoff([sys.executable, os.path.join(REPO, script), *args])


def cmd_secrets(args):
    """Scan the tracked files (the index) for secrets; run before committing evidence or logs."""
    hits = []

    def grep(what, *pattern):
        out = subprocess.run(["git", "-C", REPO, "grep", "-n", "-I", "--cached", *pattern, "--", "."],
                             capture_output=True, text=True).stdout
        hits.extend(f"{what}: {line[:200]}" for line in out.splitlines()
                    if not any(f in line for f in checks.SECRET_FIXTURES))
    for what, pat in checks.SECRETS:
        grep(what, "-E", "-e", pat)
    # The paired phones' UDIDs, from the local pairing records.
    import glob
    for rec in glob.glob(os.path.join(checks.PAIRING_RECORDS, "*.plist")):
        udid = os.path.basename(rec)[:-6]
        if re.fullmatch(r"[0-9A-Fa-f-]{24,40}", udid):
            grep("a paired phone's UDID", "-F", "-e", udid)
    # Words that must never be published (a person's name, a personal address), one per
    # line in the build area, so the repository never names them itself (decision 0043).
    private = os.path.join(os.environ.get("PLAYPORT_BUILD") or os.path.join(REPO, ".work"), "private-words")
    if os.path.isfile(private):
        with open(private) as f:
            for word in (w.strip() for w in f):
                if word and not word.startswith("#"):
                    grep("a private word (private-words)", "-i", "-F", "-e", word)
    files = subprocess.run(["git", "-C", REPO, "ls-files"], capture_output=True, text=True).stdout.splitlines()
    hits.extend(f"secret-bearing file: {f}" for f in files if re.search(checks.SECRET_FILES, f, re.I))
    hits.extend(f"screenshot or recording in evidence (keep it under .work): {f}" for f in files
                if re.search(checks.EVIDENCE_MEDIA, f, re.I))
    for h in hits:
        print(h)
    print(f"pp secrets: {len(hits)} hit(s); redact or explain each before committing" if hits else "pp secrets: clean")
    return 1 if hits else 0


def cmd_names(args):
    """No tracked file (in COMMIT, or the index) names the retired project or its identifier
    prefix, in any letter case. The patterns are split so this file does not match itself."""
    old, prefix = "game" "native", r"\b" "gn[_-]"
    where = [args[0]] if args else ["--cached"]
    hits = subprocess.run(["git", "-C", REPO, "grep", "-n", "-I", "-i", "-e", old, "-e", prefix, *where, "--", "."],
                          capture_output=True, text=True).stdout
    if hits:
        sys.stderr.write(hits)
        print(f"pp names: {len(hits.splitlines())} line(s) use a retired name or prefix", file=sys.stderr)
        return 1
    print("pp names: clean")
    return 0


def cmd_check(args):
    if args in ([], ["--variant", "dev"], ["--variant", "release"]):
        variant = args[1] if args else "dev"
    else:
        print("pp check [--variant dev|release]", file=sys.stderr)
        return 2
    # The app needs its staged runtime and Licenses/; the pipeline stages only what changed
    # (seconds when current, but a tree whose inputs changed is minutes: say so before it starts).
    pipeline = os.path.join(REPO, "build", "pipeline")
    plan = subprocess.run([pipeline, "--plan", "--variant", variant, "--to", "notices"],
                          capture_output=True, text=True).stdout.splitlines()
    trees = [line[len("plan: "):] for line in plan if re.match(r"plan: (unix|pe|fex|dxmt|vulkan|steamapi) runs", line)]
    if trees:
        print("pp check: building the trees whose inputs changed first (minutes, not seconds; a first"
              " build is 10 to 15 minutes):\n  " + "\n  ".join(t.replace(" runs", "", 1) for t in trees), flush=True)
    if any(line.startswith("plan: notices runs") for line in plan):
        print("pp check: collecting the notices first (the first time, about 0.5 GB of locked inputs"
              " are fetched into the cache; docs/BUILDING.md, notices)", flush=True)
    st = run([pipeline, "--variant", variant, "--to", "notices"])
    if st:
        return st
    env = dict(os.environ, PLAYPORT_VARIANT=variant, SWIFTPM_CUSTOM_BIN_DIR=os.path.join(REPO, "build", "ld64"))
    xtool = subprocess.run(["bash", "-c", f". '{REPO}/build/lib.sh' && echo \"$XTOOL\""],
                           capture_output=True, text=True).stdout.strip()
    pkg = os.path.join(REPO, "app")
    if variant == "release":
        st = run([sys.executable, os.path.join(REPO, "build/stages/stage-artifacts.py"), "release"])
        if st:
            return st
        pkg = os.path.join(REPO, "app", ".release")
    t0 = time.monotonic()
    st = run([xtool, "dev", "build"], cwd=pkg, env=env)
    print(f"pp check: {variant} app {'compiles' if st == 0 else 'FAILED'} ({time.monotonic() - t0:.0f} s, unsigned)")
    return st


def patches_check():
    """The Madeira pin against its gitlink, and patches/: series and trailers (checks.patch_problems)."""
    bad = checks.patch_problems(REPO)
    for b in bad:
        print(b)
    return 1 if bad else 0


def swift_test(pkg, extra=()):
    """`swift test` for one of SWIFT_PACKAGES, with its own scratch in the build area."""
    scratch = os.path.join(phonelib.BUILD, "swift-test", os.path.basename(pkg))
    return ["swift", "test", "--build-system", "native", "--scratch-path", scratch, *extra]


def swift_package(name):
    """A SWIFT_PACKAGES entry by its path or its last component (PlayportKit)."""
    return next((p for p in SWIFT_PACKAGES if name.rstrip("/") in (p, os.path.basename(p))), None)


def cmd_test(args):
    failed = []
    # Every test's scratch (tempfile, mkstemp) goes to the build area, not /tmp.
    os.environ["TMPDIR"] = os.path.join(phonelib.BUILD, "tmp")
    os.makedirs(os.environ["TMPDIR"], exist_ok=True)
    if "--swift" in args:
        i = args.index("--swift")
        pkg = swift_package(args[i + 1]) if i + 1 < len(args) else None
        rest = args[:i] + args[i + 2:]
        if not pkg or not (rest == [] or (len(rest) == 2 and rest[0] == "--filter")):
            print(f"pp test --swift PKG [--filter X]: PKG is one of {', '.join(SWIFT_PACKAGES)}", file=sys.stderr)
            return 2
        return run(swift_test(pkg, rest), cwd=os.path.join(REPO, pkg))

    def step(name, argv, **kw):
        """argv: a command, or a function that returns its exit status."""
        t0 = time.monotonic()
        st = argv() if callable(argv) else run(argv, **kw)
        print(f"pp test: {name}: {'ok' if st == 0 else 'FAILED'} ({time.monotonic() - t0:.0f} s)", flush=True)
        if st:
            failed.append(name)
    step("names", [sys.executable, os.path.join(REPO, "pp"), "names"])
    step("secrets", [sys.executable, os.path.join(REPO, "pp"), "secrets"])
    step("patches", patches_check)
    step("tools/tests", [sys.executable, "-m", "unittest", "discover", "-q", "-s", "tools/tests"])
    scratch = os.path.join(phonelib.BUILD, "c-test")
    os.makedirs(scratch, exist_ok=True)
    for name, sources, flags in C_TESTS:
        missing = [s for s in sources if not os.path.exists(os.path.join(REPO, s))]
        if missing and all(s.startswith("upstream/") for s in missing):
            print(f"pp test: C test {name}: skipped (not checked out: {', '.join(missing)})", flush=True)
            continue
        exe = os.path.join(scratch, name.replace(" ", "-").replace("(", "").replace(")", ""))
        step(f"C test {name}", ["sh", "-c", 'clang -std=c11 -O2 -Wall -Wextra -Werror "$@" && { TMPDIR="$T" "$X" > "$X.log" 2>&1 || { tail -20 "$X.log"; exit 1; }; }', "cc",
                                "-Iapp/Sources/HostIO/include", "-Iapp/Sources/WineHost/include", *flags, "-o", exe,
                                *sources], env=dict(os.environ, T=scratch, X=exe))
    step("C test WoW64 window", [sys.executable, os.path.join(REPO, "build/wow64/test.py")])
    if "--quick" not in args:
        for pkg in SWIFT_PACKAGES:
            step(f"swift test {pkg}", swift_test(pkg), cwd=os.path.join(REPO, pkg))
    print("pp test: " + ("all passed" if not failed else "FAILED: " + ", ".join(failed)))
    return 1 if failed else 0


def cmd_phone(args):
    if not args or args[0] in ("-h", "--help"):
        print(__doc__[__doc__.index("  pp phone status"):__doc__.index("Upstream and review")].rstrip())
        return 0
    sub, rest = args[0], args[1:]
    if sub != "lock" and any(a in ("-h", "--help") for a in rest):
        # a DIR or FILE argument would otherwise take the flag as its name
        print(__doc__[__doc__.index("  pp phone status"):__doc__.index("Upstream and review")].rstrip())
        return 0
    ev = phonelib.Events()
    try:
        if sub == "status":
            return phone_status()
        if sub == "lock":
            wait = None
            if rest[:1] == ["--wait"]:
                if len(rest) < 2 or not rest[1].isdigit():
                    print("pp phone lock [--wait S] -- CMD ...", file=sys.stderr)
                    return 2
                wait, rest = int(rest[1]), rest[2:]
            if rest[:1] == ["--"]:
                rest = rest[1:]
            if not rest:
                print("pp phone lock [--wait S] -- CMD ...", file=sys.stderr)
                return 2
            with phonelib.device_lock(" ".join(rest)[:120], wait=wait, events=ev):
                return subprocess.call(rest, env=dict(phonelib.pmd_env(), PLAYPORT_DEVICE_LOCK_HELD="1"))
        if sub == "unattended":
            return phone_unattended(rest, ev)
        if sub == "rest":
            if rest not in ([], ["--if-unattended"]):
                return phonelib.fail(ev, "pp phone rest [--if-unattended]", 2)
            if rest and not phonelib.unattended():
                return ev.result(True, 0, rested=False, why="not unattended")
            out = phonelib.run_dir("phone")
            with phonelib.device_lock("pp phone rest", events=ev):
                pid = phonelib.rest(ev, out)
            return ev.result(True, 0, rested=bool(pid))
        out = phonelib.run_dir("phone")
        with phonelib.device_lock("pp phone " + sub, events=ev):
            phone = phonelib.Phone(out, events=ev).ensure()
            if sub == "kill":
                return ev.result(True, 0, killed=phone.kill())
            if sub == "log":
                dest = rest[0] if rest else out
                path = phone.pull("Documents/s1-host.log", dest)
                lines = phonelib.summarize_log(path, dest)
                return ev.result(bool(path), 0 if path else 1, path=path, timeline=lines[-12:])
            if sub == "ls":
                if len(rest) != 1:
                    return phonelib.fail(ev, "pp phone ls REMOTE (a directory in the app's container: Documents, ...)", 2)
                entries = phone.ls(rest[0])
                print("\n".join(entries), flush=True)
                return ev.result(True, 0, path=rest[0], entries=len(entries))
            if sub == "pull":
                if not rest:
                    return phonelib.fail(ev, "pp phone pull REMOTE [DIR]", 2)
                kind, _ = phone.stat(rest[0])
                if kind == "dir" and rest[0].rstrip("/").endswith(".gputrace"):
                    path = phone.pull_bundle(rest[0], rest[1] if len(rest) > 1 else out)
                    return ev.result(True, 0, path=path)
                if kind in ("absent", "dir"):
                    return phonelib.fail(ev, f"pp phone pull: {rest[0]} " + (
                        "is not in the app's container" if kind == "absent" else
                        "is a directory: pull its files by name (pp phone ls lists them); "
                        "only a Metal .gputrace bundle comes whole")
                        + f"; pp phone ls {os.path.dirname(rest[0].rstrip('/')) or '.'} lists what is there")
                path = phone.pull(rest[0], rest[1] if len(rest) > 1 else out)
                return ev.result(bool(path), 0 if path else 1, path=path,
                                 **({} if path else {"why": phone.pull_error}))
            if sub == "shot":
                path = phone.screenshot(rest[0] if rest else os.path.join(out, "screen.png"))
                return ev.result(bool(path), 0 if path else 1, path=path)
            if sub == "crashes":
                since = None
                if "--since" in rest:
                    i = rest.index("--since")
                    try:
                        since = float(rest[i + 1])
                    except (IndexError, ValueError):
                        return phonelib.fail(ev, "pp phone crashes [DIR] [--since UNIX_TIME]", 2)
                    rest = rest[:i] + rest[i + 2:]
                files = phone.crashes(rest[0] if rest else os.path.join(out, "crashes"), since)
                return ev.result(True, 0, files=files)
        print(f"pp phone: no subcommand {sub}", file=sys.stderr)
        return 2
    except phonelib.PhoneError as e:
        return phonelib.fail(ev, str(e))


def phone_unattended(args, ev):
    """pp phone unattended on [--hours N] | off | status (tools/phonelib.py, unattended mode)."""
    usage = "pp phone unattended on [--hours N] | off | status"
    if args in ([], ["status"]):
        return ev.result(True, 0, unattended=phonelib.unattended())
    if args == ["off"]:
        phonelib.set_unattended(0)
        return ev.result(True, 0, unattended=None)
    if args[:1] != ["on"] or len(args) not in (1, 3) or (len(args) == 3 and args[1] != "--hours"):
        return phonelib.fail(ev, usage, 2)
    try:
        hours = float(args[2]) if len(args) == 3 else 12
    except ValueError:
        return phonelib.fail(ev, usage, 2)
    if not 0 < hours <= 72:
        return phonelib.fail(ev, "pp phone unattended on --hours N: N from 0 to 72", 2)
    rec = phonelib.set_unattended(hours)
    out = phonelib.run_dir("phone")
    with phonelib.device_lock("pp phone unattended on", events=ev):
        pid = phonelib.rest(ev, out)
    return ev.result(True, 0, unattended=rec, rested=bool(pid))


def phone_status():
    """One JSON object: reachable, the app and whether it runs, its battery, the last install,
    the lock holder (with its command)."""
    s = {"device_dir": phonelib.DEVICE_DIR, "holder": phonelib.holder(), "installed": phonelib.installed(),
         "unattended": phonelib.unattended()}
    if s["installed"]:
        s["installed"]["this_checkout"] = phonelib.same_checkout(s["installed"], REPO)
    phone = phonelib.Phone()
    try:
        devs = phone.devices()
        s["phones"] = len(devs)
        if len(devs) == 1:
            d = devs[0]
            s["phone"] = {k: d.get(k) for k in ("ConnectionType", "ProductType", "ProductVersion")}
            # without its team prefix (a secret); pp phone ls and pull reach its container
            s["app"] = phone.bundle_id().split(".", 1)[1]
            s["app_pid"] = phone.pid()
            s["battery"] = phone.battery()
            text = phone.pmd("disk", "lockdown", "get", "--domain", "com.apple.disk_usage", check=False)
            try:
                s["free_gb"] = round(json.loads(text[text.index("{"):text.rindex("}") + 1])["AmountDataAvailable"] / 1e9, 1)
            except (ValueError, KeyError):
                pass
        elif not devs:
            s["error"] = f"no phone on {phonelib.SOCK}: wake and unlock it, check it is on the same network (or cabled)"
    except phonelib.PhoneError as e:
        s["error"] = str(e)
    print(json.dumps(s, indent=1))
    return 0 if s.get("phones") == 1 else 3


def pin(name):
    for line in open(os.path.join(REPO, "pins.lock")):
        f = line.split()
        if len(f) > 1 and f[0] == name:
            return f[1]
    raise SystemExit(f"pins.lock has no {name}")


def cmd_shaders(args):
    """pp shaders TITLE_DIR OUT [--match REGEX] [--jobs N] [--scan SCAN] [--llvm BIN]: without --scan,
    build (or reuse) the host airconv `scan-port` next to the build's AIR helpers, from the dxmt tree
    `pp build` cloned, and verify with that LLVM 15."""
    if not args or args[0] in ("-h", "--help"):
        print(cmd_shaders.__doc__)
        return py("build/air-helpers/probe/title_shaders.py", ["--help"])
    args = list(args)
    air = os.path.join(phonelib.BUILD, "cache", "air-helpers-" + pin("llvm-project").removeprefix("llvmorg-"))
    if "--scan" in args:
        i = args.index("--scan")
        scan = args[i + 1]
        del args[i:i + 2]
    else:
        scan = os.path.join(air, "host", "scan-port")
        helper = os.path.join(REPO, "build", "air-helpers")
        stamp = [pin("dxmt")] + [hashlib.sha256(open(os.path.join(helper, p), "rb").read()).hexdigest()
                                 for p in ("air-helper-port.sh", "probe/airconv_scan.cpp")]
        stamp_file = os.path.join(air, "host", "stamp")
        if not (os.path.exists(scan) and os.path.exists(stamp_file) and open(stamp_file).read().split() == stamp):
            dxb = os.path.join(phonelib.BUILD, "run", "dxmt-run")
            stages = ["host"] if os.path.exists(os.path.join(air, "llvm15", "bin", "llvm-as")) else ["llvm", "air", "host"]
            log = os.path.join(air, "host.log")
            os.makedirs(air, exist_ok=True)
            print(f"pp shaders: building scan-port ({' '.join(stages)}; log: {log})", flush=True)
            # The build's lock: dxmt-run is the pipeline's tree.
            with open(os.path.join(phonelib.BUILD, "run.lock"), "w") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    print("pp shaders: a build is using the run directory; run this after it", file=sys.stderr)
                    return 1
                with open(log, "w") as out:
                    st = run(["bash", os.path.join(helper, "air-helper-port.sh"), air, *stages],
                             env=dict(os.environ, DXMT_BUILD_ROOT=dxb), stdout=out, stderr=subprocess.STDOUT)
            if st:
                subprocess.call(["tail", "-25", log])
                print(f"pp shaders: scan-port build FAILED ({log})", file=sys.stderr)
                return st
            with open(stamp_file, "w") as f:
                f.write("\n".join(stamp) + "\n")
    if "--llvm" not in args and os.path.isdir(os.path.join(air, "llvm15", "bin")):
        args += ["--llvm", os.path.join(air, "llvm15", "bin")]
    return py("build/air-helpers/probe/title_shaders.py", [scan, *args])


COMMANDS = {
    "setup": lambda a: __import__("machine").main(a),
    "build": lambda a: handoff([os.path.join(REPO, "build", "pipeline"), *a]),
    "install": lambda a: handoff([os.path.join(REPO, "build", "install"), *a]),
    "check": cmd_check,
    "verify": lambda a: py("build/verify-ipa.py", a),
    "release": lambda a: py("build/release.py", a),
    "test": cmd_test,
    "names": cmd_names,
    "secrets": cmd_secrets,
    "ui": lambda a: py("tools/ui.py", a),
    "perf": lambda a: __import__("perf").main(a),
    "pad": lambda a: __import__("pad").main(a),
    "gpu": lambda a: __import__("gpu").main(a),
    "phone": cmd_phone,
    "sync": lambda a: py("tools/sync.py", a),
    "rebase": lambda a: py("tools/rebase.py", a),
    "slots": lambda a: __import__("slots").main(a),
    "shaders": cmd_shaders,
    "registry": lambda a: py("app/tools/prefix-registry.py", a),
    "source": lambda a: py("build/source-bundle.py", a),
    "notices": lambda a: handoff(["bash", os.path.join(REPO, "build", "notices-assemble.sh"), *a]),
}


def usage(name):
    """The docstring's lines for `pp NAME`, with their continuation lines."""
    out, on = [], False
    for line in __doc__.splitlines():
        if line.startswith("  pp "):
            on = line.split()[1] == name
        elif not line.startswith("    "):
            on = False
        if on:
            out.append(line)
    return "\n".join(out)


# Commands with no --help of their own: without this, `pp test --help` runs the tests,
# `pp names --help` prints git grep's usage and `pp notices --help` makes a directory.
OWN_HELP_MISSING = ("check", "test", "names", "secrets", "notices")


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    cmd = COMMANDS.get(sys.argv[1])
    if not cmd:
        print(f"pp: no command {sys.argv[1]} (pp --help)", file=sys.stderr)
        return 2
    if sys.argv[1] in OWN_HELP_MISSING and any(a in ("-h", "--help") for a in sys.argv[2:]):
        print(usage(sys.argv[1]))
        return 0
    try:
        return cmd(sys.argv[2:])
    except phonelib.PhoneError as e:
        print(f"pp {sys.argv[1]}: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
