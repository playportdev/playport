# DXVK descriptor sibling clocks — host correction

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431).
**Plan:** [Proton parity](../plans/finished.md#kosmickrisp-proton-parity), A0 item 2.
Follow-up DXVK **0007**, `Class: diagnostics`; independent re-review pending.
[Original probe evidence](2026-10-23-dxvk-descriptor-cost-probe-host.md) describes
coverage and earlier gates; it is not acceptance of the clock bug below.

## Failure and correction

Independent review blocked 0006: child starts were checked against parent starts,
not previous sibling ends, and each successful child overwrote `lastChildEnd`.
The real production-helper fixture now includes both deterministic traces:

- Initialization 1; prep 10; child 150..200; sibling 30..40; prep ends 100;
  capture 1000..1000. Before the fix: parent `timed_calls=1`, `exclusive_ticks=30`,
  parent and second-child `clock_errors=nest_errors=0` despite invalid ordering and
  the first child's end lying outside the parent.
- Initialization 1; prep 10; child 20..50; sibling 40..60; prep ends 100;
  capture 1000..1000. Before: parent `timed_calls=1`, `exclusive_ticks=40`, same
  missing errors despite overlapping siblings.

Added these tests **before** the source fix; the fixture printed both bad outcomes
and failed its explicit-error assertion (producer exit 134). No copied timing formulas.
0007 rejects a child start strictly earlier than `parent->lastChildEnd`, using the
existing nesting-error/invalidation path. The recorded child end only increases;
final containment and summed-child checks remain. Invalidity propagates to ancestors
as scopes unwind. This changes only the enabled out-of-line diagnostic helper:
no header/layout, callsite, feature/default, pin, or disabled guard change.
Source commit before reconstruction: `78e7eba1f3df0dc423e64e9930961a6a07fb4b7b`;
format-patch exported to the absolute repository patch directory before the build.
Build reconstructed commit `18fa8a6` with tree
`ae8cc1d5b0671c2b8e3c2f6cc070b1c4b4058334`, identical to that source commit
(`git diff 78e7eba HEAD` empty and tracked worktree clean). Only the helper `.cpp`
differs from 0006.

After the fix, both traces have parent and rejected second child
`clock_errors=1`, `nest_errors=1`, `timed_calls=0`, `exclusive_ticks=0`.
Already-completed first-child local timings are not retroactively removed; consumers
must reject explicit operation errors, not assume every row in a snapshot is valid.
Capture itself can still have `clock_ok=1`, `quiescent=1`, `overflow=0`.

The fixture also checks both traces one ancestor deeper, failed child start/end and
backwards child end: each affected child/parent/root has `clock_errors=1`,
`timed_calls=exclusive_ticks=0`. A subsequent independent prep scope records one valid
100-tick exclusive without losing the prior error. Equal sibling end/start,
nonoverlapping siblings, and all-equal timestamps each retain one timed call per scope,
zero clock/nesting errors, and parent exclusives 70, 70 and 0 respectively.

## Validation

Environment: `PLAYPORT_BUILD=$PWD/.work`,
`TMPDIR=$PLAYPORT_BUILD/agent-notes/kk-parity/tmp`. Focused helper producers bounded
at 60 seconds (fixture executable at 30 seconds); long checks use bounded foreground
producers with saved logs and checked exit status.

- Real-helper fixture after correction: exit 0, including existing nesting, exclusion,
  depth-32 overflow, mixed-device, exception, thread/device isolation, saturation,
  disabled and logging/calibration checks.
- Same fixture, `-fsanitize=address,undefined`, leak detection and UBSan halt-on-error:
  exit 0. No warnings suppressed (`-Wall -Wextra -Werror`).
- Optimized host guard spot check: null stats branches directly to the operation and
  returns, bypassing `begin`/`end`, TLS, clocks and counters. Helper header/layout is
  unchanged. Disassembly equals the saved pre-fix host assembly except its object
  filename header. Earlier ARM64EC context/pool/wrapper inspection is inherited,
  not rerun.
- Post-build reconstructed real-helper fixture: exit 0, same rejection fields and
  all assertions pass.
- `./pp build`: exit 0; dev IPA **89 checks passed, 0 failed**. Exactly six hashes
  changed in `app/artifacts.tsv`: `d3d9.dll`, `d3d11.dll`, `dxgi.dll` in each of
  `arm64ec-windows` and `i386-windows`; sizes unchanged. DXVK `d3d8`/`d3d10core`,
  vkd3d DLLs and generated Wine PE manifests unchanged.
- `./pp test --quick`: exit 0, **712 Python tests and 26 C groups passed**;
  patch-series/trailer checks pass. Existing Python unclosed-file ResourceWarnings
  remain visible in the log; none suppressed. Swift tests intentionally omitted.
- `./pp names`, `./pp secrets`: exit 0, clean. Owned source/docs whitespace checks
  pass. Owner file and private diff compare byte-for-byte equal to saved snapshots.

Verified dev IPA:
`$PLAYPORT_BUILD/out/20261023-111151-a1e362fa/Playport-26.5-a1e362fa.ipa`.
SHA256 **`a1e362fa55e591411cb402d14e77dd79d0be481479934a6ac3b922f1e23d3b68`**
(recomputed after build). This is **not exact committed-source provenance**: built
from base `56162e0` plus this correction and the owner's protected, uncommitted
`SettingsView.swift` edit. Owner file SHA256
`14f47ed236724bf1250e2d7447f4fa9f16f4c93eb305c5fe5f8ee4d863b3a3fe`;
diff SHA256 `3e371c630d659be316befde9e60824ae0a4be12f44a52084d1595740532ea7b9`.
That edit remains unchanged, unstaged and uncommitted; no app source was changed
by this correction.
No Vulkan execution, phone calibration/smoke/gameplay, Mesa suite rerun, release build
or Swift package tests were performed for this C++-only correction. Earlier Mesa
and production disabled-path results remain dated evidence, not rerun claims.
A2 stays gated. Independent focused re-review is required before this helper is used
as the reference for a separately authorized next client; none was started.

Private logs under `$PLAYPORT_BUILD/agent-notes/kk-parity/`:
`a0-dxvk-clock-before.log`, `a0-dxvk-clock-helper.log`,
`a0-dxvk-clock-sanitized.log`, `a0-dxvk-clock-reconstructed.log`,
`a0-dxvk-clock-{build,quick,names,secrets}.log`. The IPA's `logs/verify.log` retains
all 89 checks; `provenance.txt` explicitly records local changes.
