# 0034: A gamepad-first, landscape UI

**Status:** accepted, 2026-09-30. Carries out the design in
[`docs/design/2026-09-28-gamepad-ui/`](../design/2026-09-28-gamepad-ui/) under the
[plan](../plans/finished.md#the-gamepad-first-ui). [0012](0012-the-ui-is-the-only-entry-point.md)
holds: everything stays in the UI.

## Decision

- **Landscape, for a controller.** The whole app is landscape, not only a
  title's screen. Home, Library and Downloads are switched with LB and RB, and
  Settings opens with ≡ or the gear. One focus ring is the only selection cue.
  A footer on every screen names what each button does, and tapping an entry
  does the same. Touch works everywhere.
- **The controller in the app's screens.** iOS gives SwiftUI no gamepad focus
  on iPhone, so the app reads every extended gamepad through GameController
  (`UI/Pad/PadRouter.swift`). HostIOKit's `PadNavigation` turns the pad's
  snapshots into presses: a button as it goes down, and a held direction that
  repeats. A direction moves the ring to the nearest item that way on screen
  (PlayportKit's `FocusMove`), and A runs the ringed item. Each other button
  runs its footer entry. When a game starts, HostIO takes the pads for the
  guest (`handOff`). Since the app restarts after a game
  ([0029](0029-restart-after-each-game.md)), the screens take the pads back
  only after a launch that ended before the runtime was used.
- **The driver presses buttons the same way.** A dev build's `pp ui --action
  pad:down+a` sends presses into the router a controller feeds. It is the
  scripted pad's counterpart for the app's own screens, not a new entry point.
- **Fewer knobs.** Environment variables are gone as a feature (#41). A game's
  launch settings are resolution, frame rate limit, Direct3D and launch
  arguments, each showing "Default · X" until changed. Memory ordering and the
  Steam API choice leave the release app, and dev builds keep them.
- **No compatibility labels.** "Plays well", "Tested" and "Untested" leave the
  UI: no rating, filter or badge on a game, and no "(tested)" mark on a version
  or a setting. The cohort ([0005](0005-title-cohort.md)) stays as data the
  player does not see.

## Why

Playport is for playing Windows games with a controller in hand, and the
games already run landscape. A portrait tab bar made the player put the
controller down, turn the phone, and pick a game by touch. Labels about which
games were tested described our test cohort, not the player's game, and hid
games that may well run.

## Costs and open items

- Every page is a new screen: the Library's grid (installed and owned games
  in one list, with chips, a sort and search), the game page with its Game
  options, Settings, and Downloads, whose queue is reorderable, queues
  updates by itself and is kept across the restart after a game.
- The controller's Home button, held, opens the in-game menu over a paused
  game (the plan's Hard problem 2), as the launch screen's tip says; a real
  controller's Home press has not been seen on the phone, only the driver's.
  The controller keyboard and the pickers exist (`UI/Pad/`); the
  Library's search and sort, the Game options and Settings use them.
- Memory ordering, block size and the Steam API choice are in a dev build's
  Game options only (its diagnostics and probes in Settings › Developer), and the release app's launch ignores them. The
  compatibility labels are gone: SteamClientKit
  has no `Compatibility`, and a game found in `C:\Games` reads Ready.
- Steam sign-in by account name asks for the password (the design's card
  did not): Steam's credential login needs it. It is typed on the
  controller keyboard as dots, goes to Steam encrypted, and is never stored
  or logged; the QR code stays beside it. A live credential sign-in has not
  run on the phone, only the screen's preview.
- The first run on iOS 27 shows the checklist instead of opening the
  on-phone pairing by itself: `JitSetup.bootstrap` is gone, and the
  checklist's pairing step (one A) or the first Play starts it. This
  changes how decision [0033](0033-on-device-pairing.md) is carried
  out, not that decision: a Play still handles the next missing
  requirement and resumes.
- The system share sheet (Report a problem, a dev build's logs) takes no
  pad focus: B closes it, and choosing where to send needs touch.
- An update or repair waiting in the queue keeps its game from playing
  until it finishes or is cancelled, and the game page says so; an update
  Playport queued by itself and the player cancelled waits for Steam's next
  version.
- Step 5 of the plan is done with the driver's presses
  ([evidence 2026-09-30-gamepad-ui](../evidence/2026-09-30-gamepad-ui.md)):
  every page walked, and Hollow Knight to its first frame and on through
  the new Play buttons and back through the in-game menu. Open, because
  they need a person at the phone: a real controller (its Home button held
  for the menu, touch on every screen), the launch failure screen and the
  slow-JIT steps (LocalDevVPN off), the first run by itself (no pairing), a
  live account-name sign-in (the paired session signed out), an automatic
  update and the cellular wait. madeira-unix 0048, which the menu's pause
  needed, changes the retry cadence of deferred holds for every game and
  was measured on Hollow Knight only.
- The restart after a game shows no screen of its own: the "Restarting
  Playport" screen is gone, and until the new process is up the app shows
  black, with no text or spinner, then Home. Decision 0029 did not promise
  that screen; only a restart that fails says anything.
