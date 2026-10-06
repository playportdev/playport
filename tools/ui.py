#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""pp ui: drive the product UI on the phone (app/Sources/S1Probe/Dev/UIDriver.swift; dev builds only).

  pp ui [--action VERB:ARG ...] [--settings ID:JSON] [--verify ID] [--play ID]
        [--shot-each-action] [--pad] [--out DIR] [--until SPEC] [--wait S] [--quiet]
        [--shot] [--screenshot-after S ...] [--leave-running] [--keep-log] [--lock-wait S]
        [--expect-ipa IPA|SHA256] [--any-build] [--keep-settings] [--dry-run]

The app starts as a Home Screen launch does, shows the
library, and does what a person would do with its buttons, through the same
model calls: each --action in order, then --settings, --verify, --play:

  open:SCREEN | open:ID  show a screen (home, library, games: the Library on Steam, downloads,
                         settings, account: Settings' Steam account, setup: the first-run checklist as
                         Settings › Setup check's first row opens it, signin: Sign in to Steam, a preview
                         that sends nothing to Steam while Steam is signed in) or a title's page;
                         open:ID#SECTION opens its Game options at a section (graphics, game, files,
                         developer, ordering, steam);
                         open:settings#SECTION shows a Settings section (steam, graphics, downloads,
                         controllers, storage, setup, about, developer; also account, jit, memory,
                         diagnostics, pairing, probes, logs for the section that holds them);
                         open:licences shows Settings › About › Licences, open:licences#PREFIX the
                         files of the first component whose name starts with PREFIX (open:licences#wine);
                         there pad:down/up move through the rows and a text's paragraphs, pad:a opens
                         the ringed one, pad:b goes back a page.
                         open:black shows Settings › Developer › Black screen (pure black, lowest
                         brightness; a tap or any button wakes it; pp phone unattended).
                         In Settings up and down move along its list and show each section, right
                         goes into it, left and B come back, B on the list closes Settings;
                         pad:left/right change a Graphics value.
                         On the checklist (open:setup) pad:right/left or rb/lb move along its steps,
                         pad:a does the ringed one (Pair again re-pairs: not in a test). First run:
                         pad:x on Memory or Steam puts it off; pad:b cannot leave until pairing
                         and VPN are ready, Increased Memory Limit is on or put off, and Steam is
                         signed in or put off. Then the completion overlay's
                         pad:a/Continue leaves; pad:b closes only the overlay. Later visits always
                         allow pad:b. Settings' dev Preview a first run simulates each step with A.
                         On Sign in to Steam (open:signin) pad:a on its left card asks for the account
                         name, then the password, on the keyboard (neither is logged), pad:rb shows a
                         QR code, pad:b cancels or leaves; a real sign-in needs Steam signed out
  pad:BUTTON[+BUTTON...] press controller buttons (a b x y lb rb menu view up down left right), 250 ms
                         apart, into the router a controller feeds (UI/Pad/PadRouter.swift):
                         pad:rb moves to the next page, pad:down+a opens what the ring moves to;
                         on a game page pad:x opens its Game options and pad:y puts the ringed
                         setting back to its default, and pad:a on Play plays: the run follows the
                         game as for play: (use --until first-frame+S);
                         while the controller keyboard or a picker is up the presses are its
                         (the keyboard starts on q: pad:y+down+right+right+right+right+right+a
                         types "h" into the Library's search)
  wait:S                 wait S seconds (at most 600); after a play:, while the game runs
  menu:open              after a play: (the actions after it then run while the game runs): wait for
                         the game's first frame, then hold the controller's Home button 0.8 s through
                         HostIO's pad handling, which opens Playport's in-game menu over the paused
                         game (UI/InGameMenuView.swift)
  menu:ROW               in that menu, move its ring to ROW (resume, screenshot, overlay, controller,
                         quit) and press A; pad:up/down/a/b press into the menu while it is up.
                         menu:screenshot saves the frame to Photos (the first time iOS asks a person
                         to allow it) and, in a dev build, to Documents/Screenshots; menu:quit closes
                         the game's windows, and the run follows Playport's restart as for play:.
                         The scripted pad (--pad) has HOME too: `pp pad send "800 HOME" "100 -"`
                         opens the menu, and its presses are the menu's while it is up.
                         Example: --action play:app-367520 --action wait:10 --action menu:open
                         --action menu:resume --action wait:5 --action menu:open --action menu:quit
                         --action open:home --shot-each-action
  set:KEY=VALUE          a UserDefaults key, as a Settings control sets it (set:metalHUD=true)
  hud:on | hud:off       Settings' Metal HUD
  queue:APP              queue a download from Steam, as a game page's Install does, and go on at once
  downloading:APP        wait (2 min at most) until the queue runs APP's download with progress (after
                         the restart after a game, too), and log the queue
  install:APP            install from Steam with the paired session; pause-resume:APP pauses at a
                         quarter and resumes
  uninstall:ID, verify:ID
  play:ID                Play. When the game ends, Playport restarts itself (decision 0029) and the
                         actions after it run in the new process, under this run
                         (Dev/DriverContinuation.swift); the run follows it across the restart.
                         A game whose cloud saves conflict is refused with the Cloud save
                         conflict screen up (the run ends there): open:ID, pad:a plays from
                         the game's page instead, and pad:a / pad:x / pad:b on that screen keep the
                         phone's saves, keep Steam's (either starts the game), or decide later.
                         Game options' Developer section has "Forget the cloud sync" (a first
                         sync next: a save that differs from Steam's becomes a conflict)
  probe:helper-exit | probe:helper-kill [-hold]
                         Settings' helper-lifetime probe (Dev/HelperLifetimeProbe.swift): the JIT
                         helper ticks, then the app ends itself by exit(0) or SIGKILL 2 s after
                         the run's done (use --leave-running); must be the last action. -hold:
                         the helper takes its own xpc transaction and ignores SIGTERM
  probe:helper-report    read that probe's report back into s1-host.log (a later run, --keep-log)
  jit:setup | jit:pair   Open the product setup (Pair again keeps old credentials until verified)
  jit:continue | jit:open-settings | jit:cancel | jit:wait
                         Resume/open Settings/cancel/wait in the SAME run; system Settings needs the person
  probe:settings-url-N   open Settings link N (OnDevicePairing's candidates); screenshot with pp phone shot
  probe:pairing          Settings' on-device pairing experiment (iOS 27); use --leave-running
  probe:pairing-cancel | probe:pairing-use
                         Cancel, or wait for pairing, store it and check readiness
                         Use after probe:pairing in the SAME run (a later pp ui relaunches the app)
  probe:relaunch         Settings' Restart Playport now (AppRestart.swift): the restart after a game,
                         with no game; the run is done as it asks (use --leave-running); must be
                         the last action
  --settings ID:JSON     a game's own launch settings, as its page saves them (PlayportKit
                         LaunchSettings: frame limit, screen, launch arguments; `ID:{}` clears)
  --play ID              Play, as the button does, after every --action; JIT from the app's own helper

ID is the catalogue's title id (`app-367520`, Hollow Knight), APP a Steam app
id. --shot-each-action takes a screenshot as each action completes: the app
holds the next action until the screenshot is taken (UI_STEP), and an open:
waits 1.5 s first, so the page is drawn. --pad starts the scripted pad
(HIO_VPAD=vpad.txt), which `pp pad` then plays.

Settings a run changes (set:, hud:, --settings) last for the session: the
hold of the device lock the run is part of (one pp ui, pp perf, or everything
under one `pp phone lock -- CMD`). The app undoes them at its first launch
outside that session (Dev/DriverUndo.swift), so another agent, or a person,
starts from the settings a person left. --keep-settings keeps this run's.

What a run does, under the device lock (phonelib.py):
  0. refuses to drive an IPA this checkout did not install (DEVICE_DIR/device-state.json,
     the machine's one install record): --expect-ipa names the IPA (file or sha256) the
     phone must have; --any-build drives whatever it has;
  1. checks the phone and finds the app, ends it if it runs, and moves
     s1-host.log aside (--keep-log leaves it), so the pulled log is this run's;
  2. launches the app with S1_MODE=ui and the actions; the app appends this
     launch's events to run-events.jsonl;
  3. follows those events until the UI's done event, or, with --play (or a
     play: action that no action follows), the title's (a refused or failed
     action stops it at once), or until --until holds: `first-frame+S` (S
     seconds after the game's first frame), `mark:TEXT+S` (after any
     `title: +s TEXT` mark) or `event:NAME+S`.
     --quiet reads the phone no more once --until has matched, until the S
     seconds are over (a measured run);
  4. takes the screenshots (--shot: when it stops; --screenshot-after S: S
     seconds after the launch), ends the app (--leave-running keeps it), and
     pulls s1-host.log and timeline.txt (the title:, jit:, ui: lines) into
     --out. If the app died, the day's crash reports go to <out>/crashes/. It
     pulls steam-drive.log after an install.

Output: JSON events on stdout and in <out>/events.jsonl, last a `result`
line with the run directory (`out`), the timeline's title: and jit: marks
(`timeline`), a play's start-up self-check (`selfcheck`: the app's verdict
line, and the TEB's TSD slot as ntdll found it) and the JIT pool's use from
the last `pool:` line the launch logged (`pool`: head, tail and alias table, in
MiB and counts; the app logs one as the pool grows and marks one when the game
exits) and the runtime's known limits from the last `limits:` line (`limits`:
counts of W+X requests that lost WRITE, x18 instructions left to fault and
emulated misaligned atomics) and the FEX arena's use from the last `band:` line
(`band`: its use and free space in MiB, free 16 MiB span slots, emulator threads
and refused requests); argv.txt records the command. A launch that ran
the pool out (`pool=exhausted:<part>`) is not ok. With actions after a play:
action, the run is ok when they all ran and the last title's end was ok; the
result's `title` is that end. Exit 0 ok, 1 failed or refused, 2
--wait ran out, 4 the JIT helper could not reach the phone's VPN (why:
"jit-unreachable": LocalDevVPN is off; a person must turn it on, so retrying
does not help), 143 ended by SIGTERM (why: "terminated"; the app is ended
unless --leave-running). --wait S gives up S + 180 s after the launch: the
app's JIT wait (180 s at most, about 4 s when JIT comes) is added to it.
"""

import argparse
import contextlib
import json
import os
import re
import secrets
import signal
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import phonelib  # noqa: E402

# How long a launch waits for its JIT pool (LaunchCoordinator).
JIT_WAIT_S = 180
ID_RE = re.compile(r"^[a-z]+-[a-z0-9 ._-]+$")
SCREENS = ("home", "library", "games", "downloads", "settings", "account", "setup", "signin")   # AppNavigation.screens
PAD_BUTTONS = "a|b|x|y|lb|rb|menu|view|up|down|left|right"   # HostIOKit NavButton
# the app's launch failure when its JIT helper cannot reach LocalDevVPN's address
JIT_UNREACHABLE_RE = re.compile(r"Timed out connecting to 10\.7\.0\.1")  # "not ready for JIT: X" has other X too
JIT_UNREACHABLE = dict(why="jit-unreachable", exit=4,
                       hint="the JIT helper could not reach 10.7.0.1: LocalDevVPN is off on the phone. Ask the "
                            "person at the phone to connect it (and unlock the phone); retrying will not help")


# the app's start-up self-check verdicts (SelfCheck.swift) and the TSD slot ntdll gave the TEB
SELFCHECK_RE = re.compile(r"title: selfcheck: (.*)$")
TEB_TSD_RE = re.compile(rb"\[teb-tsd\] key=(\d+) offset=0x([0-9a-f]+) verified=1")


def selfcheck_of(timeline, log=None):
    """The result event's `selfcheck`: the launch's last verdict (the pool's, once the pool
    is blessed; the host's alone when the launch stopped before), and the TEB's TSD slot
    from ntdll's own probe in the log (`teb`), when the runtime got that far."""
    reports = [m[1] for m in map(SELFCHECK_RE.search, timeline) if m]
    if not reports:
        return None
    out = {"report": reports[-1]}
    if log and os.path.exists(log):
        with open(log, "rb") as f:
            for raw in f:
                m = TEB_TSD_RE.search(raw)
                if m:
                    out["teb"] = f"key {int(m[1])} slot {int(m[2], 16) // 8}"
                    break
    return out


class Terminated(Exception):
    """SIGTERM or SIGHUP: end the run as its result line says."""


class EndOnTerm:
    """Inside the device lock: a Terminated from the block ends the app (unless leave)
    while the lock is still held, and is kept in .signal instead of propagating."""

    def __init__(self, phone, leave):
        self.phone, self.leave, self.signal, self.app_ended = phone, leave, None, False

    def __enter__(self):
        return self

    def __exit__(self, kind, e, _tb):
        if kind is not Terminated:
            return False
        signal.signal(signal.SIGTERM, signal.SIG_IGN)   # a second one must not cut this short
        self.signal = str(e)
        if not self.leave:
            with contextlib.suppress(phonelib.PhoneError):
                self.app_ended = self.phone.kill()
        return True


ACTION_RE = re.compile((r"^(?:(?:install|pause-resume|queue|downloading):[0-9]+|(?:uninstall|verify|play):[a-z]+-[a-z0-9 ._-]+"
                       r"|hud:(?:on|off)|open:[a-z]+(?:-[a-z0-9 ._-]+(?:#[a-z]+)?)?|open:settings#(?:steam|graphics|downloads|controllers|storage|setup|about|developer|account|jit|memory|diagnostics|pairing|probes|logs)|open:licences(?:#[a-z0-9 ._-]+)?|pad:(?:{b})(?:\+(?:{b}))*|set:[A-Za-z0-9._-]+=[^,]*"
                       r"|wait:[0-9]{1,3}|menu:(?:open|resume|screenshot|overlay|controller|quit)"
                       r"|jit:(?:setup|pair|continue|open-settings|cancel|wait)|probe:settings-url-[0-9]|probe:helper-(?:(?:exit|kill)(?:-hold)?|report)|probe:relaunch|probe:pairing(?:-cancel|-use)?)$").replace("{b}", PAD_BUTTONS))


def in_game(actions, start):
    """How many actions from start act on the running game (UIDriver.inGame): wait: and
    menu:, and pad: once a menu:open has opened the in-game menu."""
    n, menu = 0, False
    for x in actions[start:]:
        if x.startswith(("wait:", "menu:")) or (menu and x.startswith("pad:")):
            menu = menu or x == "menu:open"
            n += 1
        else:
            break
    return n


def after_play(actions):
    """Whether an action follows the last play: in actions, past the ones for the running
    game (in_game): the app then runs it after the restart that follows the game, and the
    UI's done event, not the title's, ends the run."""
    plays = [i for i, x in enumerate(actions) if x.startswith("play:")]
    return bool(plays) and plays[-1] + in_game(actions, plays[-1] + 1) < len(actions) - 1


def ends_run(e, actions, play, titles_done=1):
    """Whether an app event ends the run: the last play's title end unless an action
    follows it (titles_done counts title ends so far, this one included, so an earlier
    play's end in the same app run does not end it), the UI's own end unless a play
    (--play or a play: action, or menu:quit, which ends the game) comes last, a refused or
    failed action at once."""
    seq = list(actions) + [f"play:{play}"] * bool(play)
    if e.get("event") == "title-done":
        plays = sum(x.startswith("play:") for x in seq)
        return titles_done >= plays and not after_play(seq)
    game_last = bool(seq) and (seq[-1].startswith("play:") or seq[-1] == "menu:quit")
    return not game_last or not e.get("outcome", "").startswith("ok")


def ui_env(nonce, verify=None, play=None, extra=(), settings=None, step=False, pad=False,
           session=None, keep_settings=False):
    """settings: (title id, LaunchSettings JSON) or None. step: the app waits after each
    action until the driver pushes Documents/ui-step-<n> (--shot-each-action). session:
    the device lock hold this launch is part of (the app undoes an earlier session's
    driven settings, and records this one's); keep_settings: record nothing to undo."""
    actions = (list(extra) + ([f"settings:{settings[0]}"] if settings else [])
               + [f"verify:{verify}"] * bool(verify) + [f"play:{play}"] * bool(play))
    envs = ["S1_MODE=ui", "TITLE_NONCE=" + nonce]
    if actions:
        envs.append("UI_ACTIONS=" + ",".join(actions))
    if settings:
        envs.append("UI_SETTINGS=" + settings[1])
    if step:
        envs.append("UI_STEP=1")
    if pad:
        envs.append("HIO_VPAD=vpad.txt")
    if session:
        envs.append("UI_SESSION=" + session)
    if keep_settings:
        envs.append("UI_KEEP_SETTINGS=1")
    return envs


def title_ok(done):
    outcome = " " + done.get("outcome", "") + " "
    return " exit=0x00000000 " in outcome and " pool=exhausted:" not in outcome


POOL_RE = re.compile(r"\bpool: (size_mb=.*)$")


def pool_use(timeline):
    """The last `pool:` line of a launch's timeline as a dict (JitPool.Use.line in
    PlayportKit): sizes in MiB, counts, and `exhausted`; None when it logged none."""
    for line in reversed(timeline):
        m = POOL_RE.search(line.replace("  (from run-events.jsonl)", ""))
        if m:
            use = dict(f.split("=", 1) for f in m[1].split() if "=" in f)
            return {k: (int(v) if v.isdigit() else v) for k, v in use.items()}
    return None


LIMITS_RE = re.compile(r"\blimits: (wx_dropped=.*)$")


def limits_of(timeline):
    """The last `limits:` line of a launch's timeline as a dict of counts (RuntimeLimits
    in PlayportKit: wx_dropped, x18_images, x18_sites, split_lock); None when it logged none."""
    for line in reversed(timeline):
        m = LIMITS_RE.search(line.replace("  (from run-events.jsonl)", ""))
        if m:
            return {k: int(v) for k, v in (f.split("=", 1) for f in m[1].split() if "=" in f) if v.isdigit()}
    return None


BAND_RE = re.compile(r"\bband: (size_mb=.*)$")


def band_of(timeline):
    """The last `band:` line of a launch's timeline as a dict (FexBand.Use.line in
    PlayportKit: the FEX arena's size, use and free space in MiB, its free 16 MiB span
    slots, the emulator threads, and the requests it refused); None when it logged none."""
    for line in reversed(timeline):
        m = BAND_RE.search(line.replace("  (from run-events.jsonl)", ""))
        if m:
            return {k: int(v) for k, v in (f.split("=", 1) for f in m[1].split() if "=" in f) if v.isdigit()}
    return None


def parse(argv=None):
    p = argparse.ArgumentParser(prog="pp ui", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--action", action="append", default=[], metavar="VERB:ARG",
                   help="open:SCREEN|ID[#SECTION], pad:BUTTON[+BUTTON...], wait:S, menu:open|ROW, set:KEY=VALUE, hud:on|off, install:APP, pause-resume:APP, queue:APP, downloading:APP, uninstall:ID, "
                        "verify:ID, play:ID, probe:helper-exit|kill|report, probe:relaunch, probe:pairing[-cancel|-use]; in order, before --settings/--verify/--play")
    p.add_argument("--settings", metavar="ID:JSON",
                   help='save these launch settings for the title first ({"frameLimit":30,"screen":"720",'
                        '"arguments":"-DX12"}; {} clears them)')
    p.add_argument("--verify", metavar="ID", help="Verify files for this title first")
    p.add_argument("--play", metavar="ID", help="then Play this title")
    p.add_argument("--shot-each-action", action="store_true", help="a screenshot as each action completes")
    p.add_argument("--pad", action="store_true", help="start the scripted pad (HIO_VPAD=vpad.txt; pp pad plays it)")
    p.add_argument("--out", help="run directory (default: $PLAYPORT_BUILD/ui-runs/<time>)")
    p.add_argument("--until", default="done", help="done (default), first-frame[+S], mark:TEXT[+S] or event:NAME[+S]")
    p.add_argument("--wait", type=int, default=1800,
                   help="give up (and end the app) this many seconds after the launch, plus the app's JIT wait "
                        "(up to 180 s; default 1800)")
    p.add_argument("--poll", type=float, default=3, help="seconds between reads of the app's events (default 3)")
    p.add_argument("--quiet", action="store_true", help="no reads of the phone between --until matching and its +S")
    p.add_argument("--shot", action="store_true", help="a screenshot when the run stops")
    p.add_argument("--screenshot-after", type=int, action="append", default=[], metavar="S",
                   help="a screenshot S seconds after the launch (repeatable)")
    p.add_argument("--leave-running", action="store_true", help="do not end the app at the end of the run")
    p.add_argument("--keep-log", action="store_true", help="do not move s1-host.log aside before the launch")
    p.add_argument("--lock-wait", type=int, help="seconds to wait for the device lock (default: as long as it takes)")
    p.add_argument("--expect-ipa", metavar="IPA|SHA256",
                   help="refuse unless the phone has this IPA (pp install's record in the shared device-state.json)")
    p.add_argument("--any-build", action="store_true",
                   help="drive whatever the phone has, even an IPA another checkout installed")
    p.add_argument("--keep-settings", action="store_true",
                   help="keep this run's set:, hud: and --settings changes after the session (default: undone)")
    p.add_argument("--dry-run", action="store_true", help="print the device commands; touch nothing")
    a = p.parse_args(argv)
    for t in (a.verify, a.play):
        if t is not None and not ID_RE.match(t):
            p.error(f"{t!r} is not a catalogue title id (app-367520)")
    for x in a.action:
        if not ACTION_RE.match(x) or (x.startswith("open:") and "-" not in x.split("#")[0]
                                      and x[5:].split("#")[0] not in SCREENS + ("licences", "black")):
            p.error(f"{x!r} is not open:SCREEN|ID, pad:BUTTON[+BUTTON...], wait:S, menu:open|ROW, set:KEY=VALUE, hud:on|off, install:APP, pause-resume:APP, "
                    "queue:APP, downloading:APP, uninstall:ID, verify:ID, play:ID, probe:helper-exit|kill|report, probe:relaunch or probe:pairing[-cancel|-use]")
    a.settings_pair = None
    if a.settings:
        sid, _, js = a.settings.partition(":")
        try:
            ok = ID_RE.match(sid) and isinstance(json.loads(js), dict)
        except ValueError:
            ok = False
        if not ok:
            p.error(f"{a.settings!r} is not ID:JSON with a JSON object")
        a.settings_pair = (sid, js)
    try:
        a.until_spec = phonelib.parse_until(a.until)
    except ValueError as e:
        p.error(str(e))
    return a


def main(argv=None):
    a = parse(argv)

    title_end = {}
    titles = {"done": 0}

    def is_done(e):
        if e.get("event") == "title-done":
            titles["done"] += 1
        return ends_run(e, a.action, a.play, titles["done"])

    def ok_of(e):
        if e.get("event") == "title-done":
            return title_ok(e)
        return e.get("outcome", "").startswith("ok") and (not title_end or title_ok(title_end))

    what = "ui " + ",".join(a.action + [f"play:{a.play}"] * bool(a.play))
    out = phonelib.run_dir("ui-runs", a.out)
    ev = phonelib.Events(out)
    phone = phonelib.Phone(out, dry=a.dry_run, events=ev)
    nonce = secrets.token_hex(4)
    shots_taken = {"n": 0}

    def on_event(e):
        if e.get("event") == "title-done":
            title_end.update(e)
        if a.shot_each_action and e.get("event") == "ui-action":
            shots_taken["n"] += 1
            name = re.sub(r"[^A-Za-z0-9._=-]+", "_", e.get("action", "action"))
            path = phone.screenshot(os.path.join(out, f"action-{shots_taken['n']:02d}-{name}.png"))
            ev("screenshot", path=path, action=e.get("action"))
            # The app holds the next action until this file appears (UIDriver.waitForStep).
            marker = os.path.join(out, "cmd", "ui-step")
            open(marker, "w").close()
            phone.push(marker, f"Documents/ui-step-{e.get('index', shots_taken['n'])}")
        if e.get("event") == "ui-done" and any(x.split(":")[0] in ("install", "pause-resume", "queue", "downloading") for x in a.action):
            phone.pull("Documents/steam-drive.log", os.path.join(out, "pull"))

    if a.leave_running and not a.dry_run and not phonelib.holds_lock():
        ev("warning", message="--leave-running outside a session: the lock is released when this run ends, so "
                              "another agent's run can end the app or send it its pad; run the whole sequence "
                              "under one `pp phone lock -- CMD`")
    def terminated(signum, _frame):
        raise Terminated(signal.Signals(signum).name)
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, terminated)
    try:
        lock = contextlib.nullcontext() if a.dry_run else phonelib.device_lock(what, wait=a.lock_wait, events=ev)
        term = EndOnTerm(phone, a.leave_running or a.dry_run)
        with lock, term:
            ok, why, rec = (True, None, None) if a.dry_run else \
                phonelib.installed_check(a.expect_ipa, a.any_build, ev)
            if not ok:
                return phonelib.fail(ev, "pp ui: " + why)
            if rec:
                ev("installed", ipa_sha256=rec.get("ipa_sha256"), checkout=rec.get("checkout"),
                   head=rec.get("head"), variant=rec.get("variant"))
            phone.ensure()
            phone.bundle_id()   # refuses a phone without exactly one Playport
            if phone.kill():
                time.sleep(2)
            if not a.keep_log:
                phone.rotate_log()
            envs = ui_env(nonce, a.verify, a.play, a.action, a.settings_pair, a.shot_each_action, a.pad,
                          phonelib.session(), a.keep_settings)
            pid = phone.launch(envs)
            t0 = time.monotonic()
            t_wall = time.time()
            ev("launched", pid=pid, nonce=nonce, env=envs, out=out)
            if a.dry_run:
                return ev.result(True, 0, dry_run=True)

            def shoot(after):
                time.sleep(max(0, after - (time.monotonic() - t0)))
                p = phone.screenshot(os.path.join(out, f"screen-{after:04d}s.png"))
                ev("screenshot", path=p, after_s=after)
            shots = [threading.Thread(target=shoot, args=(s,), daemon=True) for s in sorted(a.screenshot_after)]
            for s in shots:
                s.start()

            why, done = phonelib.watch_launch(phone, ev, nonce, pid, a.until_spec, JIT_WAIT_S + a.wait, a.poll,
                                              ("ui-done", "title-done"), is_done, a.quiet, on_event)
            ev("stop", why=why, after_s=round(time.monotonic() - t0, 1))
            if a.shot and why in ("until", "done"):
                p = phone.screenshot(os.path.join(out, "screen-stop.png"))
                ev("screenshot", path=p, at="stop")
            for s in shots:
                s.join(timeout=0 if why == "timeout" else 150)
            if phone.pid() is not None and not a.leave_running:
                phone.kill()
            log = phone.pull("Documents/s1-host.log", os.path.join(out, "pull"))
            timeline = phonelib.summarize_log(log, out, phone.run_events(nonce))
            crashes = []
            if why == "exited" or (done and not ok_of(done)):
                crashes = phone.crashes(os.path.join(out, "crashes"), since=t_wall)
            if crashes:
                ev("crash-reports", files=crashes)
            ev("timeline", lines=timeline[-12:], file=os.path.join(out, "timeline.txt"))
            # The headline marks (JIT, game start, first frame) ride on the result line.
            marks = [re.sub(r"^.*?((?:title|jit): )", r"\1", x) for x in timeline
                     if re.search(r"title: \+|jit: acquire", x)]
            check = selfcheck_of(timeline, log)
            pool = pool_use(timeline)
            limits = limits_of(timeline)
            band = band_of(timeline)
            end = dict(out=out, timeline=marks, ipa_sha256=(rec or {}).get("ipa_sha256"),
                       **({"selfcheck": check} if check else {}),
                       **({"pool": pool} if pool else {}),
                       **({"limits": limits} if limits else {}),
                       **({"band": band} if band else {}),
                       **({"title": title_end.get("outcome")} if title_end and (done or {}).get("event") != "title-done" else {}),
                       **({"crashes": os.path.join(out, "crashes")} if crashes else {}))
            if why == "timeout":
                return ev.result(False, 2, why="no stop condition within --wait", **end)
            if why == "exited":
                return ev.result(False, 1, why="the app exited before the stop condition", **end)
            if done:
                ok = ok_of(done)
                if not ok and JIT_UNREACHABLE_RE.search(done.get("outcome", "") + "\n" + "\n".join(timeline)):
                    return ev.result(False, JIT_UNREACHABLE["exit"], done=done.get("outcome"),
                                     why=JIT_UNREACHABLE["why"], hint=JIT_UNREACHABLE["hint"], **end)
                return ev.result(ok, 0 if ok else 1, done=done.get("outcome"), **end)
            return ev.result(True, 0, why=f"until {a.until}", **end)
    except phonelib.PhoneError as e:
        return phonelib.fail(ev, str(e))
    except Terminated as e:   # while waiting for the lock: nothing ran
        return ev.result(False, 143, why="terminated", signal=str(e), out=out)
    return ev.result(False, 143, why="terminated", signal=term.signal, app_ended=term.app_ended, out=out)


# When a play last ended, for pp perf --cool: a game launched here heats the
# phone as one of pp perf's own runs does (tools/perf.py LAST_PLAY).
LAST_PLAY = os.path.join(phonelib.BUILD, "last-play.json")


def played(argv):
    a = parse(argv)
    return bool(a.play) or any(x.startswith("play:") for x in a.action)


def main_recorded(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        return main(argv)
    finally:
        if played(argv) and "--dry-run" not in argv:
            with contextlib.suppress(OSError):
                with open(LAST_PLAY, "w") as f:
                    json.dump({"ended": time.time(), "cmd": "pp ui " + " ".join(argv)}, f)


if __name__ == "__main__":
    sys.exit(main_recorded())
