# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/ui.py (pp ui): the launch environment, and a dry run that only
launches: the app's built-in helper provides JIT, the workstation nothing."""

import contextlib
import importlib.machinery
import importlib.util
import io
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
                   "probe:pairing", "probe:pairing-cancel", "probe:pairing-use",
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
        # pad: after a play: without the menu is an action for the restarted process, as before
        self.assertEqual(m.in_game(["play:app-367520", "pad:a"], 1), 0)
        self.assertTrue(m.after_play(["play:app-367520", "pad:a"]))

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


if __name__ == "__main__":
    unittest.main()
