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
                       "probe:memory-pool-verify", "probe:memory-pool-zero", "background:10", "background:60", "background:600"):
            self.assertEqual(m.parse(["--action", action]).action, [action])
        for action in ("probe:memory-donors-4096", "probe:memory-donors-", "probe:memory-pool", "background:",
                       "background:9", "background:601", "background:060", "background:1000"):
            self.assertFalse(m.ACTION_RE.match(action), action)

    def test_return_from_background(self):
        m = load()

        class Phone:
            def __init__(self, pid):
                self.running, self.activated = pid, 0

            def pid(self):
                return self.running

            def activate(self):
                self.activated += 1
                return self.running

        slept = []
        alive = Phone(42)
        out = m.return_from_background(alive, {"seconds": 60, "pid": 42, "t": 100.0}, now=lambda: 103.0, sleep=slept.append)
        self.assertEqual(slept, [57.0])
        self.assertEqual(out, {"seconds": 60, "pid": 42, "pid_seen": 42, "alive": True, "pid_after": 42, "same_process": True})
        self.assertEqual(alive.activated, 1)
        gone = Phone(None)
        out = m.return_from_background(gone, {"seconds": 60, "pid": 42, "t": 100.0}, now=lambda: 300.0, sleep=slept.append)
        self.assertEqual(slept[-1], 0)
        self.assertEqual((out["alive"], gone.activated), (False, 0))
        self.assertNotIn("pid_after", out)
        replaced = Phone(43)
        out = m.return_from_background(replaced, {"seconds": 10, "pid": 42}, sleep=slept.append)
        self.assertEqual((out["alive"], replaced.activated), (False, 0))

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
                   "open:settings#controllers"):
            self.assertTrue(m.ACTION_RE.match(ok), ok)
        for bad in ("touch:", "touch:a@", "touch:a.b", "touch:a@123456", "touch:a+", "touch:a,b", "menu:control"):
            self.assertFalse(m.ACTION_RE.match(bad), bad)
        self.assertEqual(m.in_game(["play:app-367520", "touch:a", "pad:a"], 1), 1)

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
        for bad in ('app-367520:{"layout":"tank"}', 'app-367520:{"opacity":3}', 'app-367520:{"x":1}', "app-367520:[]",
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
