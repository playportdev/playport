# UI session safety: host implementation, not phone verification

**Linear:** [PLA-440](https://linear.app/playportdev/issue/PLA-440).
**Status:** HOST IMPLEMENTED / independent review PENDING / not phone verified.
2026-10-24, `dev/kk-proton-parity`, starting source `6d576a3`; parent documentation
checkpoints `b553886`/`5c33866` preserved. One workstation-only chunk. No phone, UI, status,
install, perf, gameplay, save, controller or cache operation was performed. No games observed.

## Production delta

- `open:app-367520#runtime` selects existing `opt:runtime` (Runtime keys), and
  `open:app-367520#graphicsoptions` selects existing `opt:graphicsOptions` (Graphics options).
  Dev-only `UIDriverGameSection` is used by both UIDriver validation and GameDetailView's
  `firstRow(ofSection:)`; the existing `focus.ring` and `scrollTo(..., anchor: .top)` do the
  selection. No row activation, keyboard, option mutation or default/navigation change.
  Existing graphics/controls/game/files/developer/ordering/steam/gyro/controller routes,
  generic title/store IDs, Settings aliases and licence component routes remain supported.
  Unknown game sections fail before navigation in both host parsing and app dispatch.
- Dev-only `UIDriverBatch` owns actual action iteration, individual pad/menu press loops,
  wait checkpoints and step acknowledgement waits. The batch waits up to 90 seconds for
  initial active/library/opening readiness; initial inactive is not itself cancellation.
  Once active is observed, any inactive/background transition permanently cancels it.
  Actions/individual presses and both sides of awaits check active state, Task cancellation
  and the current nonce's host-cancel marker. Long driver waits check at 100 ms slices.
  Existing step wait's 90-second expiry now fails instead of silently continuing.
  Neither readiness nor step timeouts are a new UI-session/gameplay duration cap.
- The root in `PlayportApp` forwards scene changes: AppShell disappears during gameplay,
  so its old observer alone would miss that case. AppShell seeds initial phase on startup.
  Cancellation clears remaining actions/continuation, cancels the driver Task, emits one
  failed `ui-done`, releases only driver-held menu Home/touches and stops its gyro script.
  Dev-only tap/web helpers check cancellation; deferred game-section navigation also gates
  itself after its await. No physical controller routing or gameplay/pad-mode policy changed.
  Planned process replacement stops local iteration but keeps lifecycle/host-cancel checks
  armed until termination; an observed loss also drops the saved DriverContinuation, even
  if reactivated. A normal replacement reporting inactive may therefore drop subsequent
  DRIVER actions, with a cancelled outcome, rather than resume unsafely. Restart failure
  also cancels/drops them. Product AppRestart/game/prerequisite code is unchanged.
- Host SIGTERM/SIGHUP/Ctrl-C requests cancellation even with `--leave-running`: one bounded
  10-second push of `ui-cancel-<captured nonce>` containing that nonce, through the existing
  control transport. Only the current eight-hex nonce and matching content are accepted.
  No daemon, persistent session manager, lease, retry/relaunch or settings write. Non-leave
  retains its existing app-kill behavior; leave-running does not kill gameplay merely to
  stop UI input. Delivery failure is reported, and even a successful push is explicitly
  **unconfirmed**, not a claim the app consumed it. Stale nonce markers cannot cancel a new
  session. Step markers now include the captured nonce too, excluding old-session acks.
- Before screenshot/step ack, the host checks for an already reported batch failure, and
  checks again after screenshot. It skips failed/cancelled steps rather than acknowledging
  them. App-local cancellation remains authoritative even if a late marker races it.
- Deliberate diagnostic contract change approved by the supervisor: `background:S` grammar
  remains, but a Settings handoff terminally cancels this batch; **no automatic return**.
  The two other driver actions that leave Playport are the same handoff: `jit:open-settings`
  cancels after opening Settings for the pairing code, and an opened `probe:settings-url-N`
  cancels as a handoff (a link that did not open still fails the action). Neither emits
  success nor continues the queue. Normal in-app JIT/Settings capability is unchanged;
  returning requires a NEW explicitly announced session, not the interrupted batch.
  Canonical `pp ui` help and UIDriver documentation explain this.

## RED / GREEN and actual host coverage

Logs under `.work/agent-notes/kk-parity/`:

| Check | Result |
| --- | --- |
| `ui-safety-red.log` | RED: old host accepted unknown game sections; original section mapping, extracted unchanged into the dev seam, had no graphicsoptions target. Initial unguarded queue also hung its readiness test; deterministic RED rerun below avoids a real wait. |
| `ui-safety-queue-red.log` | RED against the wired, unguarded queue extraction preserving old behavior: later actions/acks/presses continued after loss/cancel, reactivation resumed, missing step ack silently passed. Exact unguarded helper retained in notes `tmp/UIDriverBatch.unguarded.swift`; this is not a claim UIKit ran on Linux. |
| `ui-safety-handoff-red.log` | RED: actual old host background helper attempted an automatic wait (clock mocked in retained rerun). |
| `ui-safety-restart-handoff-red.log` | RED against the predecision disarmed-restart behavior (`handoff` ending the gate): saved continuations survived observed inactive/host cancellation. The replacement harness compiles actual DriverContinuation save/drop code, not a duplicate implementation. |
| `ui-safety-handoff-settings-red.log` | RED, source diff (not executed: iOS only): pre-change `jit:open-settings` and `probe:settings-url-N` fell through to the next queued action after leaving Playport, and the old help text stated no terminal handoff. GREEN lines from the working tree cancel both as handoffs. |
| `ui-safety-ack-red.log` | RED: actual host event callback screenshot and pushed an ack despite observed cancellation. |
| `ui-safety-focused.log` | GREEN: 53 tests — `tools/tests/test_ui.py` (51) and the actual Swift queue/continuation seam `tools/tests/test_ui_driver_batch.py` (2). |
| `ui-safety-playportkit.log` | GREEN: `swift test --package-path app/PlayportKit`, 364 tests. Existing AppRoutes tests retained. |
| `ui-safety-quick.log` | GREEN: `./pp test --quick`, 753 Python tests and 26 host C groups; names/secrets/patch-series clean. |
| `ui-safety-release-parse.log` | GREEN: empty output, exit 0 — Swift frontend parse with `-D PLAYPORT_RELEASE` for the touched non-Dev Swift files. Syntax/guard inspection, NOT a release build or executable verification. |
| `ui-safety-build.log` | GREEN: `./pp build`, dev IPA `071ef6b0…` verified 89/89 from the final source. Dependency/staging/notices stamps unchanged; app/verify ran. |

`tools/tests/test_ui_driver_batch.py` compiles the production dev-only Swift files directly
with the existing host Swift-compiler test pattern, using `fixtures/UIDriverBatchTests.swift`.
Virtual active state, monotonic clock and sleep drive actual queue methods: initial readiness,
readiness loss/timeout, loss before action/before step/during wait/mid-pad loop, reactivation,
Task/host cancellation, missing ack, no next action/success ack after cancellation, normal
active completion, exact target rows, old sections and unknown targets. Replacement-window
cases exercise actual DriverContinuation save/drop: save-then-inactive, save-then-host-cancel,
no revival, no later action/press/ack, and ordinary handoff without observed loss. Only its
filesystem/log dependencies are stubbed. Product AppRestart is unchanged, not run on Linux.
Python tests exercise
actual parse/dry-run and host producer callbacks: no mutation actions, cancellation as a failed
result even with play last, no observed-cancel ack, normal nonce-bound ack, interrupted producer
SIGTERM/Ctrl-C in both leave modes, failed delivery, and captured-nonce/bounded transport.

Explicit wiring inspection followed UIDriver's actual `batch.run`/`presses`/`pause`/`step`,
root lifecycle call, initial AppShell call, GameDetailView mapping/ring/scroll, the
`background:S`/`jit:open-settings`/`probe:settings-url-N` handoff cancels, host event
callback and interruption context. New driver logic stays in Dev/ or `!PLAYPORT_RELEASE`;
existing verifier's UIDriver type exclusion also covers UIDriverBatch/UIDriverGameSection.
No release archive was built. UIKit scroll/rendering, lifecycle notification timing,
Touch/HostIO/gyro cleanup, the three handoff cancels and real cancellation transport were
**not executed on iOS**.

## Archive, preservation and limits

Verified dev IPA `.work/out/20261024-122059-071ef6b0/Playport-26.5-071ef6b0.ipa`, SHA256
`071ef6b03f3a44de1ae63d51af73eda030b4a950939a146d85c1ae4109277af3`, built from the final source
of this chunk and verified 89/89.
It includes the protected owner UI edit, uncommitted: **not exact committed-source provenance**.
No build-record rows changed (`app/artifacts.tsv`, `build/generated/wine-pe-*.tsv` unchanged).
No native Mesa/Wine/descriptor/parser/pin/upstream changes; the native append-flag cause is
still unknown. Previous [incident evidence](2026-10-24-descriptor-emission-reason-device.md)
is not revised by this host implementation. A0/A2 gates remain unchanged.

Owner SettingsView remains byte-identical/unstaged: file SHA256
`14f47ed236724bf1250e2d7447f4fa9f16f4c93eb305c5fe5f8ee4d863b3a3fe`, diff SHA256
`3e371c630d659be316befde9e60824ae0a4be12f44a52084d1595740532ea7b9`;
both compare exactly with the supplied owner snapshots. Main remains `26699f6`.

This fixes the inspected **app-local batch gate**, not an independently proven mechanism of
the owner's reported cross-app input. No OS frontmost-recipient guarantee: actionok and
whole-device screenshots cannot prove it. A screenshot or host marker push may race a
foreground change; the app must reject later actions regardless. In-flight product operations
already submitted are not retroactively undone. Lost transport, abrupt SIGKILL or suspension
can leave host-request cancellation delivery/consumption uncertain; no heartbeat daemon is
claimed. Process death before an observable loss/marker consumption is an unobserved handoff
gap, not guaranteed cross-process containment. Pending iOS gates and independent review
prevent any phone-verified safety claim.

Next: independent review. Only if separately approved, prepare and announce one short focused
UI-only batch showing both exact target rows and cancellation proof; finish/cancel every queued
input before releasing the session. No old restore script, black interlude followed by input,
improvised taps/pad scrolling or automatic relaunch. This evidence grants no device authority.
