# iPhone Duo: both panels, fold and unfold

**Date:** 2026-10-26. **Phone:** iPhone Duo (iPhone19,4, A20 Pro, TXM present), iOS 27.1
(24A94425), and Xcode 27.1's iPhone Duo simulator. **Build:** dev variant, trees from this
branch's pins built in the arm64 container (`build/docker/README.md`), app linked and signed by
Xcode with a free Personal Team (`app/Xcode/`). Built-in JIT, LocalDevVPN.

## What the phone is

Two integrated panels, each its own `UIScreen`:

| Panel | Native pixels | Points (landscape) | Safe area (landscape) |
| --- | --- | --- | --- |
| Cover (`LCD`, primary) | 1398 x 2034 | 678 x 466 | 84 at the camera side, 0 at the other, 34 below |
| Inner (`LCD-1`) | 1878 x 2670, rendered at 2007 x 2853 | 951 x 669 | 0 / 84 (camera column) |

The inner panel opens like a passport: held upright, it is landscape-shaped. `UIScreen.main`
is the cover panel even while the app is on the inner one.

## Found, and what changed

- **Compatibility mode.** 0.4.0 (linked against the iOS 26 SDK) runs on the cover panel in a
  16:9 window with a black band. The same binary with only its SDK field set to 27.1 fills the
  panel. An Xcode 27.1 build does.
- **The guest screen came from `UIScreen.main`.** On the inner panel that is the cover's size.
  `Panel.swift` reads the scene's own screen and window; the pickers and `TitleScreen` use it.
  On the phone: `display: screen 1024x720 (the title's screen 720) (iPhone19,4 panel 2007x2853
  px, window 2853x2007 px)`.
- **The gamepad UI is laid out for about 750 points between the safe-area edges.** The cover
  panel has 594: four checklist cards, the footer's hints and the settings values ran off the
  trailing edge. `UI/PanelFit.swift` lays the shell out on a 640-point canvas and draws it at
  90% there; the inner panel and other iPhones are drawn at 100%. Settings takes a slimmer list
  and margins on a narrow page; the checklist's footer note is left out where it would overlap
  the hints.
- **One side has no inset.** Pages put their edge on the panel's rounded edge (the game page
  at x = 0). PanelFit keeps 20 points at least, also inside the Library's `NavigationStack`,
  which takes the window's safe area from UIKit (`panelSides()`).
- **The inner panel turned sideways** showed the landscape-only app letterboxed. The app now
  turns with the phone on a panel whose short side is 600 points or more, portrait too, and
  stays landscape on the cover panel and on every other iPhone. The status bar, which an
  iPhone hides in landscape and the inner panel does not, is hidden.
- **Fold and unfold while running**: the shell follows at once (`ui: panel …` lines); a game
  surface takes the new panel's scale and safe area.
- **Hero art** (about 3:1) filled the whole page and lost more than half its width on the
  cover panel; it now fills a band no wider than 2:1 at the top and fades into the page.
- **Top bar targets** were the tabs' letters only (a plain button with a clear background);
  they now take the bar's whole height.

## On the phone

- Setup checklist: Memory ticked (Increased Memory Limit kept by Xcode's Personal Team
  signing), LocalDevVPN, on-device pairing.
- JIT: `jit: helper: prepare: checking the DDI mount`, `device ready`, `TXM present`. The
  personalized DDI's manifest has no 0x8160 chip; StikJIT 1.9.0 took the Cryptex DDI.
- **Hollow Knight** (`app-367520`): plays, on the inner panel.
- Memory: `limit 6144 MB`, phone 11571 MB; a title's limit 8192 MB.

## Virtual gamepad (2026-10-27)

A game's option on a foldable (Game options › Virtual gamepad): opened and held upright, the
game takes the top half and an on-screen controller the bottom one, an XInput pad of its own
(`virtual gamepad: XInput slot 0, layout "PlayStation"` at each launch). Its layouts (Xbox's,
PlayStation's and the player's own: each control's place, size and whether it shows, and
vibration on press) are in Settings › Virtual gamepad; a game picks one on its page, and the
in-game menu takes the next or edits it in place.

- **Hollow Knight** and **PEAK** played with it: face buttons, d-pad, shoulders, Start and the
  stick clicks reached the game (`hostio: pad0 buttons=…`); the in-game menu opened from the
  pad's Home and closed. The layout editor and switching layouts from the menu were checked by
  hand on the phone.
- The app starts upright on the inner panel held upright: Info.plist now lists portrait, since
  iOS starts an app only in a listed orientation; the app delegate keeps the cover panel and
  other iPhones landscape (Duo simulator folded and open, both ways; iPhone 18 Pro simulator).

## Not working: Mewgenics (`app-686060`)

First frame at +3.59 s, then an access violation at +13 to +18 s, every launch: the game
reserves 1 GB ranges one after another (`[jumbo#1]` to `[jumbo#42]`, 43008 MB reserved, 6 MB
committed) and the 43rd is refused (`c0000017`, `top window is full`); the game writes through
the NULL (`write access to 0000000000000008` in Mewgenics.exe). The phone does not matter: the
app's 512 GB of address space is the limit (the guest window and the PA pool below
`0x7c00000000`, see [guest-va-exhaustion](2026-10-06-guest-va-exhaustion.md)). Extended Virtual
Addressing would lift it but is not available to a Personal Team.

## Not checked

The release variant, `pp ui` and `pp perf` (they need the Linux workstation's netmuxd), the
in-game menu and launch screen on the cover panel with a game running, and the notices stage
(its source download timed out); the Licences page of this build is empty.
