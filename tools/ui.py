#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""pp ui: drive the product UI on the phone (app/Sources/S1Probe/Dev/UIDriver.swift; dev builds only).

  pp ui [--action VERB:ARG ...] [--controls ID:JSON] [--settings ID:JSON] [--verify ID] [--play ID]
        [--shot-each-action] [--pad] [--out DIR] [--until SPEC] [--wait S] [--idle N] [--quiet]
        [--shot] [--screenshot-after S ...] [--leave-running] [--keep-log] [--lock-wait S]
        [--expect-ipa IPA|SHA256] [--any-build] [--keep-settings] [--capture-layer] [--dry-run]
        [--secret-file PATH | --secret-stdin]

The app starts as a Home Screen launch does, shows the
library, and does what a person would do with its buttons, through the same
model calls: each --action in order, then --controls, --settings, --verify, --play, regardless
of argv order. Use --settings with --play, not --action play:ID, to save settings
before playing. UI batches require Playport active before each action/press and after waits.
After initial launch readiness, inactive/background or cancellation permanently drops the queue;
reactivation never resumes it. Planned process replacement keeps revocation armed too: an
observed loss/cancel drops saved DRIVER continuation (even during normal replacement), not
product restart/game behavior. Prepare and announce a short focused UI-only batch first (no
arbitrary session timer, black interlude then input, or improvised navigation). Action success
and whole-device screenshots are NOT proof of the OS's foreground recipient. The gate is
app-local, not OS-wide input containment. SIGTERM/SIGHUP/Ctrl-C request nonce-bound UI queue
cancellation even with --leave-running (no gameplay kill in that mode). Delivery is bounded,
best-effort and reported as unconfirmed; transport loss/SIGKILL can leave cancellation uncertain.
--dry-run prints UI_ACTIONS without accessing the phone:

  open:SCREEN | open:ID  show a screen (home, library: the Library on All, installed: on All with Installed only,
                         games, gog, epic, battlenet: on that store's button in the store column, Battle.net's
                         with the store's offered products (open:bnet-CODE a product's page), downloads,
                         settings, account: Settings' Accounts section, setup: the first-run checklist as
                         Settings › Setup check's first row opens it, signin: Sign in to Steam, a preview
                         that sends nothing to Steam while Steam is signed in) or a title's page;
                         open:ID#SECTION opens its Game options at a section (graphics, controls, game,
                         files, developer, ordering, steam); open:ID#runtime and open:ID#graphicsoptions
                         ring/scroll the existing Runtime keys/Graphics options rows without opening
                         a keyboard or changing values. Unknown game sections fail. open:ID#gyro opens its Controls › Gyro aim
                         page, whose test area runs the gyro for its dot while it is up (no game);
                         open:ID#controller opens its Controller page (the game's controller map: the
                         mode ctl:mode, Look speed ctl:lookSpeed, Edit a copy ctl:copy, Reset all
                         ctl:resetAll, a row per input ctl:a, ctl:lt, ctl:leftStick, ctl:dpad...;
                         pad:up/down/left/right move one ring through every item in every mode
                         (down walks the header, the left column, Look speed, the right column),
                         pad:lb/rb cycle the mode, pad:a edits the ringed input (in Custom the
                         ActionPicker at once; as keyboard & mouse "Edit a copy?" first, as a
                         controller "Switch to Custom?" first), pad:y resets it, pad:b goes back; in
                         the ActionPicker pad:lb/rb switch tabs, pad:x waits for a hardware key,
                         pad:b cancels);
                         open:ID#layout opens its Controls › Edit on-screen layout: the layout editor
                         (no game running: over the game's art, dimmed) on the layout the game starts
                         with; pad:lb/rb ring a control (the selection), pad:up/down/left/right move it
                         one 8 pt grid step, pad:a opens the bar (Add, preset, Opacity, undo, redo,
                         Reset, Done) and the inspector (what it presses through the ActionPicker,
                         Label, Size, Hold/Toggle/Repeat, Duplicate, Remove) to the ring, whose
                         pad:directions and pad:a then work it and pad:b comes back; pad:x Add,
                         pad:y Reset, pad:view undo, pad:menu redo; pad:b on the controls is Done,
                         which saves the game's own copy ("layouts" below) and goes back;
                         open:settings#SECTION shows a Settings section (accounts, graphics, downloads,
                         controls, storage, setup, about, developer; also account, jit, memory,
                         diagnostics, pairing, probes, logs for the section that holds them,
                         controllers, the old name of controls, gyro: Controls at its Gyro aim rows,
                         and controller: Settings › Controls › Controller, the default's page);
                         open:licences shows Settings › About › Licences, open:licences#PREFIX the
                         files of the first component whose name starts with PREFIX (open:licences#wine);
                         there pad:down/up move through the rows and a text's paragraphs, pad:a opens
                         the ringed one, pad:b goes back a page.
                         open:black shows Settings › Developer › Black screen (pure black, lowest
                         brightness; a tap or any button wakes it; pp phone unattended).
                         open:black ends the batch: the black screen is a handoff, so no
                         action, press or step follows it, and it must be the last action.
                         In Settings up and down move along its list and show each section, right
                         goes into it, left and B come back, B on the list closes Settings;
                         pad:left/right change a Graphics value.
                         On the checklist (open:setup) pad:right/left or rb/lb move along its steps,
                         pad:a does the ringed one (Pair again re-pairs: not in a test). First run:
                         pad:x on Memory or Accounts puts it off; pad:b cannot leave until pairing
                         and VPN are ready, Increased Memory Limit is on or put off, and one account
                         (Steam, GOG or Epic Games) is signed in or Accounts is put off. The step's
                         saved key and driver names still use steam. Then the completion overlay's
                         pad:a/Continue leaves; pad:b closes only the overlay. Later visits always
                         allow pad:b. Settings' dev Preview a first run simulates each step with A.
                         On Sign in to Steam (open:signin) pad:a on its left card asks for the account
                         name, then the password, on the keyboard (neither is logged), pad:rb shows a
                         QR code, pad:b cancels or leaves; a real sign-in needs Steam signed out
  pad:BUTTON[+BUTTON...] (not directly after play:, see below) press controller buttons (a b x y lb rb lt rt menu view up down left right), 250 ms
                         apart, into the router a controller feeds (UI/Pad/PadRouter.swift):
                         pad:rb moves to the next page, pad:down+a opens what the ring moves to;
                         in the Library pad:lt/rt step along the store column, pad:left from the
                         grid's first column enters it and pad:up/down there switch the store;
                         on a game page pad:x opens its Game options and pad:y puts the ringed
                         setting back to its default, and pad:a on Play plays: the run follows the
                         game as for play: (use --until first-frame+S);
                         while the controller keyboard or a picker is up the presses are its
                         (the keyboard starts on q: pad:y+down+right+right+right+right+right+a
                         types "h" into the Library's search)
  wait:S                 wait S seconds (at most 600); after a play:, while the game runs
                         A pad: that follows play: and its wait:/tap:/menu:/web: actions without a menu:open
                         would run only after the game ends, so it is refused up front: to press buttons in
                         the game, `pp ui --pad ... --leave-running` and `pp pad send` in one `pp phone lock`
  tap:FX:FY              after a play:  (it runs while the game runs): a finger's tap at that fraction
                         (0-1) of the game's screen, through its touch path: on a guest window (a
                         launcher or a dialog shown before the game's first frame, decision 0075;
                         its first one is the `first window` mark, --until mark:first window+S;
                         or a dialog it opens after it, decision 0076, --until mark:dialog shown+S)
                         while one is shown, else on the game. While the on-screen controls show it
                         sends nothing: a touch outside them is ignored, and the app logs `tap …: ignored`
                         (above the open touch keyboard it is the game's, for a text field)
  touch:CONTROL[+CONTROL...][@MS]
                         after a play: (it runs while the game runs): wait for the game's first frame,
                         then fingers on the on-screen controls by id, held MS ms (200 by default,
                         10000 at most) and let go together (Dev/TouchDriver.swift). The Gamepad
                         layout's ids: view menu lt lb rt rb leftStick y x b a, and dpad and rightStick
                         when the game's controls have them ("dpad":"on", "rightStick":"below"|"above");
                         a stick or the d-pad takes a direction: dpad.right, leftStick.up.
                         Point & click's ids: pointer mode rightClick hover scroll keyboard esc; the
                         pointer surface takes a point, fractions of the view as in tap:
                         (pointer:0.25:0.6), else the finger lands at its middle; a tool's press turns
                         it on or off (touch:hover+pointer:0.5:0.5 hovers there).
                         With the touch keyboard open (a layout's keyboard key, menu:keyboard) its keys
                         are the controls instead: kb-a, kb-1, kb-f1, kb-esc, kb-enter, kb-space,
                         kb-backspace, kb-up, kb-shift, kb-ctrl, kb-alt, ... and kb-close; a tapped
                         kb-shift (kb-ctrl, kb-alt) stays down for the next key: touch:kb-shift touch:kb-a.
                         The controls show while no controller is connected (--pad connects one).
                         Example: --action play:app-367520 --action wait:20 --action touch:a
                         --action touch:leftStick.right@2000 --action touch:leftStick.right+a@600
                         The Keyboard & mouse layout's ids ("layout":"keyboardMouse"): look esc tab
                         keyboard 1 2 3 4 move use reload jump fire; move (the W A S D stick) takes a
                         direction (move.up holds W), and so does look: a finger lands in the look
                         area's middle and drags 100 pt that way at once (look.left turns the view left,
                         300 mouse counts; the log's `controls: driver drags look` line), then rests.
                         Example: --controls 'app-620:{"layout":"keyboardMouse"}' --action play:app-620
                         --action wait:30 --action touch:move.up@1500 --action touch:look.left+fire@400
  gyro:STEP[/STEP...]    after a play: (it runs while the game runs): wait for the game's first frame,
                         then play a scripted gyro into gyro aim where the sensors' samples enter it
                         (Dev/GyroDriver.swift, HostIOKit GyroScript), at 100 Hz, the device upright.
                         STEP is AXIS=DEG_PER_S[+AXIS=DEG_PER_S...]@MS or rest@MS: yaw + turns right,
                         pitch + up, roll + clockwise; at most 2000 deg/s, 1-10000 ms a step, 60 s in
                         all. While it plays its samples replace the sensors' (a phone still on the desk
                         does not fight it). It moves the aim only while the game's gyro output is on
                         (--controls 'ID:{"gyro":{"output":"mouse"}}' or "rightStick") and the sensors
                         run (no menu); the `gyro: driver` line in the log gives the mouse counts (20
                         per degree at sensitivity 1; the default is 1.5) or the right stick's peak (1 at
                         180 deg/s at sensitivity 1, then past its anti-dead-zone, 0.27 by default).
                         Example: --controls 'app-620:{"gyro":{"output":"mouse"}}' --action play:app-620
                         --action wait:30 --action gyro:yaw=90@500/rest@300/pitch=-30+yaw=10@300
                         With no game running and the Gyro aim page up, it moves the page's test-area dot
                         instead (nothing reaches a game): --action open:app-620#gyro --action gyro:yaw=30@500
  gesture:three-finger-tap
                         after a play: (it runs while the game runs): wait for the game's first frame,
                         then fire the three-finger tap through the handler the app's recognizer calls,
                         which opens the in-game menu with the on-screen controls on or off and with a
                         controller connected too (pad: and menu: then act on it)
  suggest:accept|dismiss
                         after a play: (it runs while the game runs): wait (3 min at most) for the toast
                         that offers Keyboard & mouse to a game on Gamepad that asked for no XInput state
                         in 20 s of play after its first frame (PlayportKit LayoutSuggestion), then press
                         its Use button (saves the layout for the game; `controls:` logs the new layout)
                         or its Not now. Fails when the game was not offered (it read a pad, it is not
                         on the starting Gamepad layout, its layout was chosen (its own, or Settings'
                         Starting layout rather than Suggested), or it was offered before: once per game;
                         --action set:controls.suggestedLayoutOffered= forgets every game's).
                         Example: --action play:ID --action suggest:accept --action touch:fire
  menu:open              after a play: (the actions after it then run while the game runs): wait for
                         the game's first frame, then hold the controller's Home button 0.8 s through
                         HostIO's pad handling, which opens Playport's in-game menu over the paused
                         game (UI/InGameMenuView.swift)
  menu:ROW               in that menu, move its ring to ROW (resume, controls, layout, keyboard, text, screenshot,
                         overlay, controller, quit) and press A; pad:up/down/a/b press into the menu while it is up.
                         menu:keyboard goes back to the game with the touch keyboard open over it; menu:text
                         goes back to it with the text bar and the iOS keyboard open over it (UI/TextBarView.swift).
                         menu:controls opens its Controls panel: pad:left/right change the ringed row
                         (On-screen controls: Off, Pad, Keys (Keyboard & mouse), Point (Point & click);
                         D-pad: Off, On; Right stick: Off, Below, Above A/B/X/Y, these two only on the
                         Gamepad layout with no copy of the game's own; Opacity;
                         Gyro aim: Off, Mouse, Right stick; Sensitivity; and, while a
                         controller is connected, --pad's scripted pad too, Controller: Pad, Keys &
                         mouse, Custom), pad:down/up move, pad:b goes back. pad:a on Controller (or
                         choosing Custom there) opens the Controller page over the paused game, which
                         pad: then drives as on a game page (the ActionPicker too); pad:b comes back
                         to the panel. pad:a on On-screen controls (or menu:layout, its Edit layout…) opens
                         the layout editor over the paused game, which pad: then drives as on
                         open:ID#layout; its Done (pad:b on the controls) saves and comes back to the panel.
                         The menu keeps the pads from the game all along.
                         menu:screenshot saves the frame to Photos (the first time iOS asks a person
                         to allow it) and, in a dev build, to Documents/Screenshots; menu:quit closes
                         the game's windows, and the run follows Playport's restart as for play:.
                         The scripted pad (--pad) has HOME too: `pp pad send "800 HOME" "100 -"`
                         opens the menu, and its presses are the menu's while it is up.
                         Example: --action play:app-367520 --action wait:10 --action menu:open
                         --action menu:resume --action wait:5 --action menu:open --action menu:quit
                         --action open:home --shot-each-action
  textbar:OP             after menu:text (it runs while the game runs): the text bar's own controls
                         (Dev/TextBarDriver.swift): textbar:close; textbar:secure or textbar:plain (its lock:
                         password mode on, dots, or off); textbar:tab, textbar:enter, textbar:backspace (its
                         keys, to the focused guest window); textbar:type:TEXT types TEXT into its field as
                         the keyboard would, each character a WM_CHAR (percent-encoded: %2C a comma, %25 a
                         percent sign; TEXT is in argv and the logs, so never a password)
  textbar:secret[+enter] password mode, then the value of --secret-file PATH (its one trailing newline
                         stripped) or --secret-stdin typed into the field (and Enter pressed once the value
                         is in the game's input queue; a textbar: action whose input no guest thread takes
                         for 5 s fails: the game is hung or busy). The value is
                         in no argv, environment, event, log or run file: the app asks for it when the action
                         runs (a `ui-secret-wanted` event), pp ui pushes it over AFC to
                         Documents/ui-text-<nonce>-<n> on stdin, and the app reads and deletes that file
                         before typing; a file the app did not take is removed when the run ends, however it
                         ends (an error or a signal too), and at the app's next start. Keep the file under
                         .work (gitignored), e.g. .work/secrets/wow-password.
                         --secret-file once serves every textbar:secret action; given once per action, the
                         Nth action types the Nth file (an account name, then a password). Example:
                         --action play:bnet-wow --action wait:60 --action menu:open --action menu:text
                         --action textbar:secret --action textbar:tab --action textbar:secret+enter
                         --secret-file .work/secrets/wow-email --secret-file .work/secrets/wow-password
  web:wait               after a play: (it runs while the game runs): wait (3 min at most) for a web
                         page the game opened in Playport's panel over the game (UI/GameWebSheet.swift),
                         press Open on its confirm card, and wait for the page (an Epic game's Epic
                         sign-in page opens signed in to Epic, decision 0064)
  web:click:LABEL        click the button or link whose text is LABEL in that page (letters, digits,
                         space . _ -), waiting 30 s at most for it: web:click:Allow gives an Epic
                         game the consent its sign-in asks for
  web:close              close the page, as its Close button does; the game gets its input back
                         Example: --action play:epic-8337d1f975514d35ad0c1176e8a29f26 --action web:wait
                         --action web:click:Allow --action wait:30 --action web:close --action wait:10
  set:KEY=VALUE          a UserDefaults key, as a Settings control sets it (set:metalHUD=true;
                         set:donorPoolMB=0|auto|2048|4096|6144: Settings › Graphics › Donor memory, next Play,
                         Auto when unset; auto sizes it from the phone's tier and the app's limit;
                         set:endGameSocialClubAfterSignIn=, set:refuseGameSocialClubRestart=: on when unset,
                         the end off under the Social Club layout unless set, decision 0169;
                         set:battlenetInstallBytes=N, dev builds: a Battle.net product needs N bytes, so a
                         size larger than free space shows the page's refusal; 0 or unset: the real size)
  hud:on | hud:off       Settings › Developer › Metal HUD (dev builds; on unless turned off)
  queue:APP              queue a download from Steam, as a game page's Install does, and go on at once
  downloading:APP        wait (2 min at most) until the queue runs APP's download with progress (after
                         the restart after a game, too), and log the queue
  install:APP            install from Steam with the paired session; pause-resume:APP pauses at a
                         quarter and resumes; install:gog-ID[@BUILD] installs or updates from GOG;
                         install:epic-APPNAME from Epic Games; install:bnet-CODE installs a Battle.net
                         product (bnet-wow_classic_era) in its page's region and language, refused with the
                         page's reason when it does not fit; pause-resume:bnet-CODE pauses it at a quarter,
                         checks Play stays hidden and the stage is kept, resumes, and checks Play shows
                         once it is complete
  region:bnet-CODE[=R]   a Battle.net product's page with its store region picker open (us, eu, kr, tw);
                         =R picks R as the picker does; on an installed product =R changes its region
                         in place (fails if a download starts or .build.info does not say R)
  locale:bnet-CODE[=L]   an installed Battle.net product's page with its Language picker open; =L (deDE)
                         downloads that language through Downloads and waits until .build.info says L
                         and Play shows again
  notice:bnet-CODE=accept|decline
                         an installed Battle.net copy's Play from its page and the ban-risk notice its
                         first Play shows (PLA-514), answered as the player does: decline checks Play
                         does not start; accept keeps the acceptance with the copy and the Play goes on,
                         followed as play: is. play:bnet-CODE is refused while the notice asks; past it,
                         Play checks for an update first (PLA-521): a newer build, or the x64 client an
                         install from before decision 0177 lacks, is updated through Downloads and play:
                         follows it to the game's start; a failed check is logged and the game starts
  update:bnet-CODE[=install]
                         an installed Battle.net product's page and its Check for update, logging what
                         it found (current, available with its size, or why it failed); =install also
                         queues the update it found and waits until .build.info names the new version
                         and the copy's client is the x64 one
  uninstall:ID, verify:ID
  repair:ID              the game page's Repair from Steam, which it offers after a verify: that did
                         not pass (bad files, or depots to check with Steam again); waits for the job
  import:PATH            Add a game with Documents/PATH (a folder or .zip put in the container) as
                         the picked item, then wait until it is in the library
  play:ID                Play. When the game ends, Playport restarts itself (decision 0029) and the
                         actions after it run in the new process, under this run
                         (Dev/DriverContinuation.swift); the run follows it across the restart.
                         When its prerequisites ran, Playport restarts before the game too and
                         the run follows the same Play into the new process (decision 0084).
                         A game whose cloud saves conflict is refused with the Cloud save
                         conflict screen up (the run ends there): open:ID, pad:a plays from
                         the game's page instead, and pad:a / pad:x / pad:b on that screen keep the
                         phone's saves, keep Steam's (either starts the game), or decide later.
                         Game options' Developer section has "Forget the cloud sync" (a first
                         sync next: a save that differs from Steam's becomes a conflict)
  open-launcher:ID       Settings › Launchers' Open for a publisher's launcher (rockstar), dev
                         builds: followed as play: is (its window is the `first window` mark;
                         --until "mark:first window+S"); refused when it is not installed
  forget-launcher-window:ID
                         Settings › Launchers' Forget the launcher's saved window settings, dev
                         builds: deletes that one file in the prefix (rockstar: its
                         settings_user.dat); the `launcher: forget-window` line says removed or absent
  probe:helper-exit | probe:helper-kill [-hold]
                         Settings' helper-lifetime probe (Dev/HelperLifetimeProbe.swift): the JIT
                         helper ticks, then the app ends itself by exit(0) or SIGKILL 2 s after
                         the run's done (use --leave-running); must be the last action. -hold:
                         the helper takes its own xpc transaction and ignores SIGTERM
  probe:memory-64 | probe:memory-2048 | probe:memory-4096
                         Settings' shared anonymous RAM experiment, verified in the app and helper
  probe:memory-donor-tagged-2048 | probe:memory-donor-tagged-4096
  probe:memory-donor-purgeable-2048 | probe:memory-donor-purgeable-4096
                         its donor variant: the helper (ledger-tagged or purgeable objects) ends
                         after allocating, the app keeps the mappings 60 s and logs the H1 verdict
  probe:memory-donors-6144 | probe:memory-donors-8192 | probe:memory-donors-10240
                         Settings' donor RAM pool: fresh helpers in turn give purgeable RAM and end
                         until the total is mapped, verified 60 s later, then the app's own remaining
                         limit (`donors ...` lines); fails when a donor or the phone runs out first.
                         The pool stays held for the actions after it
  probe:memory-pool-verify
                         Settings' Verify the donor pool: reads that held pool again
  probe:memory-pool-zero
                         Settings' Donor pool: zeroing: 1 GiB from a donor that ends, untouched; then
                         memset, purge, a fixed-address range mapping and four ways to zero or
                         give back 64 MiB of an object: memset, MADV_ZERO, MADV_FREE_REUSABLE(+memset) (`pool-zero ...` lines)
  probe:memory-pool-gpu
                         Settings' Donor pool: Metal buffers: 1 GiB from a donor that ends, as four
                         no-copy shared Metal buffers the GPU writes and the CPU reads back, a
                         64 MiB range view's buffer, then four ordinary buffers as the control, with
                         the footprint and graphics ledger at each step (`pool-gpu ...` lines)
  background:S           opens iOS Settings (S=10-600 retained grammar), then cancels the batch.
                         No automatic return or queued continuation; returning requires a NEW,
                         explicitly announced session. This also applies to JIT/Settings handoffs.
  probe:helper-report    read that probe's report back into s1-host.log (a later run, --keep-log)
  probe:native-auth      Settings' synthetic native GSS probe (no game or store credentials)
  jit:setup | jit:pair   Open the product setup (Pair again keeps old credentials until verified)
  jit:continue | jit:open-settings | jit:cancel | jit:wait
                         Resume/cancel/wait while active; opening system Settings needs the person
                         and terminally cancels this batch, not automatic reactivation.
  probe:settings-url-N   open Settings link N (OnDevicePairing's candidates), which leaves Playport:
                         the batch is cancelled as a handoff; screenshot with pp phone shot
  probe:pairing          Settings' on-device pairing experiment (iOS 27); use --leave-running
  probe:pairing-cancel | probe:pairing-use
                         Cancel, or wait for pairing, store it and check readiness
                         Use after probe:pairing in the SAME run (a later pp ui relaunches the app)
  probe:relaunch         Settings' Restart Playport now (AppRestart.swift): the restart after a game,
                         with no game; the run is done as it asks (use --leave-running); must be
                         the last action
  --controls ID:JSON     a game's own on-screen controls, as the in-game menu's Controls saves them
                         (PlayportKit GameControls: {"layout":"off"|"gamepad"|"keyboardMouse"|"pointClick",
                         "opacity":0.1-1,"dpad":"off"|"on","rightStick":"off"|"below"|"above","gyro":{...}}; a
                         key left out follows Settings › Controls, where the layout is the title's compatibility
                         default, else its Starting layout (set:controls.startingLayout=keyboardMouse; Gamepad by default), and the d-pad and
                         right stick are off by default;
                         `ID:{}` clears). "gyro" is the game's own gyro aim (PlayportKit GameGyro), each key
                         left out following the gyro.* defaults (output off): "output":"off"|"mouse"|
                         "rightStick", "source":"auto"|"phone"|"controller", "sensitivity":0.05-20 (1.5 by default),
                         "verticalRatio":0-4, "turnAxis":"playerSpace"|"yaw"|"roll", "invertX"/"invertY":
                         true|false, "pauseButton":"none"|"pad:BUTTON" (a b x y lb rb lt rt start back ls rs
                         up down left right), "antiDeadZone":0-0.9 (right stick: where its deflection starts,
                         0.27 by default), "smoothing":"auto"|"off"|"light"|"normal" (auto, the default: off for a
                         controller's gyro, normal for the iPhone's). Example: --controls 'app-620:{"gyro":{"output":"mouse"}}'
                         "controllerMap" is the game's controller map (PlayportKit ControllerMap), what a
                         physical controller (and --pad's scripted pad, not the on-screen controls) does:
                         {"mode":"controller"} (the default: an XInput pad), {"mode":"keyboardMouse"} (left
                         stick W A S D, right stick mouse look, RT/LT left/right mouse button, A Space, B C,
                         X R, Y F, LB Q, RB E, d-pad the arrow keys, BACK Tab, START Esc; Home stays
                         Playport's), or {"mode":"custom","table":{INPUT:ACTION,...}} (no table: a copy of
                         that preset). INPUT is a b x y lb rb lt rt start back ls rs up down left right,
                         leftStick/rightStick (whole: mouse:move, pad:leftStick, pad:rightStick) or
                         leftStick.up/down/left/right (likewise rightStick.*); ACTION is pad:CONTROL,
                         key:[shift+][ctrl+][alt+]0xVK, mouse:left|right|middle|wheelUp|wheelDown,
                         playport:menu. The log's `controls: controller map MODE for PAD (slot N)` line
                         shows the map each pad plays. Example: --controls
                         'app-620:{"controllerMap":{"mode":"keyboardMouse"}}' --pad
                         "lookSpeed" (0.1-8, Settings' controls.lookSpeed, 1 by default) is how fast a
                         stick bound to mouse:move turns the view, a multiple of 2000 counts/s (the
                         Controller page's Look speed row); a change logs `controls: look speed 2.0×`
                         "layouts" is the game's own copies of the presets, as the layout editor saves
                         them (GameControls.layouts): {"keyboardMouse":{"version":3,"controls":[...]},...},
                         keyed by gamepad, keyboardMouse or pointClick (not off), each a PlayportKit
                         ControlLayout version 3 whose controls have "id" (letters, digits, - and _, each
                         once), "kind" (button, the default, stick, dpad, lookArea, pointer, tool),
                         "actions" (a button one, a stick pad:leftStick|pad:rightStick or four up, down,
                         left, right, a d-pad four, a look area mouse:move, a pointer mouse:left, a tool
                         none and a "tool": rightClick|hover|scroll|trackpad; ACTION as above, also
                         playport:keyboard), "anchor" (topLeading ... bottomTrailing), "x", "y" (the
                         centre from the anchor, pt), "width", "height" (> 0), optional "label",
                         "behaviour" (hold|toggle|repeat) and, for a stick, "floatingZone" ({"anchor",
                         "width", "height", optional "x", "y"}). A copy is drawn while its preset is the
                         layout (choose it with "layout"); the log's `controls ID:` line says
                         layouts=keyboardMouse(N controls)
  --settings ID:JSON     a game's own launch settings, as its page saves them (PlayportKit
                         LaunchSettings: frame limit, screen, launch arguments; `ID:{}` clears);
                         `launcher-rockstar:JSON` is the runtime keys and FEX inputs open-launcher:rockstar
                         reads (dev). Actions run first: save them in an earlier pp ui of the same session
  --play ID              Play, as the button does, after --action/--settings/--verify; JIT via Setup check's method

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
the pool out (`pool=exhausted:<part>`) or FEX's host band (`band=exhausted`)
is not ok. With actions after a play:
action, the run is ok when they all ran and the last title's end was ok; the
result's `title` is that end. The result carries `until` and `until_reached`: a title that
ends (even with exit 0) before --until matched is not ok (exit 1, why "the title ended … before
--until SPEC", until_reached false); with the default `--until done` the clean end is the
checkpoint. last-play.json (for pp perf --cool) is written only after a play launched. Exit 0 ok, 1 failed or refused, 2
--wait (or the JIT wait) ran out or --idle fired, 5 an iOS system alert is over the app (why:
"system-alert", `alert`: its captions; see below), 4 the JIT helper could not reach the phone's VPN (why:
"jit-unreachable": LocalDevVPN is off; a person must turn it on, so retrying
does not help), 143 ended by SIGTERM (why: "terminated"; the app is ended
unless --leave-running). --wait S counts from JIT ready (the app's
"runtime started" mark): the launch gets 180 s to get JIT (about 4 s when it comes), then
S more seconds. A run that plays nothing has no JIT wait: S from the launch. The stop
event's `bound` says which ended a run: "wait", "jit" (no JIT in 180 s) or "idle".
--idle N (default off) also stops, before --until matches, when the game has started
and no app event came for N seconds; set it above the longest quiet stretch the title
has before its stop condition.

A system alert (a software-update notice, the Photos permission prompt) over the app stalls
every step and cannot be dismissed remotely. When the app's events have been quiet for 25 s
before --until matched, the run reads the phone's accessibility items (the same list
`pymobiledevice3 developer accessibility list-items` prints; it presses nothing) and, if a
caption looks like an iOS alert's ("Would Like to", "Don't Allow", "Not Installed", ...),
stops at once with exit 5, why "system-alert" and the captions in `alert`. A person must dismiss it.
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
# watch_launch's whys that end a run on a bound: the stop event's `bound`, the result's why.
STOP_BOUND = {"timeout": "wait", "jit-timeout": "jit", "idle": "idle"}
STOP_WHY = {"timeout": "no stop condition within --wait",
            "jit-timeout": f"no JIT within {JIT_WAIT_S} s",
            "idle": "no app event within --idle after the game started"}
# A catalogue title id: a lower-case store prefix, then its own id (an Epic app name can
# have capitals: epic-Buffalo).
ID_RE = re.compile(r"^[a-z]+-[A-Za-z0-9 ._-]+$")
SCREENS = ("home", "library", "installed", "games", "gog", "epic", "battlenet", "downloads", "settings", "account", "setup", "signin")   # AppNavigation.screens
PAD_BUTTONS = "a|b|x|y|lb|rb|lt|rt|menu|view|up|down|left|right"   # HostIOKit NavButton
# the app's launch failure when its JIT helper cannot reach LocalDevVPN's address
JIT_UNREACHABLE_RE = re.compile(r"Timed out connecting to 10\.7\.0\.1")  # "not ready for JIT: X" has other X too
JIT_UNREACHABLE = dict(why="jit-unreachable", exit=4,
                       hint="the JIT helper could not reach 10.7.0.1: LocalDevVPN is off on the phone. Ask the "
                            "person at the phone to connect it (and unlock the phone); retrying will not help")
# an iOS system alert over the app (PLA-119, PLA-219): nothing remote can press its buttons
SYSTEM_ALERT = dict(why="system-alert", exit=5,
                    hint="an iOS system alert is over the app (a software-update notice, the Photos permission "
                         "prompt) and blocks the run; remote tooling cannot dismiss it. Ask the person at the "
                         "phone to dismiss it (Allow for the Photos prompt), then run again")


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


def request_batch_cancel(phone, out, nonce, events):
    """One bounded, nonce-bound cancellation request, not proof the app consumed it."""
    if not re.fullmatch(r"[0-9a-f]{8}", nonce):
        raise ValueError("invalid active UI nonce")
    marker = os.path.join(out, "ui-cancel")
    with open(marker, "w") as f:
        f.write(nonce)
    phone.pmd("cancel-ui", "apps", "push", phone.bundle_id(), marker,
              f"Documents/ui-cancel-{nonce}", secs=10)
    result = {"delivery": "pushed", "confirmed": False}
    events("ui-cancel-request", **result)
    return result


class EndOnTerm:
    """Interruptions revoke the UI queue inside the lock, even with --leave-running.

    Cancellation delivery is best-effort, not an app acknowledgement. Only the
    existing non-leave behavior ends the app/game. No activation or retries.
    """
    def __init__(self, phone, leave, cancel=None):
        self.phone, self.leave, self.signal, self.app_ended = phone, leave, None, False
        self.cancel = cancel
        self.cancellation = {"delivery": "not-requested", "confirmed": False}

    def __enter__(self):
        return self

    def __exit__(self, kind, e, _tb):
        if kind not in (Terminated, KeyboardInterrupt):
            return False
        signals = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)
        handlers = {sig: signal.getsignal(sig) for sig in signals}
        try:
            for sig in signals:
                signal.signal(sig, signal.SIG_IGN)
            self.signal = "SIGINT" if kind is KeyboardInterrupt else str(e)
            if self.cancel:
                try:
                    self.cancellation = self.cancel()
                except (phonelib.PhoneError, OSError) as error:
                    self.cancellation = {"delivery": "failed", "confirmed": False, "error": str(error)}
            if not self.leave:
                with contextlib.suppress(phonelib.PhoneError):
                    self.app_ended = self.phone.kill()
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
        return True


class SecretsLeft:
    """The text bar secret files this run pushed that the app has not taken (by action number):
    removed, with a .part a cut-short push left (afc.py rm), however the run ends: a stop, a
    PhoneError, SIGINT, SIGTERM or SIGHUP. Inside EndOnTerm, so before its own handling; the
    signals are ignored while it removes."""
    def __init__(self, phone, files, events):
        self.phone, self.files, self.events = phone, files, events

    def remove(self):
        for n, remote in sorted(self.files.items()):
            with contextlib.suppress(phonelib.PhoneError, OSError):
                self.phone.remove(remote, check=False)
            self.files.pop(n)
            self.events("secret-removed", index=n)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        if not self.files:
            return False
        signals = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)
        handlers = {sig: signal.getsignal(sig) for sig in signals}
        try:
            for sig in signals:
                signal.signal(sig, signal.SIG_IGN)
            self.remove()
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
        return False


# PlayportKit OnScreenLayout's names: --controls' "layout".
LAYOUTS = ("off", "gamepad", "keyboardMouse", "pointClick")

# Dev/UIDriverGameSection.swift: per-game destinations, independent of title/store ID grammar.
GAME_SECTIONS = ("graphics", "controls", "game", "files", "developer", "ordering", "steam",
                 "gyro", "controller", "layout", "runtime", "graphicsoptions")

# A control of an on-screen layout, with a direction for a stick or the d-pad, or a point FX:FY (0-1 of the
# view) for Point & click's pointer surface (Dev/TouchDriver.swift).
TOUCH_CONTROL = r"[A-Za-z0-9_-]+(?:\.(?:up|down|left|right)|:(?:0(?:\.[0-9]+)?|1(?:\.0+)?):(?:0(?:\.[0-9]+)?|1(?:\.0+)?))?"
# A gyro: script's step (HostIOKit GyroScript): axis=deg/s terms joined by +, or rest, then @ms.
GYRO_TERM = r"(?:yaw|pitch|roll)=-?[0-9]{1,4}(?:\.[0-9]+)?"
GYRO_STEP = rf"(?:rest|{GYRO_TERM}(?:\+{GYRO_TERM})*)@[0-9]{{1,5}}"
ACTION_RE = re.compile((r"^(?:(?:install|pause-resume|queue|downloading):[0-9]+|install:gog-[0-9]+(?:@[0-9]+)?|install:epic-[A-Za-z0-9._-]+|(?:install|pause-resume):bnet-[a-z0-9_]+|region:bnet-[a-z0-9_]+(?:=(?:us|eu|kr|tw))?|locale:bnet-[a-z0-9_]+(?:=[a-z]{2}[A-Z]{2})?|(?:uninstall|verify|repair|play):[a-z]+-[A-Za-z0-9 ._-]+|(?:open-launcher|forget-launcher-window):[a-z]+"
                        r"|import:[A-Za-z0-9 ._()'+-]+(?:/[A-Za-z0-9 ._()'+-]+)*"
                       r"|notice:bnet-[a-z0-9_]+=(?:accept|decline)|update:bnet-[a-z0-9_]+(?:=install)?"
                       r"|hud:(?:on|off)|open:[a-z]+(?:-[A-Za-z0-9 ._-]+(?:#[a-z]+)?)?|open:settings#(?:accounts|steam|graphics|downloads|controls|controllers|gyro|controller|storage|setup|about|launchers|developer|account|jit|memory|diagnostics|pairing|probes|logs)|open:licences(?:#[a-z0-9 ._-]+)?|pad:(?:{b})(?:\+(?:{b}))*|set:[A-Za-z0-9._-]+=[^,]*"
                       r"|wait:[0-9]{1,3}|tap:(?:0(?:\.[0-9]+)?|1(?:\.0+)?):(?:0(?:\.[0-9]+)?|1(?:\.0+)?)|menu:(?:open|resume|controls|layout|keyboard|text|screenshot|overlay|controller|quit)"
                       r"|textbar:(?:close|secure|plain|tab|enter|backspace|secret(?:\+enter)?)|textbar:type:(?:[^,%\x00-\x1f\x7f]|%[0-9A-Fa-f]{2})+"
                       r"|touch:{t}(?:\+{t})*(?:@[0-9]{1,5})?|gyro:{g}(?:/{g})*|gesture:three-finger-tap|web:(?:wait|close)|web:click:[A-Za-z0-9 ._-]+"
                       r"|suggest:(?:accept|dismiss)"
                       r"|jit:(?:setup|pair|continue|open-settings|cancel|wait)|probe:settings-url-[0-9]|probe:helper-(?:(?:exit|kill)(?:-hold)?|report)|probe:memory-(?:64|2048|4096|donor-(?:tagged|purgeable)-(?:2048|4096)|donors-(?:6144|8192|10240)|pool-verify|pool-zero|pool-gpu)|background:(?:[1-9][0-9]|[1-5][0-9]{2}|600)|probe:relaunch|probe:native-auth|probe:pairing(?:-cancel|-use)?)$").replace("{b}", PAD_BUTTONS).replace("{t}", TOUCH_CONTROL)
                       .replace("{g}", GYRO_STEP))


def background_handoff(e):
    """Legacy diagnostic grammar, but never activate/resume an old UI batch."""
    return {"seconds": int(e.get("seconds", 0)), "pid": e.get("pid"), "automatic_return": False,
            "reason": "foreground handoff cancels the batch; new session required"}


def in_game(actions, start):
    """How many actions from start act on the running game (UIDriver.inGame): wait:, tap:,
    touch:, gyro:, gesture:, menu:, web:, suggest: and textbar:, and pad: once a menu:open or
    gesture:three-finger-tap has opened the in-game menu."""
    n, menu = 0, False
    for x in actions[start:]:
        if x.startswith(("wait:", "tap:", "touch:", "gyro:", "gesture:", "menu:", "web:", "suggest:", "textbar:")) \
                or (menu and x.startswith("pad:")):
            menu = menu or x in ("menu:open", "gesture:three-finger-tap")
            n += 1
        else:
            break
    return n


def is_play(action):
    """Whether an action starts a launch the run follows as a game: play:ID, open-launcher:ID
    (Settings › Launchers' Open, whose title is the launcher itself), or notice:bnet-CODE=accept
    (the ban-risk notice's accept goes on into that Play, UIDriver followPlay)."""
    return action.startswith(("play:", "open-launcher:")) or (action.startswith("notice:") and action.endswith("=accept"))


def pad_after_play(actions):
    """The first pad: that follows a play: and its in-game actions without a menu:open, or None.
    The app defers it to after the game ends (UIDriver.inGame), so a run that means it for the
    game waits for a game that does not end: refused up front."""
    for i, x in enumerate(actions):
        if is_play(x):
            nxt = i + 1 + in_game(actions, i + 1)
            if nxt < len(actions) and actions[nxt].startswith("pad:"):
                return actions[nxt]
    return None


def after_play(actions):
    """Whether an action follows the last play: in actions, past the ones for the running
    game (in_game): the app then runs it after the restart that follows the game, and the
    UI's done event, not the title's, ends the run."""
    plays = [i for i, x in enumerate(actions) if is_play(x)]
    return bool(plays) and plays[-1] + in_game(actions, plays[-1] + 1) < len(actions) - 1


def ends_run(e, actions, play, titles_done=1):
    """Whether an app event ends the run: the last play's title end unless an action
    follows it (titles_done counts title ends so far, this one included, so an earlier
    play's end in the same app run does not end it), the UI's own end unless a play
    (--play or a play: action, or menu:quit, which ends the game) comes last, a refused or
    failed action at once."""
    seq = list(actions) + [f"play:{play}"] * bool(play)
    if e.get("event") == "title-done":
        plays = sum(is_play(x) for x in seq)
        return titles_done >= plays and not after_play(seq)
    game_last = bool(seq) and (is_play(seq[-1]) or seq[-1] == "menu:quit")
    return not game_last or not e.get("outcome", "").startswith("ok")


def number(v, lo, hi):
    """Whether v is a JSON number (not a bool) within lo...hi."""
    return isinstance(v, (int, float)) and not isinstance(v, bool) and lo <= v <= hi


GYRO_SMOOTHING = ("auto", "off", "light", "normal")   # PlayportKit GyroSmoothingChoice
# PlayportKit GyroPauseButton: none, or a pad button (HostIOKit PadControl, not a stick).
GYRO_PAUSE = ("none",) + tuple("pad:" + b for b in "a b x y lb rb lt rt start back ls rs up down left right".split())


def gyro_ok(g):
    """Whether g is a PlayportKit GameGyro as JSON (--controls' "gyro"): only its keys, each valid."""
    return isinstance(g, dict) \
        and set(g) <= {"output", "source", "sensitivity", "verticalRatio", "turnAxis", "invertX", "invertY", "pauseButton",
                   "antiDeadZone", "smoothing"} \
        and g.get("output", "off") in ("off", "mouse", "rightStick") \
        and g.get("source", "auto") in ("auto", "phone", "controller") \
        and number(g.get("sensitivity", 1), 0.05, 20) and number(g.get("verticalRatio", 1), 0, 4) \
        and number(g.get("antiDeadZone", 0.27), 0, 0.9) \
        and g.get("turnAxis", "playerSpace") in ("playerSpace", "yaw", "roll") \
        and all(isinstance(g.get(k, False), bool) for k in ("invertX", "invertY")) \
        and g.get("pauseButton", "none") in GYRO_PAUSE \
        and g.get("smoothing", "auto") in GYRO_SMOOTHING


# PlayportKit ControllerMap / HostIOKit ControllerBindings: a table's inputs and actions, by name.
PAD_CONTROLS = "a b x y lb rb lt rt start back ls rs up down left right leftStick rightStick".split()
STICK_INPUTS = {s + "." + d for s in ("leftStick", "rightStick") for d in ("up", "down", "left", "right")}
STICK_ACTIONS = {"pad:leftStick", "pad:rightStick", "mouse:move"}
MAP_ACTION_RE = re.compile(r"pad:(?:" + "|".join(PAD_CONTROLS) + r")|mouse:(?:left|right|middle|wheelUp|wheelDown|move)"
                           r"|playport:menu|key:(?:(?:shift|ctrl|alt)\+)*(?:0[xX][0-9a-fA-F]{1,2}|[0-9]{1,3})")


def key_ok(action):
    """A key: action names a VK 1-255."""
    vk = action.rsplit("+", 1)[-1].removeprefix("key:")
    n = int(vk, 16) if vk.lower().startswith("0x") else int(vk)
    return 1 <= n <= 255


def controller_map_ok(c):
    """Whether c is a PlayportKit ControllerMap as JSON (--controls' "controllerMap"): a mode, and for
    custom an optional table INPUT -> ACTION where a whole stick takes only a stick's action, every
    other input anything else, and a stick is bound whole or by direction, not both. Home is no input."""
    if not isinstance(c, dict) or not set(c) <= {"version", "mode", "table"} or c.get("version", 1) != 1 \
            or c.get("mode") not in ("controller", "keyboardMouse", "custom"):
        return False
    table = c.get("table", {})
    if not isinstance(table, dict):
        return False
    for k, a in table.items():
        if k not in PAD_CONTROLS and k not in STICK_INPUTS:
            return False
        if not isinstance(a, str) or not MAP_ACTION_RE.fullmatch(a) or (a.startswith("key:") and not key_ok(a)):
            return False
        if (k in ("leftStick", "rightStick")) != (a in STICK_ACTIONS):
            return False
    return not any(s in table and any(k.startswith(s + ".") for k in table) for s in ("leftStick", "rightStick"))


# PlayportKit ControlLayout as JSON (--controls' "layouts": the game's own copies of the presets, as the
# layout editor saves them). This build reads version 3 only; Off has no layout.
LAYOUT_VERSION = 3
CONTROL_KINDS = ("button", "stick", "dpad", "lookArea", "pointer", "tool")   # PlayportKit ControlKind
ANCHORS = ("topLeading", "top", "topTrailing", "leading", "center", "trailing", "bottomLeading", "bottom",
           "bottomTrailing")                                                 # PlayportKit ControlAnchor
BEHAVIOURS = ("hold", "toggle", "repeat")                                    # HostIOKit TouchBehaviour
POINTER_TOOLS = ("rightClick", "hover", "scroll", "trackpad")                # HostIOKit PointerTool
# HostIOKit InputAction's saved names.
INPUT_ACTION_RE = re.compile(r"pad:(?:" + "|".join(PAD_CONTROLS) + r")|mouse:(?:left|right|middle|wheelUp|wheelDown|move)"
                             r"|playport:(?:menu|keyboard)|key:(?:(?:shift|ctrl|alt)\+)*(?:0[xX][0-9a-fA-F]{1,2}|[0-9]{1,3})")
CONTROL_ID_RE = re.compile(r"[A-Za-z0-9_-]+")
INF = float("inf")


def zone_ok(z):
    """Whether z is a PlayportKit ControlZone (a floating stick's): an anchor, a size, an optional offset."""
    return isinstance(z, dict) and set(z) <= {"anchor", "x", "y", "width", "height"} and z.get("anchor") in ANCHORS \
        and all(number(z.get(k, 0), -INF, INF) for k in ("x", "y")) \
        and all(number(z.get(k), 0, INF) and z[k] > 0 for k in ("width", "height"))


def control_ok(c):
    """Whether c is a PlayportKit Control as JSON, usable as ControlLayout.problem has it: its keys, an id of
    letters, digits, - and _, a size over 0, and the actions its kind takes."""
    if not isinstance(c, dict) or not set(c) <= {"id", "kind", "actions", "label", "behaviour", "anchor", "x", "y",
                                                 "width", "height", "floatingZone", "tool"}:
        return False
    kind, actions = c.get("kind", "button"), c.get("actions")
    if not (isinstance(c.get("id"), str) and CONTROL_ID_RE.fullmatch(c["id"]) and kind in CONTROL_KINDS
            and isinstance(c.get("label", ""), str) and c.get("behaviour", "hold") in BEHAVIOURS
            and c.get("anchor") in ANCHORS and all(number(c.get(k), -INF, INF) for k in ("x", "y"))
            and all(number(c.get(k), 0, INF) and c[k] > 0 for k in ("width", "height"))
            and isinstance(actions, list)
            and all(isinstance(a, str) and INPUT_ACTION_RE.fullmatch(a) and (not a.startswith("key:") or key_ok(a))
                    for a in actions)):
        return False
    sticks = [a in ("pad:leftStick", "pad:rightStick") for a in actions]
    if kind == "button":
        ok = len(actions) == 1 and not sticks[0]
    elif kind == "stick":
        ok = (len(actions) == 1 and sticks[0]) or (len(actions) == 4 and not any(sticks))
    elif kind == "dpad":
        ok = len(actions) == 4
    elif kind == "lookArea":
        ok = actions == ["mouse:move"]
    elif kind == "pointer":
        ok = actions == ["mouse:left"]
    else:
        ok = c.get("tool") in POINTER_TOOLS and actions == []
    return ok and ("tool" not in c or kind == "tool") and ("floatingZone" not in c or (kind == "stick" and zone_ok(c["floatingZone"])))


def layouts_ok(ls):
    """Whether ls is GameControls.layouts as JSON: preset name (not off) -> a version 3 ControlLayout whose
    controls are each usable and have different ids."""
    if not isinstance(ls, dict):
        return False
    for preset, layout in ls.items():
        if preset not in LAYOUTS or preset == "off" or not isinstance(layout, dict) \
                or set(layout) != {"version", "controls"} or layout["version"] != LAYOUT_VERSION \
                or not isinstance(layout["controls"], list) or not all(control_ok(c) for c in layout["controls"]):
            return False
        ids = [c["id"] for c in layout["controls"]]
        if len(ids) != len(set(ids)):
            return False
    return True


def ui_env(nonce, verify=None, play=None, extra=(), settings=None, step=False, pad=False,
           session=None, keep_settings=False, controls=None, capture_layer=False):
    """settings: (title id, LaunchSettings JSON) or None; controls: (title id, GameControls
    JSON) or None. step: the app waits after each
    action until the driver pushes Documents/ui-step-<nonce>-<n> (--shot-each-action). session:
    the device lock hold this launch is part of (the app undoes an earlier session's
    driven settings, and records this one's); keep_settings: record nothing to undo."""
    actions = (list(extra) + ([f"controls:{controls[0]}"] if controls else [])
               + ([f"settings:{settings[0]}"] if settings else [])
               + [f"verify:{verify}"] * bool(verify) + [f"play:{play}"] * bool(play))
    envs = ["S1_MODE=ui", "TITLE_NONCE=" + nonce]
    if actions:
        envs.append("UI_ACTIONS=" + ",".join(actions))
    if settings:
        envs.append("UI_SETTINGS=" + settings[1])
    if controls:
        envs.append("UI_CONTROLS=" + controls[1])
    if step:
        envs.append("UI_STEP=1")
    if pad:
        envs.append("HIO_VPAD=vpad.txt")
    if session:
        envs.append("UI_SESSION=" + session)
    if keep_settings:
        envs.append("UI_KEEP_SETTINGS=1")
    if capture_layer:
        # Metal loads its capture layer, which connects to Apple's GPU tools, only from the
        # launch environment: Settings' GPU capture setenv()s it too late (decision 0165).
        envs.append("MTL_CAPTURE_ENABLED=1")
    return envs


def windows_command_line(args):
    """A list of arguments as one launch-arguments string, as LaunchSettings.splitArguments reads
    it: split at spaces, double quotes group and are removed, there is no escape. An argument
    with a space is wrapped in quotes, an empty one is "", one with a double quote is refused."""
    out = []
    for x in args:
        if '"' in x:
            raise ValueError(f"argument {x!r} holds a double quote, which the launch arguments cannot carry")
        out.append(f'"{x}"' if (" " in x or not x) else x)
    return " ".join(out)


def title_ok(done):
    outcome = " " + done.get("outcome", "") + " "
    return (" exit=0x00000000 " in outcome and " pool=exhausted:" not in outcome
            and " band=exhausted " not in outcome)


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
                   help="open:SCREEN|ID[#SECTION], pad:BUTTON[+BUTTON...], wait:S, menu:open|ROW, touch:CONTROL[+CONTROL...][@MS], gyro:STEP[/STEP...], gesture:three-finger-tap, suggest:accept|dismiss, textbar:OP, textbar:type:TEXT, textbar:secret[+enter], set:KEY=VALUE, hud:on|off, install:APP, pause-resume:APP, region:bnet-CODE[=R], locale:bnet-CODE[=L], notice:bnet-CODE=accept|decline, update:bnet-CODE[=install], queue:APP, downloading:APP, import:PATH, uninstall:ID, "
                        "verify:ID, repair:ID, play:ID, probe:helper-exit|kill|report, probe:relaunch, probe:pairing[-cancel|-use]; in order, before --settings/--verify/--play")
    p.add_argument("--controls", metavar="ID:JSON",
                   help='save these on-screen controls for the title first ({"layout":"off"}, '
                        '{"layout":"keyboardMouse"}, {"layout":"pointClick"} or '
                        '{"layout":"gamepad","opacity":0.8,"dpad":"on","rightStick":"below"}, with "gyro":'
                        '{"output":"mouse","sensitivity":1.5} for its gyro aim, "controllerMap":{"mode":"keyboardMouse"} for its '
                        'controller map, "lookSpeed":2 for its mouse look, "layouts":{"keyboardMouse":{"version":3,'
                        '"controls":[...]}} for its own copies of the presets; {} clears them)')
    p.add_argument("--settings", metavar="ID:JSON",
                   help='save these launch settings for the title first ({"frameLimit":30,"screen":"720",'
                        '"arguments":"-DX12"}; "arguments" may also be a list of strings; {} clears them)')
    p.add_argument("--verify", metavar="ID", help="Verify files for this title first")
    p.add_argument("--play", metavar="ID", help="then Play this title")
    p.add_argument("--shot-each-action", action="store_true", help="a screenshot as each action completes")
    p.add_argument("--pad", action="store_true", help="start the scripted pad (HIO_VPAD=vpad.txt; pp pad plays it)")
    p.add_argument("--out", help="run directory (default: $PLAYPORT_BUILD/ui-runs/<time>)")
    p.add_argument("--until", default="done", help="done (default), first-frame[+S], mark:TEXT[+S] or event:NAME[+S]")
    p.add_argument("--wait", type=int, default=1800,
                   help="give up (and end the app) this many seconds after JIT is ready (a launch gets "
                        "180 s to get JIT first; default 1800)")
    p.add_argument("--idle", type=int, default=0, metavar="N",
                   help="give up when the game has started and no app event came for N seconds, "
                        "before --until matches (default off)")
    p.add_argument("--poll", type=float, default=3, help="seconds between reads of the app's events (default 3)")
    p.add_argument("--quiet", action="store_true", help="no reads of the phone between --until matching and its +S")
    p.add_argument("--shot", action="store_true", help="a screenshot when the run stops")
    p.add_argument("--screenshot-after", type=int, action="append", default=[], metavar="S",
                   help="a screenshot S seconds after the launch (repeatable)")
    p.add_argument("--leave-running", action="store_true", help="do not end the app at the end of the run")
    p.add_argument("--capture-layer", action="store_true",
                   help="start the app with Metal's capture layer (MTL_CAPTURE_ENABLED=1 at launch), so a "
                        "Mac's gpucapture, gpudebug and Xcode see it (pp gpu live; costs every frame)")
    p.add_argument("--keep-log", action="store_true", help="do not move s1-host.log aside before the launch")
    p.add_argument("--lock-wait", type=int, help="seconds to wait for the device lock (default: as long as it takes)")
    p.add_argument("--expect-ipa", metavar="IPA|SHA256",
                   help="refuse unless the phone has this IPA (pp install's record in the shared device-state.json)")
    p.add_argument("--any-build", action="store_true",
                   help="drive whatever the phone has, even an IPA another checkout installed")
    p.add_argument("--keep-settings", action="store_true",
                   help="keep this run's set:, hud: and --settings changes after the session (default: undone)")
    p.add_argument("--dry-run", action="store_true", help="print the device commands; touch nothing")
    secret = p.add_mutually_exclusive_group()
    secret.add_argument("--secret-file", metavar="PATH", action="append",
                        help="the value textbar:secret types (one trailing newline stripped); keep it under .work, "
                             "e.g. .work/secrets/wow-password. It reaches the phone only as the file the app asks for. "
                             "Once for every textbar:secret action, or once per action in their order")
    secret.add_argument("--secret-stdin", action="store_true", help="read textbar:secret's value from stdin instead")
    a = p.parse_args(argv)
    for t in (a.verify, a.play):
        if t is not None and not ID_RE.match(t):
            p.error(f"{t!r} is not a catalogue title id (app-367520)")
    for x in a.action:
        if not ACTION_RE.match(x) or (x.startswith("open:") and "-" not in x.split("#")[0]
                                      and x[5:].split("#")[0] not in SCREENS + ("licences", "black")):
            p.error(f"{x!r} is not open:SCREEN|ID, pad:BUTTON[+BUTTON...], wait:S, menu:open|ROW, touch:CONTROL[+CONTROL...][@MS], gyro:STEP[/STEP...], gesture:three-finger-tap, suggest:accept|dismiss, textbar:close|secure|plain|tab|enter|backspace|secret[+enter], textbar:type:TEXT (no comma: %2C), set:KEY=VALUE, hud:on|off, install:APP, pause-resume:APP, region:bnet-CODE[=R], locale:bnet-CODE[=L], notice:bnet-CODE=accept|decline, update:bnet-CODE[=install], "
                    "queue:APP, downloading:APP, import:PATH, uninstall:ID, verify:ID, repair:ID, play:ID, open-launcher:ID, forget-launcher-window:ID, probe:helper-exit|kill|report, probe:relaunch or probe:pairing[-cancel|-use]")
        if x.startswith("open:") and "#" in x:
            target, section = x[5:].split("#", 1)
            if target not in ("settings", "licences") and section not in GAME_SECTIONS:
                p.error(f"{x!r}: unknown Game options section; choose " + ", ".join(GAME_SECTIONS))
    # textbar:secret's value has one source, given only with the action (PLA-606).
    wants_secret = any(x.startswith("textbar:secret") for x in a.action)
    has_source = bool(a.secret_file or a.secret_stdin)
    if wants_secret != has_source:
        p.error("textbar:secret needs --secret-file PATH or --secret-stdin" if wants_secret
                else "--secret-file and --secret-stdin go with a textbar:secret action only")
    asking = sum(x in SECRET_ACTIONS for x in a.action)
    if a.secret_file and len(a.secret_file) not in (1, asking):
        p.error(f"--secret-file given {len(a.secret_file)} times for {asking} textbar:secret action(s): "
                "once for all of them, or once each")
    for path in a.secret_file or ():
        if not os.path.isfile(path):
            p.error(f"--secret-file {path!r} is not a file")
    # The black screen hands the screen over: the app ends the batch there, so no action,
    # press or step may follow it (and --controls/--settings/--verify/--play append actions).
    black = [i for i, x in enumerate(a.action) if x == "open:black"]
    if black and (black != [len(a.action) - 1] or a.controls or a.settings or a.verify or a.play):
        p.error("open:black ends the batch: no action, press or step follows the black screen, "
                "so it must be the last action")
    seq = a.action + [f"play:{a.play}"] * bool(a.play)
    pad = pad_after_play(seq)
    if pad:
        p.error(f"{pad!r} follows play: and would run only after the game ends, not while it runs. To press "
                "buttons in the game use `pp ui --pad ... --leave-running` and `pp pad send` in one "
                "`pp phone lock -- sh -c '...'`; pad: works with menu:open (the in-game menu) or on screens "
                "before play:")
    a.controls_pair = None
    if a.controls:
        cid, _, cjs = a.controls.partition(":")
        try:
            cobj = json.loads(cjs)
            ok = ID_RE.match(cid) and isinstance(cobj, dict) \
                and set(cobj) <= {"layout", "opacity", "dpad", "rightStick", "gyro", "controllerMap", "lookSpeed", "layouts"} \
                and cobj.get("layout", "off") in LAYOUTS \
                and number(cobj.get("opacity", 0.5), 0.1, 1) \
                and cobj.get("dpad", "off") in ("off", "on") \
                and cobj.get("rightStick", "off") in ("off", "below", "above") \
                and gyro_ok(cobj.get("gyro", {})) \
                and ("controllerMap" not in cobj or controller_map_ok(cobj["controllerMap"])) \
                and number(cobj.get("lookSpeed", 1), 0.1, 8) \
                and layouts_ok(cobj.get("layouts", {}))
        except ValueError:
            ok = False
        if not ok:
            p.error(f"{a.controls!r} is not ID:JSON with layout ({', '.join(LAYOUTS)}), opacity (0.1-1), dpad (off, on), "
                    "rightStick (off, below, above) and gyro (an object: output off|mouse|rightStick, source "
                    "auto|phone|controller, sensitivity 0.05-20, verticalRatio 0-4, turnAxis playerSpace|yaw|roll, "
                    "invertX/invertY true|false, pauseButton none|pad:BUTTON, antiDeadZone 0-0.9, smoothing auto|off|light|normal) "
                    "and controllerMap "
                    "(an object: mode controller|keyboardMouse|custom, table INPUT:ACTION) and lookSpeed (0.1-8) "
                    "and layouts (an object: PRESET (gamepad, keyboardMouse, pointClick): a ControlLayout, version 3, "
                    "whose controls each have an id, kind, actions, anchor, x, y, width and height) only")
        a.controls_pair = (cid, json.dumps(cobj, separators=(",", ":")))
    a.settings_pair = None
    if a.settings:
        sid, _, js = a.settings.partition(":")
        try:
            obj = json.loads(js)
            ok = ID_RE.match(sid) and isinstance(obj, dict)
        except ValueError:
            ok = False
        if not ok:
            p.error(f"{a.settings!r} is not ID:JSON with a JSON object")
        if isinstance(obj.get("arguments"), list):
            if not all(isinstance(x, str) for x in obj["arguments"]):
                p.error('--settings "arguments" as a list must hold only strings')
            try:
                obj["arguments"] = windows_command_line(obj["arguments"])
            except ValueError as e:
                p.error(str(e))
            js = json.dumps(obj, separators=(",", ":"))
        elif "arguments" in obj and not isinstance(obj["arguments"], str):
            p.error('--settings "arguments" is a string (or a list of strings, joined with Windows quoting)')
        a.settings_pair = (sid, js)
    try:
        a.until_spec = phonelib.parse_until(a.until)
    except ValueError as e:
        p.error(str(e))
    return a


# textbar:secret (PLA-606; Dev/TextBarDriver.swift): the actions that ask for the value, and
# the file name it goes to, Documents/ui-text-<nonce>-<action number> (afc.py put-secret).
SECRET_ACTIONS = ("textbar:secret", "textbar:secret+enter")
SECRET_PREFIX = "ui-text-"


def read_secrets(a):
    """textbar:secret's values as bytes, one per --secret-file (or one from stdin), each with one
    trailing newline (\\n or \\r\\n) stripped; [] without a source. Kept in memory only."""
    def strip(data):
        for end in (b"\r\n", b"\n"):
            if data.endswith(end):
                return data[:-len(end)]
        return data
    if a.secret_stdin:
        return [strip(sys.stdin.buffer.read())]
    values = []
    for path in a.secret_file or ():
        with open(path, "rb") as f:
            values.append(strip(f.read()))
    return values


def main(argv=None, launched=None):
    """launched: a dict main sets "play" in once it has launched a title (main_recorded's
    last-play.json is written only then)."""
    a = parse(argv)
    until_hit = {"seen": False}

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
    ui_done = {"seen": None}
    # textbar:secret (PLA-606): the values only here, in memory; the files pushed for them, by action
    # number. The Nth action the app asks for gets the Nth value (or the only one).
    secret_values = read_secrets(a)
    if any(v == b"" for v in secret_values):
        return phonelib.fail(ev, "pp ui: a textbar:secret value is empty")
    secret_files = {}
    secrets_asked = {"n": 0}
    # The app's ui-secret-wanted names the action's number only (Dev/TextBarDriver.swift); it is
    # answered while this run's textbar:secret actions have not all been served.
    secret_actions = sum(x in SECRET_ACTIONS for x in a.action)

    def on_event(e):
        if e.get("event") == "ui-secret-wanted":
            n = e.get("index")
            action = e.get("action", "textbar:secret")
            if not secret_values or action not in SECRET_ACTIONS or not isinstance(n, int) or n in secret_files \
                    or secrets_asked["n"] >= secret_actions:
                ev("warning", message=f"the app asked for a secret for action {n} ({action}), which is no "
                                      "textbar:secret action waiting for one: nothing pushed")
            else:
                k = min(secrets_asked["n"], len(secret_values) - 1)
                secrets_asked["n"] += 1
                secret_files[n] = f"Documents/{SECRET_PREFIX}{nonce}-{n}"
                phone.put_secret(secret_files[n], secret_values[k])
                ev("secret-pushed", index=n)
        if e.get("event") == "ui-action" and e.get("index") in secret_files:
            # The app deleted it before typing, so its action is done.
            secret_files.pop(e["index"])
        if phonelib.until_matches(a.until_spec, e):
            until_hit["seen"] = True
        if e.get("event") == "title-done":
            title_end.update(e)
        if e.get("event") == "ui-done":
            ui_done["seen"] = e
        if a.shot_each_action and e.get("event") == "ui-action":
            def cancelled_step():
                # These are app-local events, NOT proof of the OS foreground recipient.
                # A late marker can never revive UIDriver's latched cancelled queue.
                return e.get("result") != "ok" or any(
                    item.get("event") == "ui-done" and not item.get("outcome", "").startswith("ok")
                    for item in phone.run_events(nonce))
            if cancelled_step():
                ev("step-cancelled", action=e.get("action"), reason="batch failed/cancelled; no screenshot or ack")
                return
            shots_taken["n"] += 1
            name = re.sub(r"[^A-Za-z0-9._=-]+", "_", e.get("action", "action"))
            path = phone.screenshot(os.path.join(out, f"action-{shots_taken['n']:02d}-{name}.png"))
            ev("screenshot", path=path, action=e.get("action"))
            if cancelled_step():
                ev("step-cancelled", action=e.get("action"), reason="batch cancelled during screenshot; no ack")
                return
            # The app holds the next action until this file appears (UIDriver.waitForStep).
            marker = os.path.join(out, "cmd", "ui-step")
            open(marker, "w").close()
            phone.push(marker, f"Documents/ui-step-{nonce}-{e.get('index', shots_taken['n'])}")
        if e.get("event") == "ui-background":
            ev("background-handoff", **background_handoff(e))
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
        left = SecretsLeft(phone, secret_files, ev)
        with lock, term, left:
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
                          phonelib.session(), a.keep_settings, a.controls_pair, a.capture_layer)
            if not a.dry_run:
                # Captured current nonce only; no callback while merely waiting for the lock.
                term.cancel = lambda: request_batch_cancel(phone, out, nonce, ev)
            pid = phone.launch(envs)
            t0 = time.monotonic()
            t_wall = time.time()
            ev("launched", pid=pid, nonce=nonce, env=envs, out=out)
            if a.dry_run:
                return ev.result(True, 0, dry_run=True)
            if launched is not None and plays(a):
                launched["play"] = True

            def shoot(after):
                time.sleep(max(0, after - (time.monotonic() - t0)))
                p = phone.screenshot(os.path.join(out, f"screen-{after:04d}s.png"))
                ev("screenshot", path=p, after_s=after)
            shots = [threading.Thread(target=shoot, args=(s,), daemon=True) for s in sorted(a.screenshot_after)]
            for s in shots:
                s.start()

            why, done = phonelib.watch_launch(phone, ev, nonce, pid, a.until_spec, a.wait, a.poll,
                                              ("ui-done", "title-done"), is_done, a.quiet, on_event,
                                              JIT_WAIT_S if plays(a) else None, a.idle or None,
                                              None if a.dry_run else phone.system_alert)
            ev("stop", why=why, after_s=round(time.monotonic() - t0, 1),
               **({"bound": STOP_BOUND[why]} if why in STOP_BOUND else {}))
            # A secret the app did not take (the run stopped first) goes now; one an error or a
            # signal cuts the run short goes as SecretsLeft exits; the app's next start removes
            # one this misses (Dev/TextBarDriver.swift).
            left.remove()
            # --leave-running with no finished batch would let the app run the queued actions
            # unsupervised. Request ONE bounded, nonce-bound cancellation (best-effort: not
            # proof the app consumed it); a ui-done exit is left exactly as it was.
            cancellation = None
            if a.leave_running and why not in ("done", "exited") and ui_done["seen"] is None:
                ev("warning", message="the run stopped with queued input unfinished and the app left "
                                      "running; requesting one best-effort cancellation for this batch "
                                      "(unconfirmed)")
                try:
                    cancellation = request_batch_cancel(phone, out, nonce, ev)
                except (phonelib.PhoneError, OSError) as error:
                    cancellation = {"delivery": "failed", "confirmed": False, "error": str(error)}
                    ev("warning", message=f"the cancellation request could not be delivered: {error}")
            if a.shot and why in ("until", "done", "alert"):
                p = phone.screenshot(os.path.join(out, "screen-stop.png"))
                ev("screenshot", path=p, at="stop")
            for s in shots:
                s.join(timeout=0 if why in STOP_BOUND else 150)
            if phone.pid() is not None and not a.leave_running:
                phone.kill()
            log = phone.pull("Documents/s1-host.log", os.path.join(out, "pull"))
            timeline = phonelib.summarize_log(log, out, phone.run_events(nonce))
            crashes = []
            if why == "exited" or (why != "alert" and done and not ok_of(done)):
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
            reached = (why == "done") if a.until_spec[0] == "done" else (until_hit["seen"] or why == "until")
            end = dict(out=out, until=a.until, until_reached=reached, timeline=marks, ipa_sha256=(rec or {}).get("ipa_sha256"),
                       **({"cancellation": cancellation} if cancellation else {}),
                       **({"selfcheck": check} if check else {}),
                       **({"pool": pool} if pool else {}),
                       **({"limits": limits} if limits else {}),
                       **({"band": band} if band else {}),
                       **({"title": title_end.get("outcome")} if title_end and (done or {}).get("event") != "title-done" else {}),
                       **({"crashes": os.path.join(out, "crashes")} if crashes else {}))
            if why == "alert":
                return ev.result(False, SYSTEM_ALERT["exit"], why=SYSTEM_ALERT["why"], alert=done["alert"],
                                 hint=SYSTEM_ALERT["hint"], **end)
            if why in STOP_BOUND:
                return ev.result(False, 2, why=STOP_WHY[why], **end)
            if why == "exited":
                return ev.result(False, 1, why="the app exited before the stop condition", **end)
            if done:
                ok = ok_of(done)
                if ok and done.get("event") == "title-done" and not reached:
                    return ev.result(False, 1, done=done.get("outcome"),
                                     why=f"the title ended ({done.get('outcome', '').strip()}) before --until {a.until}", **end)
                if not ok and JIT_UNREACHABLE_RE.search(done.get("outcome", "") + "\n" + "\n".join(timeline)):
                    return ev.result(False, JIT_UNREACHABLE["exit"], done=done.get("outcome"),
                                     why=JIT_UNREACHABLE["why"], hint=JIT_UNREACHABLE["hint"], **end)
                return ev.result(ok, 0 if ok else 1, done=done.get("outcome"), **end)
            # A title that ended with an error before the stop condition: the app restarts
            # itself after it (AppRestart), so the watch can reach --until in the new process
            # without seeing the end (2026-10-06, vk-s3-dxvk-notiler1). Its log line says so.
            ended = title_failed(log, nonce)
            if ended:
                return ev.result(False, 1, why=f"the title ended before the stop condition: {ended}", **end)
            return ev.result(True, 0, why=f"until {a.until}", **end)
    except phonelib.PhoneError as e:
        return phonelib.fail(ev, str(e))
    except (Terminated, KeyboardInterrupt) as e:   # while waiting for the lock: nothing ran
        return ev.result(False, 130 if isinstance(e, KeyboardInterrupt) else 143,
                         why="terminated", signal="SIGINT" if isinstance(e, KeyboardInterrupt) else str(e), out=out)
    return ev.result(False, 130 if term.signal == "SIGINT" else 143, why="terminated", signal=term.signal,
                     app_ended=term.app_ended, cancellation=term.cancellation, out=out)


def title_failed(log, nonce):
    """The `exit=… after_s=…` of this launch's `title: done` line when the title ended
    with a nonzero code (or a launch failure); None when it did not end, or ended with 0."""
    try:
        with open(log, errors="replace") as f:
            for line in f:
                m = re.search(r"title: done nonce=" + re.escape(nonce) + r" (.*)$", line)
                if m and not re.match(r"exit=0x0+ ", m[1] + " "):
                    return m[1].strip()
    except (OSError, TypeError):
        pass
    return None


# When a play last ended, for pp perf --cool: a game launched here heats the
# phone as one of pp perf's own runs does (tools/perf.py LAST_PLAY).
LAST_PLAY = os.path.join(phonelib.BUILD, "last-play.json")


def plays(a):
    return bool(a.play) or any(is_play(x) for x in a.action)


def played(argv):
    return plays(parse(argv))


def main_recorded(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    launched = {}
    try:
        return main(argv, launched)
    finally:
        if launched.get("play"):
            with contextlib.suppress(OSError):
                with open(LAST_PLAY, "w") as f:
                    json.dump({"ended": time.time(), "cmd": "pp ui " + " ".join(argv)}, f)


if __name__ == "__main__":
    sys.exit(main_recorded())
