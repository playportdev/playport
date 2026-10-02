# Three-step first-run setup, with a completion overlay

Removed Controller from the checklist: pairing, LocalDevVPN and Steam are
numbered 1–3. Steps can be visited in any order, but the first run cannot leave
until pairing and VPN are ready and Steam is signed in or explicitly put off
with X / the tappable Not now footer entry. A pending first run is remembered
across app restarts, even after pairing has been stored; existing paired phones
keep their setup. Later visits from Settings can always leave.

Once settled, the steps remain visible but dimmed behind **You're all set**.
The highlighted **Continue** button (tap or A) leaves setup; B closes only the
overlay, without immediately showing it again. B on the settled steps leaves.
Steam's Not now does not claim a signed-in session or disable later sign-in.
The iOS 27 pairing action still uses `JitSetup.begin`; the iOS 26 Files fallback
is unchanged.

## Checks

- `./pp test`: passed, including checklist completion, optional Steam,
  unfinished setup resuming after pairing, and existing routing tests.
- `./pp check`: dev app compiled.
- `./pp install`: upgraded in place; 71 IPA checks passed.
- Installed dev IPA SHA256:
  `6087cccb9ee3564cfe656c0a495de6e8c0f9bc0268fcbaffff627e24e3b97df9`.
- `./pp build --variant release`: compiled; 75 IPA checks passed. Release IPA
  SHA256: `3f2d2581d338fabc942fb8b59e3ffac7852fba42b7f02402e474c912421ad689`.

## Phone

The dev UI's existing Preview a first run now simulates completion with A.
It uses the same gate and overlay without changing real pairing, VPN or Steam.
Both runs below used `--shot-each-action` on iOS 27; screenshots stay in `.work`.

- `.work/ui-runs/20261002T143916`: `ok actions=12`. B stayed on the unfinished
  preview; RB reached Steam before pairing/VPN were done. X put Steam off but
  B still could not leave. Completing pairing and VPN showed the dimmed
  checklist and centered completion panel with amber A Continue. B closed
  only the panel; the next B returned to Settings with preview-row focus.
- `.work/ui-runs/20261002T145114`: `ok actions=9`. A later, real checklist visit
  could leave with B. In a new preview, B was blocked until the simulated
  pairing, VPN and Steam steps completed. The overlay appeared on the last
  step; A returned to Settings with preview-row focus and real facts restored.

This checks the UI with simulated first-run facts, not new pairing or Steam
credentials on a fresh phone. Neither a real pairing/import nor a real Steam
sign-in was performed. Physical tapping was not exercised; Continue and the
footer entries are SwiftUI Buttons sharing the controller actions. Restart
persistence and the iOS 26 branch were checked by host tests, not a fresh-device
run. No title was launched or installed.
