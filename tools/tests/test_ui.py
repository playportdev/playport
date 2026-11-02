# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/ui.py (pp ui): the launch environment, and a dry run that only
launches: the app's built-in helper provides JIT, the workstation nothing."""

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import re
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

    def test_read_only_game_option_targets(self):
        m = load()
        actions = ["open:app-367520#runtime", "open:app-367520#graphicsoptions"]
        for action in actions:
            self.assertEqual(m.parse(["--action", action]).action, [action])
            text = self.dry("--action", action)
            self.assertIn("UI_ACTIONS=" + action, text)
            self.assertNotIn("pad:", text)
            self.assertNotIn("UI_SETTINGS=", text)
        for section in ("graphics", "controls", "game", "files", "developer", "ordering", "steam", "gyro", "controller"):
            self.assertEqual(m.parse(["--action", "open:dir-my game#" + section]).action,
                             ["open:dir-my game#" + section])
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            m.parse(["--action", "open:app-367520#nope"])
        self.assertIn("open:ID#runtime", m.__doc__)
        self.assertIn("open:ID#graphicsoptions", m.__doc__)

    def test_open_black_is_the_last_action_only(self):
        """The black screen is a terminal handoff: no action, press or step follows it."""
        m = load()
        for argv, expected in ((["--action", "open:black"], ["open:black"]),
                               (["--action", "open:home", "--action", "open:black"],
                                ["open:home", "open:black"])):
            self.assertEqual(m.parse(argv).action, expected)
        for argv in (["--action", "open:black", "--action", "open:home"],
                     ["--action", "open:black", "--action", "open:black"],
                     ["--action", "open:black", "--play", "app-367520"],
                     ["--action", "open:black", "--verify", "app-367520"],
                     ["--action", "open:black", "--settings", 'app-367520:{"frameLimit":30}']):
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                m.parse(argv)
        self.assertIn("open:black ends the batch", m.__doc__)

    @staticmethod
    def normalize_row(target):
        # Both copies interpolate the ordering row's first setting; compare the shape.
        return re.sub(r"\\\([^)]*\)", "{first}", target.strip())

    def dev_sections(self):
        """The dev-only enum's real case list and each case's row target."""
        path = os.path.join(TOOLS, "..", "app", "Sources", "S1Probe", "Dev", "UIDriverGameSection.swift")
        with open(path) as f:
            text = f.read()
        declared = re.search(r"enum UIDriverGameSection: String, CaseIterable \{\n\s*case ([a-z, ]+)\n", text)
        self.assertIsNotNone(declared, "the dev enum's case list moved: update this test")
        cases = [n.strip() for n in declared.group(1).split(",")]
        rows = {}
        for case in re.finditer(r"^\s*case ((?:\.\w+)(?:, \.\w+)*): (.+)$", text, re.M):
            for name in case.group(1).split(","):
                rows[name.strip().lstrip(".")] = self.normalize_row(case.group(2))
        return cases, rows

    def release_sections(self):
        """The `firstRow(ofSection:)` release copy's real section names and row targets."""
        path = os.path.join(TOOLS, "..", "app", "Sources", "S1Probe", "UI", "GameDetailView.swift")
        with open(path) as f:
            text = f.read()
        function = re.search(r"private static func firstRow\(ofSection s: String\) -> String\? \{\n(.*?)\n    \}\n",
                             text, re.S)
        self.assertIsNotNone(function, "firstRow(ofSection:) moved or was removed: update this test")
        guarded = function.group(1).split("#else")
        self.assertEqual(len(guarded), 2, "firstRow lost its #if !PLAYPORT_RELEASE / #else split")
        rows = {}
        for case in re.finditer(r'^\s*case ((?:"[^"]+"(?:, "[^"]+")*)): (.+)$', guarded[1], re.M):
            for name in re.findall(r'"([^"]+)"', case.group(1)):
                rows[name] = self.normalize_row(case.group(2))
        return rows

    def test_the_three_section_vocabularies_agree(self):
        """Dev enum, release copy and pp ui's set: same members, same row per section."""
        m = load()
        cases, dev = self.dev_sections()
        release = self.release_sections()
        self.assertGreaterEqual(len(cases), 7, "the dev enum parse found too few sections")
        self.assertEqual(len(cases), len(set(cases)), "duplicate section in the dev enum")
        self.assertEqual(set(cases), set(dev), "a dev case has no row target")
        self.assertEqual(len(dev), len(release), "the release copy names different sections than the dev enum")
        self.assertEqual(dev, release, "a section's target row drifted between the dev enum and the release copy")
        self.assertEqual(len(m.GAME_SECTIONS), len(set(m.GAME_SECTIONS)),
                         "duplicate section in pp ui's GAME_SECTIONS")
        self.assertEqual(set(m.GAME_SECTIONS), set(cases), "pp ui and the dev enum name different sections")

    def test_open_names_the_gamepad_screens_and_pad_presses_buttons(self):
        m = load()
        for screen in m.SCREENS:
            self.assertEqual(m.parse(["--action", f"open:{screen}"]).action, [f"open:{screen}"])
        self.assertEqual(m.parse(["--action", "open:licences#wine"]).action, ["open:licences#wine"])
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            m.parse(["--action", "open:steam"])   # Steam's store button is open:games
        for ok in ("pad:a", "pad:rb", "pad:lt", "pad:down+down+a", "pad:menu+b", "pad:lb+right"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        for bad in ("pad:", "pad:start", "pad:a+", "pad:a b", "pad:A", "pad:l2"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)

    def test_donor_pool_setting_takes_auto_and_fixed_sizes(self):
        # Settings › Developer › Donor pool (PLA-351): set:'s generic KEY=VALUE carries auto.
        m = load()
        for v in ("0", "auto", "2048", "4096", "6144"):
            self.assertEqual(m.parse(["--action", f"set:donorPoolMB={v}"]).action, [f"set:donorPoolMB={v}"])
        self.assertFalse(m.ACTION_RE.match("set:donorPoolMB=auto,play:app-367520"))

    def test_set_takes_an_empty_value(self):
        # set:KEY= stores "" (UIDriver keeps the empty value), as --help documents for
        # set:controls.suggestedLayoutOffered= (forgets the offered layouts) and the Social Club keys.
        m = load()
        for a in ("set:controls.suggestedLayoutOffered=", "set:endGameSocialClubAfterSignIn="):
            self.assertEqual(m.parse(["--action", a]).action, [a])
        self.assertFalse(m.ACTION_RE.match("set:=x"))

    def test_memory_probe_sizes_are_bounded(self):
        m = load()
        for size in (64, 2048, 4096):
            action = f"probe:memory-{size}"
            self.assertEqual(m.parse(["--action", action]).action, [action])
        for kind in ("tagged", "purgeable"):
            for size in (2048, 4096):
                action = f"probe:memory-donor-{kind}-{size}"
                self.assertEqual(m.parse(["--action", action]).action, [action])
        for action in ("probe:memory-0", "probe:memory-8192", "probe:memory--1", "probe:memory-64-extra", "probe:memory-status",
                       "probe:memory-donor-2048", "probe:memory-donor-tagged-64", "probe:memory-donor-other-2048"):
            self.assertFalse(m.ACTION_RE.match(action), action)

    def test_donor_pool_and_background_actions(self):
        m = load()
        for action in ("probe:memory-donors-6144", "probe:memory-donors-8192", "probe:memory-donors-10240",
                       "probe:memory-pool-verify", "probe:memory-pool-zero", "probe:memory-pool-gpu", "background:10", "background:60", "background:600"):
            self.assertEqual(m.parse(["--action", action]).action, [action])
        for action in ("probe:memory-donors-4096", "probe:memory-donors-", "probe:memory-pool", "probe:memory-pool-gpu-1", "background:",
                       "background:9", "background:601", "background:060", "background:1000"):
            self.assertFalse(m.ACTION_RE.match(action), action)

    def test_background_handoff_never_reactivates(self):
        m = load()
        self.assertEqual(m.background_handoff({"seconds": 60, "pid": 42}),
                         {"seconds": 60, "pid": 42, "automatic_return": False,
                          "reason": "foreground handoff cancels the batch; new session required"})
        # Canonical help must state the terminal handoff contract for both Settings leaves.
        self.assertIn("then cancels the batch", m.__doc__)
        self.assertIn("the batch is cancelled as a handoff", m.__doc__)

    def test_queue_and_downloading_take_an_app_id(self):
        m = load()
        for ok in ("queue:2494780", "downloading:2494780", "install:367520", "install:gog-1104084973@123",
                   "install:epic-Hazelnut", "install:epic-65d73e3be8824829b5b788bd849b6559", "open:epic-Hazelnut",
                   "verify:epic-Hazelnut", "uninstall:epic-65d73e3be8824829b5b788bd849b6559", "repair:app-1174180"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        for bad in ("queue:app-2494780", "downloading:", "queue:12a", "install:epic-", "install:epic-a/b", "install:gog-x", "repair:1174180"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)

    def test_battlenet_store_paths(self):
        """PLA-519: the Battle.net store, a product page, its region picker, install with pause and
        resume, removal, and a size larger than free space for the refusal."""
        m = load()
        for ok in ("open:battlenet", "open:bnet-wow_classic_era", "region:bnet-wow_classic_era", "region:bnet-wow=eu",
                   "install:bnet-wow_classic_era", "pause-resume:bnet-wow_classic_era", "uninstall:bnet-wow_classic_era",
                   "set:battlenetInstallBytes=999000000000", "set:battlenetInstallBytes=0"):
            self.assertEqual(m.parse(["--action", ok]).action, [ok])
        for bad in ("install:bnet-", "install:bnet-WoW", "install:bnet-a/b", "region:bnet-wow=cn", "region:bnet-wow=",
                    "region:wow", "pause-resume:bnet-", "region:epic-Hazelnut"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)

    def test_battlenet_installed_region_and_language_paths(self):
        """PLA-520: an installed product's region changed in place and its language through Downloads,
        or either picker open."""
        m = load()
        for ok in ("region:bnet-wow_classic_era=eu", "region:bnet-wow_classic_era", "locale:bnet-wow_classic_era=deDE",
                   "locale:bnet-wow_classic_era"):
            self.assertEqual(m.parse(["--action", ok]).action, [ok])
        for bad in ("locale:bnet-", "locale:bnet-wow=de", "locale:bnet-wow=dede", "locale:bnet-wow=deDE1", "locale:bnet-wow=",
                    "locale:wow=deDE", "locale:epic-Hazelnut=deDE"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)

    def test_battlenet_notice_and_play_paths(self):
        """PLA-514: a Battle.net copy's ban-risk notice, accepted or declined as the player does, and
        its Play."""
        m = load()
        for ok in ("notice:bnet-wow=accept", "notice:bnet-wow_classic_era=decline", "play:bnet-wow"):
            self.assertEqual(m.parse(["--action", ok]).action, [ok])
        for bad in ("notice:bnet-wow", "notice:bnet-wow=yes", "notice:bnet-=accept", "notice:app-367520=accept",
                    "notice:bnet-WoW=accept"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)

    def test_battlenet_update_check_path(self):
        """PLA-521: an installed product's Check for update from its page, or =install, which also
        downloads the update it found through Downloads."""
        m = load()
        for ok in ("update:bnet-wow", "update:bnet-wow_classic_era", "update:bnet-wow=install"):
            self.assertEqual(m.parse(["--action", ok]).action, [ok])
        for bad in ("update:bnet-", "update:bnet-WoW", "update:bnet-wow=", "update:bnet-wow=yes", "update:wow",
                    "update:app-367520", "update:gog-1207658924"):
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

    def test_open_launcher_is_followed_as_a_play(self):
        """Settings › Launchers' Open (UIDriver open-launcher:) ends the run at the launcher's end, as play: does."""
        m = load()
        for ok in ("open-launcher:rockstar", "open:settings#launchers"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        for bad in ("open-launcher:", "open-launcher:Rock-star", "open-launcher:rockstar,play:app-1"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)
        title = {"event": "title-done", "outcome": "exit=0 after_s=90"}
        ui = {"event": "ui-done", "outcome": "ok actions=1"}
        self.assertTrue(m.ends_run(title, ["open-launcher:rockstar"], None))
        self.assertFalse(m.ends_run(ui, ["open-launcher:rockstar"], None))
        self.assertTrue(m.after_play(["open-launcher:rockstar", "wait:5", "open:settings"]))
        self.assertEqual(m.pad_after_play(["open-launcher:rockstar", "pad:a"]), "pad:a")

    def test_an_accepted_ban_risk_notice_is_followed_as_a_play(self):
        """notice:bnet-CODE=accept goes on into the Play (PLA-514): the game's end, not the UI's,
        ends the run, so --until can match; a decline starts nothing."""
        m = load()
        title = {"event": "title-done", "outcome": "exit=0 after_s=90"}
        ui = {"event": "ui-done", "outcome": "ok actions=1"}
        accept = ["notice:bnet-wow=accept"]
        self.assertFalse(m.ends_run(ui, accept, None))
        self.assertTrue(m.ends_run(title, accept, None))
        self.assertTrue(m.ends_run({"event": "ui-done", "outcome": "action=notice:bnet-wow=accept failed: x"}, accept, None))
        self.assertTrue(m.ends_run(ui, ["notice:bnet-wow=decline"], None))
        self.assertTrue(m.after_play(accept + ["wait:5", "open:settings"]))

    def test_forget_launcher_window_is_a_ui_step_not_a_play(self):
        """Settings \u203a Launchers' Forget the launcher's saved window settings (UIDriver
        forget-launcher-window:) is accepted for a launcher id and is not followed as a play."""
        m = load()
        self.assertTrue(m.ACTION_RE.match("forget-launcher-window:rockstar"))
        for bad in ("forget-launcher-window:", "forget-launcher-window:Rock-star", "forget-launcher-window:../x"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)
        self.assertFalse(m.after_play(["forget-launcher-window:rockstar", "wait:5"]))

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

    def test_touch_presses_the_on_screen_controls_while_the_game_runs(self):
        """touch: is a finger on the running game's on-screen controls (Dev/TouchDriver.swift)."""
        m = load()
        for ok in ("touch:a", "touch:dpad.right@2000", "touch:dpad.right+a@600",
                   "touch:leftStick.up+rightStick.left@10000", "menu:controls", "open:settings#controls",
                   # Keyboard & mouse: the W A S D stick, a look drag while firing, a number key.
                   "touch:move.up@1500", "touch:look.left+fire@400", "touch:1",
                   "open:settings#controllers"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        for bad in ("touch:", "touch:a@", "touch:a.b", "touch:a@123456", "touch:a+", "touch:a,b", "menu:control"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)
        self.assertEqual(m.in_game(["play:app-367520", "touch:a", "pad:a"], 1), 1)

    def test_touch_taps_the_pointer_surface_at_a_point(self):
        """Point & click: pointer:FX:FY is a finger on the pointer surface at that fraction of the view; tools by id."""
        m = load()
        for ok in ("touch:pointer", "touch:pointer:0.25:0.6", "touch:pointer:1:0", "touch:hover+pointer:0.5:0.5@400",
                   "touch:rightClick", "touch:mode", "touch:scroll+pointer:0.5:0.5@1000"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        for bad in ("touch:pointer:0.5", "touch:pointer:1.5:0.5", "touch:pointer:0.5:0.5.up", "touch:pointer:-0.1:0.5",
                    "touch:pointer::0.5"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)

    def test_the_touch_keyboard_opens_from_the_menu_and_its_keys_are_touched(self):
        """menu:keyboard opens the touch keyboard over the game; touch: presses its kb- keys (HostIOKit TouchKeyboard)."""
        m = load()
        for ok in ("menu:keyboard", "touch:kb-shift", "touch:kb-a", "touch:kb-f12", "touch:kb-ctrl+kb-alt+kb-del",
                   "touch:kb-close", "touch:kb-backspace@1000"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        for bad in ("menu:keyboards", "menu:touch-keyboard", "touch:kb-a.up.down"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)
        run = ["play:app-620", "wait:20", "menu:open", "menu:keyboard", "touch:kb-shift", "touch:kb-h", "touch:kb-close"]
        self.assertEqual(m.in_game(run, 1), 6)
        self.assertFalse(m.after_play(run))
        self.assertIn("menu:keyboard", m.__doc__)

    def test_gyro_plays_a_scripted_gyro_while_the_game_runs(self):
        """gyro: plays HostIOKit GyroScript steps into gyro aim (Dev/GyroDriver.swift) while the game runs."""
        m = load()
        for ok in ("gyro:yaw=90@500", "gyro:yaw=90@500/pitch=-30@300", "gyro:pitch=-30+yaw=10.5@300/rest@200",
                   "gyro:roll=45@10000", "gyro:rest@1", "gyro:yaw=2000@1/yaw=-2000@1"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        for bad in ("gyro:", "gyro:yaw=90", "gyro:yaw@500", "gyro:spin=10@100", "gyro:yaw=90@500/", "gyro:yaw=90@500,pitch=1@2",
                    "gyro:yaw=+90@500", "gyro:yaw=90@123456", "gyro:rest", "gyro:yaw=1e3@100"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)
        run = ["play:app-620", "wait:30", "gyro:yaw=90@500", "touch:a", "gyro:rest@100", "open:home"]
        self.assertEqual(m.in_game(run, 1), 4)
        self.assertTrue(m.after_play(run))
        self.assertIsNone(m.pad_after_play(run))
        a = m.parse(["--controls", 'app-620:{"gyro":{"output":"mouse"}}', "--action", "play:app-620",
                     "--action", "gyro:yaw=90@500/rest@300"])
        self.assertEqual(a.action[-1], "gyro:yaw=90@500/rest@300")
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            m.parse(["--action", "gyro:yaw=90"])

    def test_the_gyro_aim_page_and_its_test_area_are_reachable(self):
        """open:ID#gyro opens Game options › Controls › Gyro aim, open:ID#controls its Controls section,
        open:settings#gyro Settings › Controls at its Gyro aim rows; gyro: with no game moves the test area's dot."""
        m = load()
        for ok in ("open:app-620#gyro", "open:app-620#controls", "open:settings#gyro", "menu:controls"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        self.assertFalse(m.ACTION_RE.match("open:settings#gyroaim"))
        a = m.parse(["--action", "open:app-620#gyro", "--action", "gyro:yaw=30@500", "--action", "pad:down+right"])
        self.assertEqual(a.action, ["open:app-620#gyro", "gyro:yaw=30@500", "pad:down+right"])
        self.assertFalse(m.after_play(a.action))
        self.assertIsNone(m.pad_after_play(a.action))
        self.assertIn("open:ID#gyro", m.__doc__)
        self.assertIn("Gyro aim: Off, Mouse, Right stick; Sensitivity", m.__doc__)

    def test_the_controller_page_and_the_action_picker_are_reachable(self):
        """open:ID#controller opens a game's Controller page, open:settings#controller Settings' default's;
        pad: rings rows and drives the ActionPicker there; menu:controls has the Controller row."""
        m = load()
        for ok in ("open:app-620#controller", "open:settings#controller", "menu:controls"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        self.assertFalse(m.ACTION_RE.match("open:settings#controllermap"))
        a = m.parse(["--action", "open:app-620#controller", "--action", "pad:right+right+lb", "--action", "pad:a+rb+a"])
        self.assertEqual(a.action, ["open:app-620#controller", "pad:right+right+lb", "pad:a+rb+a"])
        self.assertIsNone(m.pad_after_play(a.action))
        for text in ("open:ID#controller", "ctl:mode", "ctl:lookSpeed", "ctl:resetAll", "ActionPicker",
                     "controller: Settings › Controls › Controller", "Controller: Pad, Keys &"):
            self.assertIn(text, m.__doc__)

    def test_the_controller_page_ring_and_the_in_game_editor_are_documented(self):
        """The Controller page's ring (touch controls U): every item by the directions, LB/RB the mode,
        A edits, Y resets, B back; and its in-game editor from menu:controls."""
        m = load()
        for text in ("move one ring through every item in every mode", "pad:lb/rb cycle the mode",
                     "pad:y resets it", "Switch to Custom?", "pad:b cancels",
                     "opens the Controller page over the paused game", "pad:b comes back"):
            self.assertIn(text, m.__doc__)
        a = m.parse(["--action", "play:app-620", "--action", "menu:open", "--action", "menu:controls",
                     "--action", "pad:down+down+down+down+down+down+a", "--action", "pad:down+a", "--action", "pad:b+b",
                     "--action", "menu:resume"])
        self.assertIsNone(m.pad_after_play(a.action))

    def test_three_finger_tap_opens_the_menu_so_pad_after_it_is_the_menus(self):
        """gesture:three-finger-tap fires the app's three-finger tap handler (HostIO.menuGesture),
        which opens the in-game menu with or without on-screen controls: pad: after it is the menu's."""
        m = load()
        self.assertTrue(m.ACTION_RE.match("gesture:three-finger-tap"))
        for bad in ("gesture:", "gesture:tap", "gesture:three-finger-tap@100"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)
        run = ["play:app-367520", "wait:20", "touch:a", "touch:dpad.right@2000", "gesture:three-finger-tap", "pad:down",
               "menu:resume", "touch:a"]
        self.assertEqual(m.in_game(run, 1), 7)
        self.assertFalse(m.after_play(run))
        self.assertIsNone(m.pad_after_play(run))
        # A touch: on a control named like the old Playport button no longer opens the menu.
        self.assertEqual(m.in_game(["play:app-367520", "touch:playport", "pad:a"], 1), 1)
        self.assertEqual(m.pad_after_play(["play:app-367520", "touch:playport", "pad:a"]), "pad:a")

    def test_suggest_answers_the_suggested_layouts_toast_while_the_game_runs(self):
        """suggest:accept|dismiss waits for the Keyboard & mouse offer (PlayportKit LayoutSuggestion)
        and answers it as its buttons do; it runs while the game runs."""
        m = load()
        for ok in ("suggest:accept", "suggest:dismiss"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        for bad in ("suggest:", "suggest:yes", "suggest:accept@100"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)
        self.assertEqual(m.in_game(["play:app-15100", "suggest:accept", "touch:fire"], 1), 2)

    def test_controls_saves_a_games_on_screen_controls_before_play(self):
        m = load()
        env = m.ui_env("n1", play="app-367520", controls=("app-367520", '{"layout":"off"}'),
                       settings=("app-367520", "{}"))
        self.assertIn("UI_ACTIONS=controls:app-367520,settings:app-367520,play:app-367520", env)
        self.assertIn('UI_CONTROLS={"layout":"off"}', env)
        a = m.parse(["--controls", 'app-367520:{"opacity": 0.8}', "--play", "app-367520"])
        self.assertEqual(a.controls_pair, ("app-367520", '{"opacity":0.8}'))
        # The Gamepad layout's d-pad and right stick (PlayportKit GameControls.dpad, .rightStick).
        for stick in ("off", "below", "above"):
            a = m.parse(["--controls", f'app-367520:{{"layout":"gamepad","dpad":"on","rightStick":"{stick}"}}'])
            self.assertEqual(a.controls_pair,
                             ("app-367520", f'{{"layout":"gamepad","dpad":"on","rightStick":"{stick}"}}'))
        self.assertEqual(m.parse(["--controls", 'app-367520:{"dpad":"off"}']).controls_pair, ("app-367520", '{"dpad":"off"}'))
        # Every layout (PlayportKit OnScreenLayout).
        for layout in ("off", "gamepad", "keyboardMouse", "pointClick"):
            self.assertEqual(m.parse(["--controls", f'app-620:{{"layout":"{layout}"}}']).controls_pair,
                             ("app-620", f'{{"layout":"{layout}"}}'))
        for bad in ('app-367520:{"layout":"tank"}', 'app-367520:{"layout":"Keyboard & mouse"}', 'app-367520:{"opacity":3}', 'app-367520:{"x":1}', "app-367520:[]",
                    'nope:{}', 'app-367520:{"dpad":"yes"}', 'app-367520:{"dpad":true}', 'app-367520:{"rightStick":"left"}',
                    'app-367520:{"rightStick":"Below A/B/X/Y"}'):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                m.parse(["--controls", bad])

    def test_controls_carries_a_games_gyro_aim(self):
        """--controls' "gyro" is PlayportKit GameGyro: the game's own gyro aim, saved with its controls."""
        m = load()
        for ok in ('{"gyro":{"output":"mouse"}}', '{"gyro":{}}',
                   '{"layout":"off","gyro":{"output":"rightStick","source":"phone","sensitivity":2.5,"verticalRatio":0,'
                   '"turnAxis":"yaw","invertX":true,"invertY":false,"pauseButton":"pad:lb"}}',
                   '{"gyro":{"source":"controller","turnAxis":"roll","pauseButton":"none","sensitivity":20}}',
                   '{"gyro":{"pauseButton":"pad:rt","sensitivity":0.05,"verticalRatio":4}}',
                   '{"gyro":{"output":"rightStick","antiDeadZone":0.3}}', '{"gyro":{"antiDeadZone":0}}',
                   '{"gyro":{"antiDeadZone":0.9}}', '{"gyro":{"smoothing":"off"}}', '{"gyro":{"smoothing":"light"}}',
                   '{"gyro":{"output":"mouse","smoothing":"normal"}}', '{"gyro":{"smoothing":"auto"}}'):
            a = m.parse(["--controls", "app-620:" + ok])
            self.assertEqual(a.controls_pair, ("app-620", json.dumps(json.loads(ok), separators=(",", ":"))), ok)
        for bad in ('{"gyro":{"output":"keyboard"}}', '{"gyro":{"source":"watch"}}', '{"gyro":{"sensitivity":0}}',
                    '{"gyro":{"sensitivity":21}}', '{"gyro":{"sensitivity":"2"}}', '{"gyro":{"sensitivity":true}}',
                    '{"gyro":{"verticalRatio":-1}}', '{"gyro":{"turnAxis":"pitch"}}', '{"gyro":{"invertX":1}}',
                    '{"gyro":{"pauseButton":"pad:leftStick"}}', '{"gyro":{"pauseButton":"key:0x20"}}',
                    '{"gyro":{"speed":1}}', '{"gyro":"mouse"}', '{"gyro":[]}', '{"opacity":true}',
                    '{"gyro":{"antiDeadZone":-0.1}}', '{"gyro":{"antiDeadZone":0.95}}', '{"gyro":{"antiDeadZone":"0.3"}}',
                    '{"gyro":{"smoothing":"heavy"}}', '{"gyro":{"smoothing":false}}'):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                m.parse(["--controls", "app-620:" + bad])

    def test_controls_carries_a_games_controller_map(self):
        """--controls' "controllerMap" is PlayportKit ControllerMap: the mode, and a custom map's table."""
        m = load()
        for ok in ('{"controllerMap":{"mode":"keyboardMouse"}}', '{"controllerMap":{"mode":"controller"}}',
                   '{"controllerMap":{"mode":"custom"}}', '{"controllerMap":{"mode":"custom","version":1}}',
                   '{"layout":"off","controllerMap":{"mode":"custom","table":{"a":"key:0x20","rt":"mouse:left",'
                   '"leftStick.up":"key:0x57","leftStick.left":"key:shift+0x41","rightStick":"mouse:move",'
                   '"lb":"mouse:wheelUp","back":"playport:menu","x":"pad:b","start":"key:27"}}}',
                   '{"controllerMap":{"mode":"custom","table":{"leftStick":"pad:rightStick","rightStick":"pad:leftStick"}}}',
                   '{"controllerMap":{"mode":"custom","table":{}},"gyro":{"output":"mouse"}}'):
            a = m.parse(["--controls", "app-620:" + ok])
            self.assertEqual(a.controls_pair, ("app-620", json.dumps(json.loads(ok), separators=(",", ":"))), ok)
        for bad in ('{"controllerMap":"keyboardMouse"}', '{"controllerMap":{}}', '{"controllerMap":{"mode":"mouse"}}',
                    '{"controllerMap":{"mode":"custom","version":2}}', '{"controllerMap":{"mode":"custom","x":1}}',
                    '{"controllerMap":{"mode":"custom","table":[]}}',
                    '{"controllerMap":{"mode":"custom","table":{"home":"key:0x20"}}}',
                    '{"controllerMap":{"mode":"custom","table":{"a":"mouse:move"}}}',
                    '{"controllerMap":{"mode":"custom","table":{"a":"pad:leftStick"}}}',
                    '{"controllerMap":{"mode":"custom","table":{"leftStick":"key:0x57"}}}',
                    '{"controllerMap":{"mode":"custom","table":{"leftStick.up":"mouse:move"}}}',
                    '{"controllerMap":{"mode":"custom","table":{"rightStick":"mouse:move","rightStick.up":"key:0x57"}}}',
                    '{"controllerMap":{"mode":"custom","table":{"a":"key:0x00"}}}',
                    '{"controllerMap":{"mode":"custom","table":{"a":"key:256"}}}',
                    '{"controllerMap":{"mode":"custom","table":{"a":"key:meta+0x20"}}}',
                    '{"controllerMap":{"mode":"custom","table":{"a":"mouse:back"}}}',
                    '{"controllerMap":{"mode":"custom","table":{"a":"gyro:on"}}}',
                    '{"controllerMap":{"mode":"custom","table":{"a.up":"key:0x20"}}}',
                    '{"controllerMap":{"mode":"custom","table":{"a":1}}}'):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                m.parse(["--controls", "app-620:" + bad])
        self.assertIn("controllerMap", m.__doc__)

    def test_controls_carries_a_games_look_speed(self):
        """--controls' "lookSpeed" is GameControls.lookSpeed: a number 0.1-8, the mouse look's speed."""
        m = load()
        for ok in ('{"lookSpeed":1}', '{"lookSpeed":0.25}', '{"lookSpeed":8}',
                   '{"controllerMap":{"mode":"keyboardMouse"},"lookSpeed":2.5}'):
            a = m.parse(["--controls", "app-620:" + ok])
            self.assertEqual(a.controls_pair, ("app-620", json.dumps(json.loads(ok), separators=(",", ":"))), ok)
        for bad in ('{"lookSpeed":0}', '{"lookSpeed":9}', '{"lookSpeed":"2"}', '{"lookSpeed":true}', '{"lookSpeed":null}'):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                m.parse(["--controls", "app-620:" + bad])
        self.assertIn("lookSpeed", m.__doc__)

    def test_controls_carries_a_games_own_layouts(self):
        """--controls' "layouts" is GameControls.layouts: the game's own copies of the presets, as the
        layout editor saves them (PlayportKit ControlLayout version 3, keyed by preset name)."""
        m = load()
        jump = {"id": "jump", "actions": ["key:0x20"], "label": "Jump", "anchor": "bottomTrailing", "x": -71, "y": -166,
                "width": 56, "height": 56}
        wasd = {"id": "move", "kind": "stick", "actions": ["key:0x57", "key:0x53", "key:0x41", "key:0x44"],
                "anchor": "bottomLeading", "x": 120, "y": -90, "width": 132, "height": 132,
                "floatingZone": {"anchor": "bottomLeading", "width": 210, "height": 126}}
        look = {"id": "look", "kind": "lookArea", "actions": ["mouse:move"], "anchor": "center", "x": 0, "y": 0,
                "width": 10000, "height": 10000}
        tool = {"id": "rc", "kind": "tool", "actions": [], "tool": "rightClick", "anchor": "leading", "x": 30, "y": 0,
                "width": 44, "height": 44}
        pad = {"id": "a", "actions": ["pad:a"], "behaviour": "toggle", "anchor": "bottomTrailing", "x": -60, "y": -60,
               "width": 52, "height": 52}
        stick = {"id": "leftStick", "kind": "stick", "actions": ["pad:leftStick"], "anchor": "bottomLeading", "x": 100,
                 "y": -100, "width": 120, "height": 120}
        for ok in ({"keyboardMouse": {"version": 3, "controls": [look, jump, wasd, {**jump, "id": "jump-2", "x": -140}]}},
                   {"gamepad": {"version": 3, "controls": [pad, stick]}, "pointClick": {"version": 3, "controls": [tool]}},
                   {"keyboardMouse": {"version": 3, "controls": []}}, {}):
            js = json.dumps({"layout": "keyboardMouse", "layouts": ok}, separators=(",", ":"))
            self.assertEqual(m.parse(["--controls", "app-620:" + js]).controls_pair, ("app-620", js), js)
        for bad in ({"off": {"version": 3, "controls": []}},                       # Off has no layout
                    {"racingWheel": {"version": 3, "controls": []}},
                    {"gamepad": {"version": 2, "controls": []}},                   # this build reads version 3
                    {"gamepad": {"controls": []}}, {"gamepad": []}, [],
                    {"gamepad": {"version": 3, "controls": [jump, jump]}},         # two controls with one id
                    {"gamepad": {"version": 3, "controls": [{**jump, "id": "a b"}]}},
                    {"gamepad": {"version": 3, "controls": [{**jump, "width": 0}]}},
                    {"gamepad": {"version": 3, "controls": [{**jump, "anchor": "middle"}]}},
                    {"gamepad": {"version": 3, "controls": [{**jump, "kind": "slider"}]}},
                    {"gamepad": {"version": 3, "controls": [{**jump, "behaviour": "turbo"}]}},
                    {"gamepad": {"version": 3, "controls": [{**jump, "actions": ["key:0x20", "key:0x21"]}]}},
                    {"gamepad": {"version": 3, "controls": [{**jump, "actions": ["pad:leftStick"]}]}},
                    {"gamepad": {"version": 3, "controls": [{**jump, "actions": ["key:0x0"]}]}},
                    {"gamepad": {"version": 3, "controls": [{**jump, "actions": ["mouse:hover"]}]}},
                    {"gamepad": {"version": 3, "controls": [{**jump, "floatingZone": wasd["floatingZone"]}]}},
                    {"gamepad": {"version": 3, "controls": [{**jump, "tool": "hover"}]}},
                    {"gamepad": {"version": 3, "controls": [{**jump, "colour": "red"}]}},
                    {"gamepad": {"version": 3, "controls": [{**wasd, "actions": ["key:0x57"]}]}},
                    {"gamepad": {"version": 3, "controls": [{**look, "actions": ["mouse:left"]}]}},
                    {"gamepad": {"version": 3, "controls": [{**tool, "tool": "lasso"}]}},
                    {"gamepad": {"version": 3, "controls": [{**tool, "actions": ["mouse:left"]}]}}):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                m.parse(["--controls", "app-620:" + json.dumps({"layouts": bad})])
        self.assertIn('"layouts"', m.__doc__)

    def test_the_layout_editor_opens_from_game_options_and_over_the_paused_game(self):
        """open:ID#layout: Game options › Controls › Edit on-screen layout, the editor over the game's art;
        menu:layout: the in-game Controls panel's Edit layout…; pad: drives either."""
        m = load()
        self.assertIn("layout", m.GAME_SECTIONS)
        self.assertEqual(m.parse(["--action", "open:app-620#layout", "--action", "pad:rb+right+right+a"]).action,
                         ["open:app-620#layout", "pad:rb+right+right+a"])
        a = m.parse(["--action", "play:app-620", "--action", "menu:open", "--action", "menu:layout",
                     "--action", "pad:rb+up+b", "--action", "menu:resume"])
        self.assertIsNone(m.pad_after_play(a.action))
        self.assertEqual(m.in_game(a.action, 1), 4)
        for text in ("open:ID#layout", "menu:layout", "the layout editor"):
            self.assertIn(text, m.__doc__)

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

    def test_afc_puts_and_removes_only_a_text_bar_secret_file(self):
        """put-secret and rm reach Documents/ui-text-<nonce>-<n> (the text bar's secret, PLA-606), nothing near it."""
        spec = importlib.util.spec_from_file_location("afc_tool", os.path.join(TOOLS, "afc.py"))
        afc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(afc)
        self.assertIsNone(afc.secret_refusal("Documents/ui-text-0a1b2c3d-3"))
        self.assertIsNone(afc.rm_refusal("Documents/ui-text-0a1b2c3d-3"))
        for bad in ("Documents/ui-text-0a1b2c3d", "Documents/ui-text-0A1B2C3D-3", "Documents/ui-text-0a1b2c3d-3/x",
                    "Documents/ui-text-0a1b2c3d-3.part", "Documents/x/ui-text-0a1b2c3d-3", "ui-text-0a1b2c3d-3",
                    "Documents/ui-step-0a1b2c3d-3", "Documents/s1-host.log"):
            self.assertIsNotNone(afc.secret_refusal(bad), bad)
        self.assertIsNotNone(afc.rm_refusal("Documents/ui-text-0a1b2c3d-3.part"))

    def test_afc_rm_deletes_a_diagnostic_dump_in_a_title_config_folder(self):
        """rm reaches a NAME.bin a dev runtime wrote into title-cfg/TITLE/ (PLA-514's wow-dec.bin), never
        madeira.cfg, the folder, a deeper path or the rest of the prefix."""
        spec = importlib.util.spec_from_file_location("afc_tool", os.path.join(TOOLS, "afc.py"))
        afc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(afc)
        cfg = "Documents/prefix/Documents/title-cfg/"
        self.assertIsNone(afc.rm_refusal(cfg + "World of Warcraft Classic Era/wow-dec.bin"))
        for bad in (cfg + "World of Warcraft Classic Era/madeira.cfg", cfg + "World of Warcraft Classic Era",
                    cfg + "World of Warcraft Classic Era/", cfg + "World of Warcraft Classic Era/.bin",
                    cfg + "W/sub/x.bin", cfg + "../x.bin", cfg + "./x.bin", cfg + "x.bin", cfg + "/x.bin",
                    cfg + "W/x.bin.part", cfg + "W/x y.bin", "Documents/prefix/Documents/x.bin",
                    "Documents/prefix/drive_c/Games/W/x.bin", "Documents/title-cfg/W/x.bin", cfg[:-1]):
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
        self.assertFalse(m.title_ok({"outcome": "band=exhausted exit=0x00000000 after_s=12"}))

    def test_interruption_cancels_batch_even_when_leaving_game_running(self):
        m = load()
        import signal
        saved = {s: signal.getsignal(s) for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)}
        try:
            for leave in (False, True):
                for exception in (m.Terminated("SIGTERM"), KeyboardInterrupt()):
                    calls = []
                    class Phone:
                        def kill(self): calls.append("kill"); return True
                    term = m.EndOnTerm(Phone(), leave, cancel=lambda: calls.append("cancel") or {"delivery": "pushed", "confirmed": False})
                    with term:
                        raise exception
                    self.assertEqual(calls, ["cancel"] + ([] if leave else ["kill"]))
                    self.assertEqual(term.signal, "SIGINT" if isinstance(exception, KeyboardInterrupt) else "SIGTERM")
                    self.assertFalse(term.cancellation["confirmed"])
            calls = []
            def failed(): raise m.phonelib.PhoneError("transport lost")
            term = m.EndOnTerm(Phone(), True, cancel=failed)
            with term: raise m.Terminated("SIGTERM")
            self.assertEqual(term.cancellation["delivery"], "failed")
            self.assertFalse(term.cancellation["confirmed"])
        finally:
            for s, handler in saved.items(): signal.signal(s, handler)

    def test_cancel_marker_is_bounded_and_nonce_bound(self):
        m = load()
        calls, events = [], []
        class Phone:
            def bundle_id(self): return "test.bundle"
            def pmd(self, *args, **kwargs):
                with open(args[-2]) as f: payload = f.read()
                calls.append((args[-1], payload, kwargs))
        with tempfile.TemporaryDirectory() as d:
            result = m.request_batch_cancel(Phone(), d, "a123bc45", lambda *a, **k: events.append((a, k)))
            self.assertEqual(calls, [("Documents/ui-cancel-a123bc45", "a123bc45", {"secs": 10})])
            self.assertEqual(result, {"delivery": "pushed", "confirmed": False})
            with self.assertRaises(ValueError):
                m.request_batch_cancel(Phone(), d, "../stale", lambda *a, **k: None)
            self.assertEqual(len(calls), 1)

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

    def test_capture_layer_is_a_launch_variable(self):
        # Metal loads its capture layer only from the launch environment (decision 0165).
        self.assertIn("MTL_CAPTURE_ENABLED=1", load().ui_env("n1", play="app-292030", capture_layer=True))
        self.assertNotIn("MTL_CAPTURE_ENABLED=1", load().ui_env("n1", play="app-292030"))
        self.assertIn("--env MTL_CAPTURE_ENABLED=1", self.dry("--play", "app-292030", "--capture-layer"))

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
        nonce = None
        def launch(self, envs):
            self.__class__.nonce = next(e.split("=", 1)[1] for e in envs if e.startswith("TITLE_NONCE="))
            return 1
        def pid(self): return None
        def pull(self, *a, **k): return None
        current_events = []
        calls = []
        cancel_on_shot = False
        def run_events(self, nonce): return self.current_events
        def screenshot(self, path):
            self.calls.append("screenshot")
            if self.cancel_on_shot:
                self.current_events.append({"event": "ui-done", "outcome": "cancelled: foreground loss"})
            return path
        step_remotes = []
        def push(self, *args):
            self.calls.append("push")
            self.step_remotes.append(args[-1])
        cancel_push_failed = False
        def pmd(self, *args, **kwargs):
            self.calls.append((args[-1], kwargs["secs"]))
            if self.cancel_push_failed:
                import phonelib
                raise phonelib.PhoneError("cancel transport lost")
        def system_alert(self): return None
        def crashes(self, *a, **k): return []

    def run_ui(self, argv, events, why="done", interrupt=None):
        """main_recorded's result event and exit code with the app events replayed.
        self.last_events holds every JSON event line, for warnings and cancel requests."""
        m = load()
        import phonelib
        done = next((e for e in events if e.get("event") in ("title-done", "ui-done")), None)

        def watch(phone, ev, nonce, pid, until, wait, poll, done_events, is_done, quiet, on_event, *rest):
            if interrupt:
                raise m.Terminated(interrupt) if isinstance(interrupt, str) else interrupt
            for e in events:
                on_event(e)
                is_done(e)
            # A stop other than "done" leaves no terminal app event (a play-last run's
            # ui-done is seen but does not end the watch).
            terminal = done if done and why == "done" else None
            return (why, terminal) if terminal else (why if why != "done" else "until", None)
        saved = (phonelib.Phone, phonelib.watch_launch, phonelib.installed_check, phonelib.device_lock, m.LAST_PLAY)
        out = io.StringIO()
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "cmd"))
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
        self.last_events = [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]
        result = self.last_events[-1]
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

    def test_producer_interruption_wires_captured_nonce_to_cancel_transport(self):
        m = load()
        import signal
        saved = {s: signal.getsignal(s) for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)}
        try:
            for leave in (False, True):
                for interrupt, expected in (("SIGTERM", 143), (KeyboardInterrupt(), 130)):
                    for failed in (False, True):
                        self.FakePhone.calls = []
                        self.FakePhone.cancel_push_failed = failed
                        args = ["--action", "open:home"] + (["--leave-running"] if leave else [])
                        code, result, _ = self.run_ui(args, [], interrupt=interrupt)
                        self.assertEqual((code, result["ok"]), (expected, False))
                        self.assertEqual(result["cancellation"]["delivery"], "failed" if failed else "pushed")
                        self.assertFalse(result["cancellation"]["confirmed"])
                        self.assertEqual(len(self.FakePhone.calls), 1)
                        remote, timeout = self.FakePhone.calls[0]
                        self.assertEqual(remote, "Documents/ui-cancel-" + self.FakePhone.nonce)
                        self.assertEqual(timeout, 10)
        finally:
            self.FakePhone.calls = []; self.FakePhone.cancel_push_failed = False
            for s, handler in saved.items(): signal.signal(s, handler)

    def test_cancelled_batch_surfaces_failure_even_with_play_last(self):
        code, result, _ = self.run_ui(["--play", "app-1"],
                                    [{"event": "ui-done", "outcome": "cancelled: foreground loss"}], "done")
        self.assertEqual((code, result["ok"]), (1, False))
        self.assertIn("cancelled", result["done"])

    def test_step_does_not_acknowledge_observed_cancellation(self):
        event = {"event": "ui-action", "action": "open:home", "result": "ok", "index": 1}
        cancel = {"event": "ui-done", "outcome": "cancelled: foreground loss"}
        phone = self.FakePhone
        try:
            for during_shot in (False, True):
                phone.calls = []
                phone.current_events = [] if during_shot else [cancel]
                phone.cancel_on_shot = during_shot
                self.run_ui(["--action", "open:home", "--shot-each-action"], [event, cancel], "done")
                self.assertEqual(phone.calls, ["screenshot"] if during_shot else [])
            phone.calls = []; phone.current_events = []; phone.cancel_on_shot = False; phone.step_remotes = []
            self.run_ui(["--action", "open:home", "--shot-each-action"],
                        [event, {"event": "ui-done", "outcome": "ok"}], "done")
            self.assertEqual(phone.calls, ["screenshot", "push"])
            self.assertEqual(phone.step_remotes, ["Documents/ui-step-" + phone.nonce + "-1"])
        finally:
            phone.current_events = []; phone.calls = []; phone.cancel_on_shot = False

    def test_watcher_exit_with_an_unfinished_batch_requests_one_cancel(self):
        """--leave-running with queued input left: one bounded, unconfirmed cancel request."""
        phone = self.FakePhone
        try:
            phone.calls = []
            code, result, _ = self.run_ui(["--action", "open:home", "--leave-running",
                                           "--until", "first-frame+10"], [self.FRAME], why="until")
            self.assertEqual((code, result["ok"]), (0, True))
            self.assertEqual(result["cancellation"], {"delivery": "pushed", "confirmed": False})
            # The one device call is the marker; no action, screenshot or step was added.
            self.assertEqual(phone.calls, [("Documents/ui-cancel-" + phone.nonce, 10)])
            requests = [e for e in self.last_events if e.get("event") == "ui-cancel-request"]
            self.assertEqual(len(requests), 1)
            self.assertEqual((requests[0]["delivery"], requests[0]["confirmed"]), ("pushed", False))
            warnings = [e for e in self.last_events if e.get("event") == "warning"
                        and "queued input" in e["message"]]
            self.assertEqual(len(warnings), 1)
            self.assertIn("unfinished", warnings[0]["message"])
        finally:
            phone.calls = []

    def test_watcher_exit_after_ui_done_pushes_no_cancel(self):
        phone = self.FakePhone
        try:
            phone.calls = []
            code, result, _ = self.run_ui(["--action", "open:home", "--leave-running"],
                                          [{"event": "ui-done", "outcome": "ok actions=1"}])
            self.assertEqual((code, result["ok"]), (0, True))
            self.assertNotIn("cancellation", result)
            self.assertEqual(phone.calls, [])
            self.assertFalse(any(e.get("event") == "ui-cancel-request" for e in self.last_events))
        finally:
            phone.calls = []

    def test_watcher_exit_after_a_play_last_ui_done_pushes_no_cancel(self):
        """A --play smoke check leaves the game running; its finished queue gets no marker."""
        phone = self.FakePhone
        try:
            phone.calls = []
            code, result, _ = self.run_ui(["--play", "app-1", "--leave-running",
                                           "--until", "first-frame+10"],
                                          [{"event": "mark", "what": "first frame"},
                                           {"event": "ui-done", "outcome": "ok actions=1"}], why="until")
            self.assertEqual((code, result["ok"]), (0, True))
            self.assertNotIn("cancellation", result)
            self.assertEqual(phone.calls, [])
        finally:
            phone.calls = []

    def test_watcher_cancel_delivery_failure_is_reported_unconfirmed(self):
        phone = self.FakePhone
        try:
            phone.calls = []
            phone.cancel_push_failed = True
            code, result, _ = self.run_ui(["--action", "open:home", "--leave-running",
                                           "--until", "first-frame+10"], [self.FRAME], why="until")
            self.assertEqual(code, 0)
            self.assertEqual(result["cancellation"]["delivery"], "failed")
            self.assertFalse(result["cancellation"]["confirmed"])
            self.assertEqual(len(phone.calls), 1)
            warnings = [e for e in self.last_events if e.get("event") == "warning"]
            self.assertEqual(len([e for e in warnings if "queued input" in e["message"]]), 1)
            self.assertEqual(len([e for e in warnings if "could not be delivered" in e["message"]]), 1)
        finally:
            phone.calls = []
            phone.cancel_push_failed = False

    def test_watcher_exit_without_leave_running_pushes_no_cancel(self):
        phone = self.FakePhone
        try:
            phone.calls = []
            code, result, _ = self.run_ui(["--action", "open:home", "--until", "first-frame+10"],
                                          [self.FRAME], why="until")
            self.assertEqual(code, 0)
            self.assertNotIn("cancellation", result)
            self.assertEqual(phone.calls, [])
        finally:
            phone.calls = []

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


class TextBarSecret(unittest.TestCase):
    """pp ui's text bar actions (PLA-267) and textbar:secret (PLA-606): the value comes from a
    file or stdin and reaches the phone only as the nonce file the app asked for, never argv,
    the launch environment (UI_ACTIONS, which a restart's continuation file copies), the lock
    record, an event or any file of the run directory."""

    SENTINEL = "S3ntinel-Pa55,w0rd!€"

    class Phone(UntilReached.FakePhone):
        envs, secrets, removed, put_fails = [], [], [], False

        def launch(self, envs):
            self.__class__.envs = list(envs)
            return super().launch(envs)

        def put_secret(self, remote, data):
            self.secrets.append((remote, data))
            if self.put_fails:   # afc.py's 30 s timeout, after the .part was written
                import phonelib
                raise phonelib.PhoneError("afc put-secret failed (exit 124): ")

        def remove(self, remote, check=True):
            self.removed.append(remote)

    def run_secret(self, argv, events, stdin=None, put_fails=False, interrupt=None):
        """(exit code, stdout events, every byte the run directory holds, lock what, Phone).
        `interrupt` names what the watch raises after the events: KeyboardInterrupt (SIGINT)
        or Terminated (SIGTERM, SIGHUP)."""
        m = load()
        import phonelib
        phone = self.Phone
        phone.envs, phone.secrets, phone.removed, phone.put_fails = [], [], [], put_fails
        locked = []

        def watch(_phone, ev, nonce, pid, until, wait, poll, done_events, is_done, quiet, on_event, *rest):
            for e in events(nonce):
                ev("app:" + e["event"], **{k: v for k, v in e.items() if k != "event"})
                on_event(e)
            if interrupt == "KeyboardInterrupt":
                raise KeyboardInterrupt
            if interrupt == "Terminated":
                raise m.Terminated("SIGTERM")
            return "done", {"event": "ui-done", "outcome": "ok"}
        saved = (phonelib.Phone, phonelib.watch_launch, phonelib.installed_check, phonelib.device_lock, sys.argv, sys.stdin)
        out = io.StringIO()
        with tempfile.TemporaryDirectory() as d:
            run = os.path.join(d, "run")
            phonelib.Phone, phonelib.watch_launch = phone, watch
            phonelib.installed_check = lambda *a: (True, None, None)
            phonelib.device_lock = lambda what, **k: locked.append(what) or contextlib.nullcontext()
            sys.argv = ["pp-ui", "--out", run, *argv]
            if stdin is not None:
                sys.stdin = io.TextIOWrapper(io.BytesIO(stdin))
            try:
                with contextlib.redirect_stdout(out):
                    code = m.main(sys.argv[1:])
            finally:
                (phonelib.Phone, phonelib.watch_launch, phonelib.installed_check, phonelib.device_lock,
                 sys.argv, sys.stdin) = saved
            files = b""
            for root, _, names in os.walk(d):
                for n in names:
                    with open(os.path.join(root, n), "rb") as f:
                        files += n.encode() + b"\n" + f.read()
        return code, out.getvalue(), files, locked, phone

    @staticmethod
    def asked(n, action):
        """The app's events for a textbar:secret action at number n that typed what it got."""
        return lambda nonce: [{"event": "ui-secret-wanted", "index": n},   # the app names the number only
                              {"event": "ui-action", "action": action, "result": "ok", "index": n},
                              {"event": "ui-done", "outcome": "ok actions=3"}]

    def test_the_bar_s_actions_parse(self):
        m = load()
        for ok in ("menu:text", "textbar:close", "textbar:secure", "textbar:plain", "textbar:tab", "textbar:enter",
                   "textbar:backspace", "textbar:type:me@example.com", "textbar:type:a%2Cb%25 c"):
            self.assertEqual(m.parse(["--action", ok]).action, [ok])
        for bad in ("textbar:type:", "textbar:type:a,b", "textbar:open", "textbar:secret:x", "textbar:type:%zz"):
            with self.assertRaises(SystemExit, msg=bad), contextlib.redirect_stderr(io.StringIO()):
                m.parse(["--action", bad])
        self.assertTrue(m.in_game(["menu:open", "menu:text", "textbar:type:x", "textbar:enter", "open:home"], 0) == 4)

    def test_a_secret_action_needs_exactly_one_source_and_a_source_needs_the_action(self):
        m = load()
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "pw")
            open(path, "w").close()
            self.assertEqual(m.parse(["--action", "textbar:secret+enter", "--secret-file", path]).secret_file, [path])
            # One file per secret action, in order; one file serves them all.
            two = ["--action", "textbar:secret", "--action", "textbar:secret+enter"]
            self.assertEqual(m.parse(two + ["--secret-file", path, "--secret-file", path]).secret_file, [path, path])
            self.assertEqual(m.parse(two + ["--secret-file", path]).secret_file, [path])
            self.assertTrue(m.parse(["--action", "textbar:secret", "--secret-stdin"]).secret_stdin)
            for argv in (["--action", "textbar:secret"],
                         ["--action", "textbar:secret", "--secret-file", path, "--secret-stdin"],
                         ["--action", "textbar:enter", "--secret-file", path],
                         ["--action", "textbar:secret", "--secret-file", os.path.join(d, "absent")],
                         ["--action", "textbar:secret", "--secret-file", path, "--secret-file", path]):
                with self.assertRaises(SystemExit, msg=argv), contextlib.redirect_stderr(io.StringIO()):
                    m.parse(argv)

    def test_a_sentinel_secret_reaches_only_its_nonce_file(self):
        actions = ["--action", "menu:open", "--action", "menu:text", "--action", "textbar:secret+enter"]
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "wow-password")
            with open(path, "w") as f:
                f.write(self.SENTINEL + "\n")
            for argv, stdin in ((actions + ["--secret-file", path], None),
                                (actions + ["--secret-stdin"], (self.SENTINEL + "\n").encode())):
                code, stdout, files, locked, phone = self.run_secret(argv, self.asked(3, "textbar:secret+enter"), stdin)
                self.assertEqual(code, 0, stdout)
                nonce = next(e.split("=", 1)[1] for e in phone.envs if e.startswith("TITLE_NONCE="))
                # The one copy: the file the app asked for, its trailing newline stripped.
                self.assertEqual(phone.secrets, [(f"Documents/ui-text-{nonce}-3", self.SENTINEL.encode())])
                for where, text in (("events", stdout), ("env", "\n".join(phone.envs)), ("lock", "\n".join(locked)),
                                    ("run directory", files.decode(errors="replace"))):
                    for piece in (self.SENTINEL, "S3ntinel", "Pa55"):
                        self.assertNotIn(piece, text, where)
                self.assertIn("UI_ACTIONS=menu:open,menu:text,textbar:secret+enter", phone.envs)
                pushed = [json.loads(x) for x in stdout.splitlines() if '"secret-pushed"' in x]
                self.assertEqual([(e["index"], set(e) - {"event", "t", "index"}) for e in pushed], [(3, set())])
                # The app typed it (its ui-action): nothing is left to take back.
                self.assertEqual(phone.removed, [])

    def test_a_secret_the_app_did_not_take_is_removed_at_the_end(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "pw")
            with open(path, "w") as f:
                f.write(self.SENTINEL)
            events = lambda nonce: [{"event": "ui-secret-wanted", "index": 1},  # noqa: E731
                                    {"event": "ui-done", "outcome": "cancelled: foreground loss"}]
            _, _, _, _, phone = self.run_secret(["--action", "textbar:secret", "--secret-file", path], events)
            nonce = next(e.split("=", 1)[1] for e in phone.envs if e.startswith("TITLE_NONCE="))
            self.assertEqual(phone.secrets, [(f"Documents/ui-text-{nonce}-1", self.SENTINEL.encode())])
            self.assertEqual(phone.removed, [f"Documents/ui-text-{nonce}-1"])

    def test_each_secret_action_types_its_own_file_in_order(self):
        """Two textbar:secret actions (an account name, then a password): the first the app asks
        for gets the first --secret-file, the second the second; neither value is anywhere else."""
        with tempfile.TemporaryDirectory() as d:
            paths = []
            for name, value in (("name", "N4me-sentinel"), ("pw", self.SENTINEL)):
                paths.append(os.path.join(d, name))
                with open(paths[-1], "w") as f:
                    f.write(value + "\n")
            events = lambda nonce: [  # noqa: E731
                {"event": "ui-secret-wanted", "index": 3},
                {"event": "ui-action", "action": "textbar:secret", "result": "ok", "index": 3},
                {"event": "ui-secret-wanted", "index": 5},
                {"event": "ui-action", "action": "textbar:secret+enter", "result": "ok", "index": 5},
                {"event": "ui-done", "outcome": "ok actions=5"}]
            argv = ["--action", "menu:open", "--action", "menu:text", "--action", "textbar:secret",
                    "--action", "textbar:tab", "--action", "textbar:secret+enter",
                    "--secret-file", paths[0], "--secret-file", paths[1]]
            code, stdout, files, _, phone = self.run_secret(argv, events)
            self.assertEqual(code, 0, stdout)
            nonce = next(e.split("=", 1)[1] for e in phone.envs if e.startswith("TITLE_NONCE="))
            self.assertEqual(phone.secrets, [(f"Documents/ui-text-{nonce}-3", b"N4me-sentinel"),
                                             (f"Documents/ui-text-{nonce}-5", self.SENTINEL.encode())])
            for text in (stdout, "\n".join(phone.envs), files.decode(errors="replace")):
                self.assertNotIn("N4me-sentinel", text)
                self.assertNotIn(self.SENTINEL, text)

    def test_a_request_past_the_run_s_secret_actions_gets_nothing(self):
        """One textbar:secret action, two requests (the app's shape: a number only): the second
        gets nothing, so a stray request cannot pull the value twice."""
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "pw")
            with open(path, "w") as f:
                f.write(self.SENTINEL)
            events = lambda nonce: [{"event": "ui-secret-wanted", "index": 1},  # noqa: E731
                                    {"event": "ui-action", "action": "textbar:secret", "result": "ok", "index": 1},
                                    {"event": "ui-secret-wanted", "index": 2},
                                    {"event": "ui-done", "outcome": "ok"}]
            _, stdout, _, _, phone = self.run_secret(["--action", "textbar:secret", "--secret-file", path], events)
            nonce = next(e.split("=", 1)[1] for e in phone.envs if e.startswith("TITLE_NONCE="))
            self.assertEqual(phone.secrets, [(f"Documents/ui-text-{nonce}-1", self.SENTINEL.encode())])
            self.assertIn("nothing pushed", stdout)

    def test_a_secret_is_removed_however_the_run_ends(self):
        """A push that fails part-way (the 30 s timeout), SIGINT or SIGTERM: the file pushed, or
        its .part, is removed before the run ends (afc.py rm takes both)."""
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "pw")
            with open(path, "w") as f:
                f.write(self.SENTINEL)
            wanted = lambda nonce: [{"event": "ui-secret-wanted", "index": 2}]  # noqa: E731
            for how, kw, code in (("failed push", {"put_fails": True}, 1),
                                  ("SIGINT", {"interrupt": "KeyboardInterrupt"}, 130),
                                  ("SIGTERM", {"interrupt": "Terminated"}, 143)):
                got, stdout, _, _, phone = self.run_secret(["--action", "textbar:secret", "--secret-file", path], wanted, **kw)
                nonce = next(e.split("=", 1)[1] for e in phone.envs if e.startswith("TITLE_NONCE="))
                self.assertEqual(got, code, how)
                self.assertEqual(phone.removed, [f"Documents/ui-text-{nonce}-2"], how)
                self.assertIn('"secret-removed"', stdout, how)
                self.assertNotIn(self.SENTINEL, stdout, how)

    def test_afc_rm_takes_a_secret_s_part_file_and_a_failed_put_leaves_none(self):
        spec = importlib.util.spec_from_file_location("afc_tool", os.path.join(TOOLS, "afc.py"))
        afc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(afc)

        class AFC:
            def __init__(self, files, fail_rename=False):
                self.files, self.fail_rename = dict(files), fail_rename

            async def __aenter__(self):
                return self

            async def __aexit__(self, *_):
                return False

            async def exists(self, p):
                return p in self.files

            async def stat(self, p):
                return {"st_ifmt": "S_IFREG", "st_size": len(self.files[p])}

            async def rm(self, p):
                del self.files[p]

            async def set_file_contents(self, p, data):
                self.files[p] = data

            async def rename(self, a, b):
                if self.fail_rename:
                    raise ConnectionError("the phone went away")
                self.files[b] = self.files.pop(a)

        name = "Documents/ui-text-0a1b2c3d-2"
        out = io.StringIO()
        for files in ({name + ".part": b"x"}, {name: b"x", name + ".part": b"x"}, {name: b"x"}):
            fake = AFC(files)

            async def connect(_bundle, fake=fake):
                return fake
            afc.connect = connect
            with contextlib.redirect_stdout(out):
                afc.asyncio.run(afc.main("app", "rm", [name]))
            self.assertEqual(fake.files, {}, files)
        with self.assertRaises(SystemExit), contextlib.redirect_stdout(out):
            afc.asyncio.run(afc.main("app", "rm", [name]))   # neither is there

        fake = AFC({}, fail_rename=True)

        async def connect(_bundle):
            return fake
        afc.connect = connect
        old = sys.stdin
        sys.stdin = io.TextIOWrapper(io.BytesIO(self.SENTINEL.encode()))
        try:
            with self.assertRaises(ConnectionError):
                afc.asyncio.run(afc.main("app", "put-secret", [name]))
        finally:
            sys.stdin = old
        self.assertEqual(fake.files, {})


if __name__ == "__main__":
    unittest.main()
