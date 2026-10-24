# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/ui.py (pp ui): the launch environment, and a dry run that only
launches: the app's built-in helper provides JIT, the workstation nothing."""

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest

TOOLS = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def load():
    path = os.path.join(TOOLS, "ui.py")
    loader = importlib.machinery.SourceFileLoader("ui_device_run", path)
    spec = importlib.util.spec_from_loader("ui_device_run", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class UiEnvTest(unittest.TestCase):
    def test_env(self):
        m = load()
        env = m.ui_env("n1", play="app-292030", pad=True)
        self.assertEqual(env, ["S1_MODE=ui", "TITLE_NONCE=n1", "UI_ACTIONS=play:app-292030", "HIO_VPAD=vpad.txt"])

    def dry(self, *args):
        m = load()
        out = io.StringIO()
        with tempfile.TemporaryDirectory() as d, contextlib.redirect_stdout(out):
            argv = sys.argv
            sys.argv = ["ui.py", "--dry-run", "--out", d, *args]
            try:
                self.assertEqual(m.main(), 0)
            finally:
                sys.argv = argv
        return out.getvalue()

    def test_open_takes_a_page_section(self):
        m = load()
        for ok in ("open:settings", "open:app-367520", "open:app-367520#steam", "open:dir-my game#files",
                   "open:settings#diagnostics", "open:settings#pairing", "open:settings#steam",
                   "open:settings#graphics", "open:settings#setup", "open:settings#developer", "open:licences",
                   "open:licences#wine", "open:licences#gnutls"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        for bad in ("open:settings#nope", "open:app-367520#", "open:app-367520#Steam", "open:app-367520#a#b",
                    "open:licences#Wine", "open:licences#"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)

    def test_open_names_the_gamepad_screens_and_pad_presses_buttons(self):
        m = load()
        for screen in m.SCREENS:
            self.assertEqual(m.parse(["--action", f"open:{screen}"]).action, [f"open:{screen}"])
        self.assertEqual(m.parse(["--action", "open:licences#wine"]).action, ["open:licences#wine"])
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            m.parse(["--action", "open:installed"])   # the old tab, now open:library
        for ok in ("pad:a", "pad:rb", "pad:down+down+a", "pad:menu+b", "pad:lb+right"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        for bad in ("pad:", "pad:start", "pad:a+", "pad:a b", "pad:A"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)

    def test_queue_and_downloading_take_an_app_id(self):
        m = load()
        for ok in ("queue:2494780", "downloading:2494780", "install:367520", "install:gog-1104084973@123",
                   "install:epic-Hazelnut", "install:epic-65d73e3be8824829b5b788bd849b6559", "open:epic-Hazelnut",
                   "verify:epic-Hazelnut", "uninstall:epic-65d73e3be8824829b5b788bd849b6559"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        for bad in ("queue:app-2494780", "downloading:", "queue:12a", "install:epic-", "install:epic-a/b", "install:gog-x"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)

    def test_actions_after_a_play_run_after_the_restart(self):
        """play: with actions after it: they run in the restarted process; the title's end does
        not end the run, the UI's does."""
        m = load()
        for ok in ("play:app-367520", "probe:relaunch", "probe:helper-kill-hold", "probe:helper-report", "probe:native-auth",
                   "probe:pairing", "probe:pairing-cancel", "probe:pairing-use", "probe:pairing-isolation",
                   "jit:setup", "jit:pair", "jit:continue", "jit:open-settings", "jit:cancel", "jit:wait",
                   "probe:settings-url-0", "probe:settings-url-5"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        for bad in ("play:367520", "back:library", "relaunch-play:app-367520", "probe:helper-hold",
                    "probe:pairing-use-extra", "probe:pairing-delete", "probe:native-auth-extra", "jit:delete", "jit:pair-extra", "probe:settings-url-", "probe:settings-url-12"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)
        title = {"event": "title-done", "outcome": "pool=exhausted:head still-running after_s=14"}
        ui = {"event": "ui-done", "outcome": "ok actions=3"}
        after = ["set:jitPoolSimulatedMB=184", "play:app-367520", "open:settings"]
        self.assertFalse(m.ends_run(title, after, None))
        self.assertTrue(m.ends_run(ui, after, None))
        self.assertTrue(m.ends_run(title, ["play:app-367520"], None))
        self.assertFalse(m.ends_run(ui, ["play:app-367520"], None))
        self.assertTrue(m.ends_run({"event": "ui-done", "outcome": "action=play:app-367520 failed"},
                                   ["play:app-367520"], None))
        self.assertTrue(m.ends_run(ui, ["open:settings"], None))
        self.assertTrue(m.ends_run(title, ["open:settings"], "app-367520"))
        self.assertFalse(m.ends_run(ui, ["open:settings"], "app-367520"))
        two = ["play:app-1654660", "play:app-367520"]
        self.assertFalse(m.after_play(two))
        self.assertFalse(m.ends_run(title, two, None, 1))
        self.assertTrue(m.ends_run(title, two, None, 2))
        env = m.ui_env("n1", play="app-367520", extra=after)
        self.assertIn("UI_ACTIONS=" + ",".join(after + ["play:app-367520"]), env)

    def test_the_in_game_menu_runs_while_the_game_does(self):
        """wait: and menu: after a play: act on the running game: a run that ends with
        menu:quit ends with the title, one that goes on after it with the UI's done."""
        m = load()
        for ok in ("wait:10", "wait:600", "menu:open", "menu:resume", "menu:screenshot", "menu:overlay",
                   "menu:controller", "menu:quit"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        for bad in ("wait:", "wait:1000", "wait:a", "menu:", "menu:close", "menu:Quit"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)
        title = {"event": "title-done", "outcome": "exit=0x00000000 after_s=30"}
        ui = {"event": "ui-done", "outcome": "ok actions=5"}
        quit = ["play:app-367520", "wait:10", "menu:open", "pad:down", "menu:quit"]
        self.assertEqual(m.in_game(quit, 1), 4)
        self.assertFalse(m.after_play(quit))
        self.assertTrue(m.ends_run(title, quit, None))
        self.assertFalse(m.ends_run(ui, quit, None))
        home = quit + ["open:home"]
        self.assertTrue(m.after_play(home))
        self.assertFalse(m.ends_run(title, home, None))
        self.assertTrue(m.ends_run(ui, home, None))
        resume = ["play:app-367520", "menu:open", "menu:resume"]
        self.assertFalse(m.after_play(resume))
        self.assertTrue(m.ends_run(ui, resume, None))       # the UI is done while the game runs on
        # web: acts on a page the running game opened
        for ok in ("web:wait", "web:close", "web:click:Allow", "web:click:Sign in", "web:click:Not-now_2.x"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        for bad in ("web:", "web:open", "web:click:", "web:click:a,b", "web:click:<b>", "web:click:x\"y"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)
        web = ["play:epic-8337d1f975514d35ad0c1176e8a29f26", "web:wait", "web:click:Allow", "wait:30", "web:close"]
        self.assertEqual(m.in_game(web, 1), 4)
        self.assertFalse(m.after_play(web))
        self.assertTrue(m.ends_run(title, web, None))
        self.assertTrue(m.after_play(web + ["open:home"]))
        # tap: is a finger on the running game's screen (a guest window while one is shown)
        for ok in ("tap:0.5:0.5", "tap:0:1", "tap:1.0:0.25"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        for bad in ("tap:", "tap:0.5", "tap:0.5,0.5", "tap:1.5:0", "tap:-0.1:0", "tap:a:b"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)
        launcher = ["play:app-203160", "wait:20", "tap:0.5:0.5", "wait:60"]
        self.assertEqual(m.in_game(launcher, 1), 3)
        self.assertFalse(m.after_play(launcher))
        # pad: after a play: without the menu is an action for the restarted process, as before
        self.assertEqual(m.in_game(["play:app-367520", "pad:a"], 1), 0)
        self.assertTrue(m.after_play(["play:app-367520", "pad:a"]))

    def test_touch_controls_run_during_play(self):
        m = load()
        for action in ("touch:A", "touch:A+ls-left@500", "touch:RT+Back@10000"):
            self.assertTrue(m.ACTION_RE.match(action), action)
        for action in ("touch:", "touch:A@0", "touch:A@10001", "touch:A++B", "touch:nope"):
            self.assertFalse(m.ACTION_RE.match(action), action)
        actions = ["play:app-367520", "wait:10", "touch:A+ls-left@500", "menu:open", "menu:quit"]
        self.assertEqual(m.in_game(actions, 1), 4)
        self.assertIsNone(m.pad_after_play(actions))
        m.parse(["--action", actions[0], "--action", actions[1], "--action", actions[2]])

    def test_pad_after_play_is_refused_and_settings_arguments_may_be_a_list(self):
        m = load()
        self.assertEqual(m.pad_after_play(["play:app-367520", "wait:10", "pad:a"]), "pad:a")
        self.assertIsNone(m.pad_after_play(["play:app-367520", "wait:10", "menu:open", "pad:down", "menu:quit"]))
        self.assertIsNone(m.pad_after_play(["pad:a", "play:app-367520"]))
        self.assertIsNone(m.pad_after_play(["play:app-367520", "open:home", "pad:a"]))
        with contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
            m.parse(["--action", "play:app-367520", "--action", "wait:5", "--action", "pad:a"])
        self.assertIn("pp ui --pad", err.getvalue())
        a = m.parse(["--settings", 'app-1:{"arguments":["-a","b c","","-d=e"],"graphics":"vulkan"}'])
        self.assertEqual(json.loads(a.settings_pair[1]),
                         {"arguments": '-a "b c" "" -d=e', "graphics": "vulkan"})
        for bad in ('app-1:{"arguments":["a\"b"]}', 'app-1:{"arguments":[1]}', 'app-1:{"arguments":5}'):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                m.parse(["--settings", bad])
        self.assertEqual(m.parse(["--settings", 'app-1:{"arguments":"-x"}']).settings_pair[1], '{"arguments":"-x"}')

    def test_system_alert_detection(self):
        """An iOS alert's captions are found in list-items output; the app's own pages are not."""
        import phonelib
        text = 'log line\n[{"caption": "\\u201cPlayport\\u201d Would Like to Add to Your Photos"}, {"caption": "Don\u2019t Allow, Button"}]\n'
        items = phonelib.accessibility_items(text)
        self.assertEqual(len(items), 2)
        self.assertIn("Would Like to", phonelib.system_alert_in(items))
        app = [{"caption": "Library, Button"}, {"caption": "Not installed"}, {"caption": "Can't start X"}]
        self.assertIsNone(phonelib.system_alert_in(app))
        self.assertEqual(phonelib.accessibility_items("no json"), [])
        self.assertEqual(phonelib.accessibility_items("[broken"), [])

    def test_watch_launch_stops_on_an_alert_after_quiet_events(self):
        import phonelib
        class FakePhone:
            def run_events(self, nonce): return []
            def pid(self): return 1
        events = lambda *a, **k: None
        calls = []
        old = phonelib.ALERT_QUIET_S
        phonelib.ALERT_QUIET_S = 0
        try:
            why, done = phonelib.watch_launch(FakePhone(), events, "n", 1, ("done", None, 0), 30, poll=0.01,
                                              alert_check=lambda: calls.append(1) or "Not Installed")
        finally:
            phonelib.ALERT_QUIET_S = old
        self.assertEqual((why, done), ("alert", {"alert": "Not Installed"}))
        self.assertEqual(len(calls), 1)

    def test_afc_rm_deletes_only_a_zip_in_documents(self):
        spec = importlib.util.spec_from_file_location("afc_tool", os.path.join(TOOLS, "afc.py"))
        afc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(afc)
        self.assertIsNone(afc.rm_refusal("Documents/sockprobe.zip"))
        for bad in ("Documents/prefix", "Documents/s1-host.log", "Documents/prefix/a.zip", "Documents/../x.zip",
                    "Documents/.zip", "Documents/", "x.zip", "Documents/Playport-PLA-147.ipa"):
            self.assertIsNotNone(afc.rm_refusal(bad), bad)

    def test_jit_unreachable_is_its_own_failure(self):
        """LocalDevVPN off: the app's launch outcome names the helper's timeout; a person must act."""
        m = load()
        done = ("launch=failed runtime=JIT pool (896 MiB): built-in JIT: JIT helper: The device is not ready "
                "for JIT: Timed out connecting to 10.7.0.1:49152.")
        self.assertTrue(m.JIT_UNREACHABLE_RE.search(done))
        self.assertFalse(m.JIT_UNREACHABLE_RE.search("launch=failed exit=0xc0000005"))
        self.assertEqual((m.JIT_UNREACHABLE["why"], m.JIT_UNREACHABLE["exit"]), ("jit-unreachable", 4))

    def test_selfcheck_in_the_result(self):
        """The last selfcheck verdict (the pool's) and ntdll's TEB slot go on the result line."""
        m = load()
        timeline = ["[12:00:00.000] title: selfcheck: ok page=16384 tsd=key 5 slot 5",
                    "[12:00:00.100] title: +1.20 s surface ready; asking for JIT",
                    "[12:00:04.000] title: selfcheck: ok page=16384 tsd=key 5 slot 5 "
                    "pool=0x102094000+896MiB rw=0x7000000000"]
        self.assertIsNone(m.selfcheck_of(["title: +1.20 s runtime started"]))
        self.assertEqual(m.selfcheck_of(timeline), {
            "report": "ok page=16384 tsd=key 5 slot 5 pool=0x102094000+896MiB rw=0x7000000000"})
        with tempfile.TemporaryDirectory() as d:
            log = os.path.join(d, "s1-host.log")
            with open(log, "wb") as f:
                f.write(b"[teb-tsd] key=284 offset=0x8e0 verified=1 tsd_base=0x1 teb=0x2\n")
            self.assertEqual(m.selfcheck_of(timeline, log)["teb"], "key 284 slot 284")
        refused = ["title: selfcheck: failed page: the host page is 4096 bytes; page=4096 tsd=key 5 slot 5"]
        self.assertTrue(m.selfcheck_of(refused)["report"].startswith("failed page: "))

    def test_pool_use_is_the_last_pool_line(self):
        """The result's `pool` is the launch's last `pool:` line (JitPool.Use.line), a mark or not."""
        m = load()
        line = ("pool: size_mb=896 head_mb=153 head_live_mb=150 head_free_mb=0 tail_mb=144 tail_live_mb=144 "
                "room_mb=599 alias=5 alias_slots=5 alias_cap=4096 images=50 children=0 children_mb=0 "
                "head_exhausted=0 tail_refused=0 tail_fatal=0 alias_full=0 exhausted=none")
        timeline = ["title: jit pool: 896 MiB for a memory limit of 8192 MB",
                    "[12:00:01.000] title: " + line.replace("head_mb=153", "head_mb=40"),
                    "title: +31.20 s " + line + "  (from run-events.jsonl)",
                    "title: done nonce=n exit=0x00000000 after_s=20"]
        use = m.pool_use(timeline)
        self.assertEqual((use["head_mb"], use["tail_mb"], use["alias_cap"], use["exhausted"]), (153, 144, 4096, "none"))
        self.assertIsNone(m.pool_use(["title: jit pool: 896 MiB for a memory limit of 8192 MB"]))

    def test_limits_are_the_last_limits_line(self):
        """The result's `limits` is the launch's last `limits:` line (RuntimeLimits.Counts.line)."""
        m = load()
        timeline = ["[12:00:01.000] title: limits: wx_dropped=0 x18_images=0 x18_sites=0 split_lock=0",
                    "title: +31.20 s limits: wx_dropped=0 x18_images=1 x18_sites=12 split_lock=3"
                    "  (from run-events.jsonl)",
                    "title: done nonce=n exit=0x00000000 after_s=20"]
        self.assertEqual(m.limits_of(timeline), {"wx_dropped": 0, "x18_images": 1, "x18_sites": 12, "split_lock": 3})
        self.assertIsNone(m.limits_of(["title: jit pool: 896 MiB for a memory limit of 8192 MB"]))

    def test_band_is_the_last_band_line(self):
        """The result's `band` is the launch's last `band:` line (FexBand.Use.line)."""
        m = load()
        line = ("band: size_mb=16384 used_mb=5121 peak_mb=6144 free_mb=11263 largest_free_mb=4096 "
                "span_slots=256 threads=54 spans=120 l1=54 other_mb=3 views=300 refused=0")
        timeline = ["[12:00:01.000] title: " + line.replace("threads=54", "threads=20"),
                    "title: +31.20 s " + line + "  (from run-events.jsonl)",
                    "title: done nonce=n exit=0x00000000 after_s=20"]
        band = m.band_of(timeline)
        self.assertEqual((band["threads"], band["span_slots"], band["refused"]), (54, 256, 0))
        self.assertIsNone(m.band_of(["title: jit pool: 896 MiB for a memory limit of 8192 MB"]))

    def test_a_pool_that_ran_out_is_not_ok(self):
        m = load()
        self.assertTrue(m.title_ok({"outcome": "exit=0x00000000 after_s=12"}))
        self.assertFalse(m.title_ok({"outcome": "pool=exhausted:head exit=0x00000000 after_s=12"}))

    def test_sigterm_ends_the_app_inside_the_lock(self):
        m = load()
        calls = []

        class Phone:
            def kill(self):
                calls.append("kill")
                return True

        @contextlib.contextmanager
        def lock():
            yield
            calls.append("unlock")
        term = m.EndOnTerm(Phone(), leave=False)
        with lock(), term:
            raise m.Terminated("SIGTERM")
        self.assertEqual(calls, ["kill", "unlock"])
        self.assertEqual((term.signal, term.app_ended), ("SIGTERM", True))
        left = m.EndOnTerm(Phone(), leave=True)
        with left:
            raise m.Terminated("SIGHUP")
        self.assertEqual(calls, ["kill", "unlock"])
        import signal
        signal.signal(signal.SIGTERM, signal.SIG_DFL)

    def test_play_only_launches(self):
        text = self.dry("--play", "app-292030")
        self.assertIn("dvt launch", text)
        self.assertIn("--env UI_ACTIONS=play:app-292030", text)
        self.assertNotIn("S1_JIT=", text)
        self.assertNotIn("socat", text)

    def test_settings_come_before_the_play(self):
        env = load().ui_env("n1", play="app-367520", settings=("app-367520", '{"frameLimit":30}'))
        self.assertIn("UI_ACTIONS=settings:app-367520,play:app-367520", env)
        self.assertIn('UI_SETTINGS={"frameLimit":30}', env)
        with self.assertRaises(SystemExit):
            with contextlib.redirect_stderr(io.StringIO()):
                self.dry("--settings", "app-367520:[1]")

    def test_play_and_settings_take_an_epic_app_name_with_capitals(self):
        m = load()
        self.assertEqual(m.parse(["--play", "epic-Buffalo"]).play, "epic-Buffalo")
        a = m.parse(["--settings", 'epic-Buffalo:{"frameLimit":30}', "--verify", "epic-Buffalo"])
        self.assertEqual(a.settings_pair, ("epic-Buffalo", '{"frameLimit":30}'))
        for bad in ("Epic-Buffalo", "epic-", "epic-a/b", "367520"):
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                m.parse(["--play", bad])

    def test_session_and_kept_settings_reach_the_app(self):
        env = load().ui_env("n1", extra=["set:metalHUD=true"], session="s1", keep_settings=True)
        self.assertIn("UI_SESSION=s1", env)
        self.assertIn("UI_KEEP_SETTINGS=1", env)
        self.assertFalse(any(e.startswith(("UI_SESSION", "UI_KEEP")) for e in load().ui_env("n1")))

    def test_refuses_an_ipa_another_checkout_installed(self):
        import json
        import subprocess
        with tempfile.TemporaryDirectory() as d:
            # A pymobiledevice3 that finds no phone: the refusal must come first, and nothing
            # may reach a real device if it does not.
            stub = os.path.join(d, "bin")
            os.makedirs(stub)
            with open(os.path.join(stub, "pymobiledevice3"), "w") as f:
                f.write("#!/bin/sh\nexit 1\n")
            os.chmod(os.path.join(stub, "pymobiledevice3"), 0o755)
            with open(os.path.join(d, "device-state.json"), "w") as f:
                json.dump({"ipa_sha256": "ab" * 32, "checkout": "/another/checkout", "head": "1234567"}, f)
            env = {k: v for k, v in os.environ.items() if not k.startswith("PLAYPORT_DEVICE")}
            env.update(PLAYPORT_DEVICE_DIR=d, PLAYPORT_BUILD=d, PLAYPORT_USBMUX_SOCKET=os.path.join(d, "no.sock"),
                       PATH=stub + os.pathsep + os.environ["PATH"])
            r = subprocess.run([sys.executable, os.path.join(TOOLS, "ui.py"), "--out", os.path.join(d, "run"),
                                "--action", "open:settings"], capture_output=True, text=True, env=env)
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            last = json.loads(r.stdout.strip().splitlines()[-1])
            self.assertEqual(last["event"], "result")
            self.assertIn("/another/checkout", r.stderr)
            self.assertNotIn("launched", r.stdout)


class LastPlay(unittest.TestCase):
    """A play records its end for pp perf --cool; actions without one do not."""

    def test_played(self):
        ui = load()
        self.assertTrue(ui.played(["--play", "app-367520"]))
        self.assertTrue(ui.played(["--action", "play:app-367520"]))
        self.assertFalse(ui.played(["--action", "open:settings"]))

    def test_wait_bounds(self):
        ui = load()
        self.assertEqual(ui.parse(["--play", "app-1", "--wait", "40"]).idle, 0)
        self.assertEqual(ui.parse(["--idle", "90"]).idle, 90)
        self.assertEqual(set(ui.STOP_BOUND), set(ui.STOP_WHY))
        self.assertTrue(ui.plays(ui.parse(["--play", "app-1"])))
        self.assertFalse(ui.plays(ui.parse(["--action", "open:settings"])))


class UntilReached(unittest.TestCase):
    """A title that ends cleanly before --until fails; last-play.json needs a launched play."""

    class FakePhone:
        def __init__(self, *a, **k): pass
        def ensure(self): pass
        def bundle_id(self): return "x"
        def kill(self): return False
        def rotate_log(self): pass
        def launch(self, envs): return 1
        def pid(self): return None
        def pull(self, *a, **k): return None
        def run_events(self, nonce): return []
        def screenshot(self, path): return path
        def system_alert(self): return None

    def run_ui(self, argv, events, why="done"):
        """main_recorded's result event and exit code with the app events replayed."""
        import phonelib
        m = load()
        done = next((e for e in events if e.get("event") == "title-done"), None)

        def watch(phone, ev, nonce, pid, until, wait, poll, done_events, is_done, quiet, on_event, *rest):
            for e in events:
                on_event(e)
                is_done(e)
            return (why, done) if done else ("until", None)
        saved = (phonelib.Phone, phonelib.watch_launch, phonelib.installed_check, phonelib.device_lock, m.LAST_PLAY)
        out = io.StringIO()
        with tempfile.TemporaryDirectory() as d:
            phonelib.Phone, phonelib.watch_launch = self.FakePhone, watch
            phonelib.installed_check = lambda *a: (True, None, None)
            phonelib.device_lock = lambda *a, **k: contextlib.nullcontext()
            m.LAST_PLAY = os.path.join(d, "last-play.json")
            try:
                with contextlib.redirect_stdout(out):
                    code = m.main_recorded(["--out", d, *argv])
            finally:
                phonelib.Phone, phonelib.watch_launch, phonelib.installed_check, phonelib.device_lock = saved[:4]
            recorded = os.path.exists(m.LAST_PLAY)
        result = json.loads(out.getvalue().strip().splitlines()[-1])
        return code, result, recorded

    CLEAN = {"event": "title-done", "outcome": "ok exit=0x00000000"}
    FRAME = {"event": "mark", "what": "first frame"}

    def test_clean_exit_before_the_checkpoint_fails(self):
        code, r, recorded = self.run_ui(["--play", "app-1", "--until", "first-frame+10"], [self.CLEAN])
        self.assertEqual((code, r["ok"], r["until_reached"]), (1, False, False))
        self.assertIn("before --until first-frame+10", r["why"])
        self.assertTrue(recorded)

    def test_clean_exit_after_the_checkpoint_passes(self):
        code, r, _ = self.run_ui(["--play", "app-1", "--until", "first-frame+10"], [self.FRAME, self.CLEAN])
        self.assertEqual((code, r["ok"], r["until_reached"]), (0, True, True))

    def test_until_done_is_the_clean_exit(self):
        code, r, _ = self.run_ui(["--play", "app-1"], [self.CLEAN])
        self.assertEqual((code, r["ok"], r["until_reached"], r["until"]), (0, True, True, "done"))

    def test_checkpoint_reached_before_the_watch_ends(self):
        code, r, _ = self.run_ui(["--play", "app-1", "--until", "first-frame+10"], [self.FRAME])
        self.assertEqual((code, r["ok"], r["until_reached"]), (0, True, True))

    def test_last_play_needs_a_launched_play(self):
        _, _, recorded = self.run_ui(["--action", "open:settings"], [{"event": "ui-done", "outcome": "ok"}])
        self.assertFalse(recorded)
        m = load()
        with tempfile.TemporaryDirectory() as d:
            m.LAST_PLAY = os.path.join(d, "last-play.json")
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    m.main_recorded(["--play", "app-1", "--until", "nonsense"])
            self.assertFalse(os.path.exists(m.LAST_PLAY))


if __name__ == "__main__":
    unittest.main()
