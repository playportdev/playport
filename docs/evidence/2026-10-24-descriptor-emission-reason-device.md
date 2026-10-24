# Descriptor emission: missing-append branch observed, not fixed

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431). UI-session safety follow-up:
[PLA-440](https://linear.app/playportdev/issue/PLA-440).
**2026-10-24**, `dev/kk-proton-parity`. Exactly **ONE** separately authorized Hollow Knight
(`app-367520`) DXVK-on diagnostic play completed before the later UI-restoration interruption.
No second route, retry, save/game input, measurement or runtime fix. A0 remains blocked; A2 unstarted.

## Archive, capture and retained evidence

Exact verified dev IPA `.work/out/20261024-102128-aa32a361/Playport-26.5-aa32a361.ipa`, SHA256
`aa32a3616694ee28806ad4667833fb40af77993c06a5b79ee867860308b07a19`.
Includes the protected uncommitted owner UI edit: **not exact committed-source provenance**.
`pp install --no-build --ipa` explicitly selected that archive, upgraded in place/container kept,
exit0, `.work/install-runs/20261024-103556`; no build or uninstall.

One lock session covered install and play. Historical script (DO NOT resume/rerun):
`.work/agent-notes/kk-parity/emission-device-session.sh`; complete producer log
`emission-device-session.log`, install log `emission-device-install.log`, UI transcript
`emission-device-dxvk-on.jsonl` in that notes directory. Capture producer exit0, saved final
`event=result` oktrue/exit0, exact IPA, `until_reached=true`, **first-frame+10**.
JIT acquired in3.10s; first frame+12.07s. These are initialization marks, not performance evidence.
Vulkan/720p/60, arguments `-force-d3d11`, options exactly
`MESA_KK_DEBUG=descriptor_stats PLAYPORT_DESCRIPTOR_STATS=1`, HUDoff, normal counters,
CPU/pass profiling and GPU captureoff; no validation requested. Session-scoped, no keep-settings.
Only neutral `--pad`, no game/menu-button/save input. `--wait 120 --shot`, no later screenshots.

Run `.work/ui-runs/descriptor-emission-reason-dxvk-on-20261024` retains full events, argv,
timeline, raw log and `screen-stop.png`. The saved stop image is **black, not menu proof**.
No extended run to obtain menus. Product itself cleared80.8MB FEX cache under its10GB free-space
policy (raw21, reported8.60GB free); worker requested no cache deletion or policy change.
No warm/cold-equivalence or cache-benefit claim.

Full unmodified `pull/s1-host.log`: 2,859,194bytes/23,453lines; SHA256
`b763174f9c8e7d215424696ae3853eb36917cb8dff5562db9f84f42eafc16656`.
Both exact delivered markers, at **14705 and18583**:

```text
[kk-descriptor] emission failed stage=missing-append rowlen=454 mode=33188 flags=65541
```

## Observed failing branch

Actual reconstructed `.work/run/mesa/mesa/src/kosmickrisp/vulkan/kk_debug.c:384–507`:
formatting and fstat succeeded, regular-file branch selected, F_GETFL succeeded, but
`flags & O_APPEND` was zero. Mode33188 =0100644 (regular file); flags65541 =0x10005.
Actual Darwin target constants retained in
`.work/agent-notes/kk-parity/research/native-emission/target-macros.txt`:
S_IFMT0170000, S_IFREG0100000, F_GETFL3, **O_APPEND0x8**, not Linux0x400.
Thus the required append bit is absent at the query. No errno is emitted: this is a logical
predicate rejection, **not a failed syscall/errno diagnosis**. No pipe query occurred; no
banner-row write was attempted, so pipe_buf/written/attempts are unavailable, not zero.
rowlen454 is the successfully formatted first banner length, within the prior<=483 target
bound; type/mode and flags are initialized observations, not guesses. The permanent latch
then suppresses this device's later native reports; one best-effort poison reached the log.

**This identifies the failing branch, not why fd2 had those flags.** It does not identify
who opened/rebound/changed it, prove fd stability, or establish a stamping/cap explanation.
Prior Darwin ABI/import/banner audit found no concrete mismatch; no new fix, workaround,
sink bypass or broad source investigation performed. Native enabled banner/calibration/
10-row capture/work/errors remain **UNOBSERVED**, not zero. Poison intentionally invalidates
this source under the unchanged v1 strict consumer.

## Strict saved parse: rejected, not repaired

Both unchanged `tools/descriptorprof.py` CLI modes were run once on the complete new raw:
JSON and text **exit1**, insufficient, **0 usable intervals,20 rejected adjacent intervals,
21 rejected complete36-row DXVK captures,2 malformed poison records**. No filtering,
client-only subset, reconstruction or parser edits. Host-only resumption read these saved
outputs; it did not rerun the parser. Notes artifacts `emission-device-parser.{json,txt,rc}`
and both stderr files retain every rejection and raw calibration value.

| Stream | pid/module/device/init_ticks | Banner line | Captures / calibration |
| --- | --- | ---: | --- |
| DXVK D1 |100/4545842536/1/2924937050904|14707|21 complete36-row, all rejected;16 raw valid samples|
| DXVK D3 |100/4545842536/3/2924951370971|18584|0 captures/intervals, later work unknown;16 raw valid samples|
| Native KK |unavailable|none|no identity/calibration/capture|
| vkd3d |UNRUN|none|D3D12/Simple path unobserved|

D1 snapshot1 lines20095–20130 through snapshot21 lines23390–23425; all intermediate
identities/rows/reasons remain in JSON/text. Both client streams lack orderly tails, no
cross-device join. Actual QPC Hz10000000, all16 samples/stream valid, six reads/sample;
this is a tick unit, not demonstrated resolution or native calibration. Raw begin/end/flags
and derived adjacent/scope/empty ticks retained in `emission-device-saved-summary.txt`.
No CPU attribution, calibration subtraction, savings, perturbation, cross-layer parity or A2 claim.

JSON SHA256 `d59892da22394405c8f3433c4b84a1d5ef87692ecbfeba56c641df67be00ccc0`;
text `9de120d479036d86bf14b8871aa1f714536dc110a20d89e758cdd2b43c4dbe20`.
Original raw remains `f2668220bff3198b977d7f412ba6c17f99432ef35dbdc1fc7eef912f57947fac`;
previous retry raw remains `48d01f122d68c38b9307e258d7aa4f9acca5ce2686ba287833b91d6199c7f0c2`.
Old manifests/parser outputs unchanged; never reprocessed/overwritten by this capture.

## Restoration interruption and owner reclaim — no current black handoff

Saved supported UI restoration under `.work/ui-runs/descriptor-emission-reason-restore-*`:
- `options-20261024`: final resultok/exit0/exactIPA; timeline confirms capture-session undo.
  Saved image: default720p/60/Vulkan, launch argumentsNone. Developer section opens too high
  to inspect the lower options without more navigation.
- `diagnostics-20261024`: final resultok/exit0/exactIPA. Saved developer image shows GPU
  capture/CPU sampling/pass profiling/Metal validationoff, Runtime counterson(normal).
  `DeveloperSettings.swift:57–58` binds that switch to **!countersOff**; its subtitle must not
  be misread as the switch state. Graphics image shows HUDoff. An earlier black image was
  saved, **but more input followed, so it was not a final handoff**.
- `confirm-20261024`: queued after that black screen, with generic tenDown pad scrolling.
  Saved lower-options image shows own Runtime keysNone and Graphics optionsNone; compatibility
  subtitle is separate from the own-value field. Last `open:black` action was reportedok,
  **but its saved screenshot shows another foreground app, not black**. No final result or
  completed producer exit exists for this confirmation run. Do not infer final state from
  the action label, screenshot filename, earlier black or the undo record.

The owner reported input in another app. This report accepts that incident; it does not
independently establish the recipient of each input. The black-interlude-then-input sequence
and improvised scrolling were unsafe. Owner reclaim stopped the producer; queued restoration
was aborted. Supervisor subsequently verified the host lock free. **No active worker UI
session, no resumed old script and no device commands after host-only resumption.** No new
phone/status/foreground/screenshot/cleanup check was performed. Final settings/screen/current
power/free-space are unconfirmed, even where earlier saved controls are known.

Only pre-capture readiness status:58%, notcharging/noexternalpower,5.0GB free,
unattendednull. These are historical, not current readiness. Unattended never changed.
No JIT/VPN retry or owner game auto-launch. No final explicit-black handoff claim.

## Narrow PLA-440 recommendation — not implemented or authorized here

Existing `open:app-367520#developer` routes via `Dev/UIDriver.swift:343–370`
(`AppNavigation.pageSection`) and `UI/GameDetailView.swift:246–257,639–681` to the first
ordering row, not Runtime keys/Graphics options. Missing deterministic **read-only** targets:
propose `open:app-367520#runtime` -> existing `opt:runtime`, and
`open:app-367520#graphicsoptions` -> existing `opt:graphicsOptions`.
The two rows already exist at GameDetailView1049/1060; extend `firstRow(ofSection:)` and
reuse existing focus.ring/proxy.scrollTo(.top), without activating a keyboard or changing values.
Current `tools/ui.py:413–419` already accepts lowercase title-section names, so no new input
transport/grammar needed; update help/UIDriver route documentation. Unknown target should
fail explicitly rather than silently show the top of the options.

Tests for the next owned host chunk: `tools/tests/test_ui.py` parse/dry-run tests for both
exact paths, no pad actions; a small host-testable target mapping with source-named Swift
tests (existing PlayportKit/AppRoutesTests pattern), covering exact row IDs, old sections,
unknown targets and no mutation. Any actual scroll rendering still needs a separately
announced, focused UI batch after host preparation; this is not phone authorization.
No protected `UI/SettingsView.swift` edit is needed for these per-game targets. Any global
Settings target requiring that protected owner file needs separate explicit approval.

Foreground containment is missing in the inspected generic route: UIDriver372–397 loops
PadRouter.send without active-state checks; PadRouter.swift:63–66 checks only handedOff and
publishes an app-local Combine event, not an observed OS-wide key injection. UIDriver1015–1022
step wait also lacks cancellation/foreground checking; tools/ui.py771–784 screenshots and
acks the step without verifying the foreground recipient. AppShell157–169 observes phase
changes but does not cancel this driver. This does **not** prove the mechanism of the owner's
reported cross-app input. It does show that actionok/screenshot filenames cannot prove
foreground containment. Recommend active-state/cancellation checks before each action,
each pad press and after step wait, terminal queue cancellation on leaving foreground,
no automatic relaunch/resume, and host tests for no subsequent press/ack after inactive,
owner stop or failed foreground confirmation. Scope/implementation belongs to PLA-440.

## Preservation, checks and next review

Protected owner file remains byte-identical to snapshot, SHA256
`14f47ed236724bf1250e2d7447f4fa9f16f4c93eb305c5fe5f8ee4d863b3a3fe`;
its diff SHA256 `3e371c630d659be316befde9e60824ae0a4be12f44a52084d1595740532ea7b9`.
No source/test/parser/runtime/build-record changes, build, branch switch, merge/push or
blanket staging. Only this evidence and own Runner/README entry updated. Focused names,
secrets, document links, diff/staged-path and evidence/owner hash checks pass; no new tests
or quick-suite run needed for documentation-only changes. Independent checkpoint review
required. Supervisor owns PLA-431/PLA-440 and Compatibility filing: Hollow Knight only,
initialization result/black screenshot, not new menu/gameplay status. No further play or fix
authorized. Next is host-only deterministic-route/safety preparation and supervisor review,
not resuming old scripts or human measurement.
