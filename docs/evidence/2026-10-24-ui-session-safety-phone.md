# UI session safety and deterministic routes, on the phone (PLA-440)

2026-10-24. Dev IPA
`.work/out/20261024-124310-5346e740/Playport-26.5-5346e740.ipa`,
sha256 `5346e7400d10e578bbb85df2fca6979a8422e04e28477052651c2d7fb037cc0c`,
89/89 verify checks, installed in place over the previous build (container kept,
never uninstalled). The IPA carries the owner's uncommitted
`app/Sources/S1Probe/UI/SettingsView.swift` edit, so it is not exact
committed-source provenance.

Host implementation and review: commits `e2a62de` and `4953fe4`; independent
review reports left in the build area. This record is what the phone itself
showed.

## What was driven

Every run was `pp ui` with explicit actions under the owner's UI-session rules:
announced start, no black screen, no pad scrolling, no game, no settings change,
and a final batch that leaves the Library up.

| Run | Actions | Result |
| --- | --- | --- |
| `.work/ui-runs/ui-verify-routes-20261024` | `open:app-367520#runtime`, `open:app-367520#graphicsoptions`, `--shot-each-action` | `ok actions=2` |
| `.work/ui-runs/ui-iso-title-20261024` | `open:app-367520` | `ok actions=1` |
| `.work/ui-runs/ui-iso-graphics-20261024` | `open:app-367520#graphics` | `ok actions=1` |
| `.work/ui-runs/ui-iso-runtime-20261024` | `open:app-367520#runtime` | `ok actions=1` |
| `.work/ui-runs/ui-verify-cancel-20261024` | six `open:` actions, `--leave-running`, host `SIGTERM` after 9 s | `exit 143`, `cancellation: pushed, confirmed false` |
| `.work/ui-runs/ui-verify-after-20261024` | `open:library` | `ok actions=1` |

## The two routes work

The two screenshots in the routes run show the Game options page with the
ringed row moved to the target and nothing else changed:

- `action-01-open_app-367520_runtime.png`: the **Runtime keys** row is ringed
  (`opt:runtime`); its subtitle still reads the per-game default, value `None`.
- `action-02-open_app-367520_graphicsoptions.png`: the **Graphics options** row
  is ringed (`opt:graphicsOptions`), value still `None`, with the page scrolled
  so that row is at the top.

Neither screenshot has a keyboard, a picker, or a changed value, which is the
read-only behaviour the route is meant to have. The previously reachable
`#graphics` section still works in the same build.

## Cancellation: requested, not app-confirmed

The interrupted batch was sent one cancel request and the host reported it as
`delivery: pushed`, `confirmed: false`, which is the designed ceiling. The
marker left in the run directory (`ui-cancel`) carries exactly that run's nonce,
so it cannot belong to another session. The host stopped with exit 143 and did
not push further input.

The app's own cancellation terminal outcome could not be read back from this
run: the host was signalled, so it never pulled the app log, and the next `pp ui`
launch starts a new process with a fresh log. The app-side latch itself is
covered by the host tests and was seen live once (below), but **the marker path
is not proven to have stopped the queue on the device**. Treat it as
requested-and-reported, not confirmed.

## An unexplained cancel, and its isolation

The first routing batch of the session
(`.work/ui-runs/ui-session-routes-20261024`) ended `cancelled: task cancelled`
after the Library loaded and before its first action logged anything. Nothing in
the sequence asked for it: no marker of that nonce existed, the foreground was
Playport, and the app reported no foreground loss.

Four later batches on the same build and IPA succeeded, including a repeat of
the exact same two-action batch with screenshots. So the failure did not
reproduce and is not attributable to the new routes; it is recorded here as an
unexplained single occurrence, not as a fixed or understood defect.

## Limits

- App-local gate only: the driver stops its own input when Playport is not
  active; nothing here shows where an input event would have landed, and a
  screenshot or `action ok` is not such proof.
- SIGKILL, transport loss and process death before the marker is read remain
  uncovered; the host reports `confirmed: false` for exactly that reason.
- A `--leave-running` exit without `ui-done` now cancels the remainder; scripts
  that relied on carrying a queue across processes must start a new session.
- `open:black` now ends a batch and exits 1 (a handoff, not success). Nothing was
  driven to the black screen in this session.
- No game was launched and no gameplay, performance or frame-pacing claim is
  made. The release variant was not built.
