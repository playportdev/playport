# The Witcher 3's current 4.x build needs an AVX128 path in the iOS FEX host

**Linear:** [PLA-451](https://linear.app/playportdev/issue/PLA-451). Related:
[PLA-43](https://linear.app/playportdev/issue/PLA-43) (the title),
[PLA-444](https://linear.app/playportdev/issue/PLA-444) (the sweep that hit it),
[PLA-450](https://linear.app/playportdev/issue/PLA-450) (branch selection),
[PLA-269](https://linear.app/playportdev/issue/PLA-269) (cohort FEX features),
[PLA-81](https://linear.app/playportdev/issue/PLA-81) (the Witcher 3 DX12 candidate waits on this).

**Status:** **stopped 2026-10-27** and handed to the owner for review. Chunks 1,
1b, 2a, 2b and 3 landed on the branch; chunks 4–6 did not run. The owner's
decision: leave `dev/pla-451-fex-ios-host-avx` unmerged for review.
**Branch:** `dev/pla-451-fex-ios-host-avx`, from `main` at `5317c13`, **not
pushed, not merged**. HEAD `3670c47`.

## Runner state (2026-10-27, stopped)

**The AVX128 gap is closed and gated; it is necessary but not sufficient for The
Witcher 3.** Its installed 4.x build now decodes and executes the AVX instruction
that used to kill it, reaches its own memory initialiser, and dies in its own
out-of-memory handler because it needs a 64 GiB contiguous reservation that this
phone cannot serve (PLA-452 — Linux VA ceiling, not RAM, not FEX).

**What landed** (each with `pp test` + `pp build` where a build was involved):

| Chunk | Commit | What |
|---|---|---|
| 1 | `7c93589` | `patches/fex-port/0064`: the iOS host's hand-built `HostFeatures` sets `SupportsAVX` — that branch returns before `OverrideFeatures`, which is why `enableavx` could never reach it. |
| 1b | `a7f48f2` | `0064` narrowed to `SupportsAVX = HostType != HostTypeEnum::Wow64`: the FEX_IOS_HOST branch compiles into both modules and upstream keeps AVX off for WOW64. No i386 title gains a code path. |
| 2a | `28a323c` | `patches/fex/0082` (`Class: diagnostics`): startup prints `FEX: iOS host AVX=`, the ml538 sentence becomes `rev=ml538b`. Belongs in `patches/fex`, not `fex-port` (the line is created by `patches/fex/0005`/`0008`/`0023`, and `0034` owns the neighbouring block). |
| 2b | `48c26f1` | Phone on IPA `097bb2cc`; `docs/evidence/2026-10-27-witcher3-avx.md`. Hollow Knight first frame +11.80 s (the runtime smoke gate); The Witcher 3 past the `vmovaps`, dead at 1480 ms in its OOM handler. |
| 3 | `3670c47` | `build/ymm-context/test.py` (`pp test`: `C test ymm context`) compiles FEX's and Wine's own context code from the run trees and round-trips known ymm bytes. Verdict: the copy conditions are right, the high halves never travel through a context; two gaps filed (PLA-453, PLA-454). Report `.work/agent-notes/witcher3-avx/reports/chunk3.md`. |

**Not landed — the open queue, in the order it should resume.** Each item is one
writer child; the numbers continue this plan's chunk list below.

1. **Chunk 4 — per-title FEX features (PLA-269).** AVX is global today. Let a
   cohort entry carry FEX features so only titles that need AVX get it, and give
   The Witcher 3 its compatibility default only if 4.x ever boots. This is now the
   most valuable remaining item: the AVX change's blast radius is every x86-64
   title until it lands. PLA-451, PLA-269.
2. **Chunk 5 — measure what AVX costs.** `pp perf` on Hollow Knight with AVX on
   and off (the runtime marker names the state), plus PLA-454's flush-cost
   question once that issue is worked. Decide whether AVX stays default-on.
3. **Chunk 6 — the play gates.** Hollow Knight's own frame times and the
   compatibility ledger must stay clean for the AVX change to be called verified;
   The Witcher 3's gates are blocked on PLA-452/PLA-450 and cannot be met by AVX
   work alone.

**Open Linear from this plan:** [PLA-452](https://linear.app/playportdev/issue/PLA-452)
(the Witcher 3's 64 GiB reservation and its OOM handler; the analysis and the
static classification are both recorded there, next steps ranked),
[PLA-453](https://linear.app/playportdev/issue/PLA-453) (Wine: no XSTATE reaches an
x64 guest), [PLA-454](https://linear.app/playportdev/issue/PLA-454) (FEX: a
high-half write can sit in the register cache past a guest fault),
[PLA-450](https://linear.app/playportdev/issue/PLA-450) (branch selection, the only
route to the classic 1.32 art this title's Best known names), and
[PLA-269](https://linear.app/playportdev/issue/PLA-269) (cohort FEX features).

**Reports and scratch** (not in the branch, by design):
`.work/agent-notes/witcher3-avx/reports/{chunk1,chunk2a,chunk3}.md`, the build and
test logs beside them, and `.work/agent-notes/pla-452/{report,static-report}.md`
with the pulled `witcher3.exe` in `.work/agent-notes/pla-452/pull/`.

**Phone state (2026-10-27 17:4x, `pp phone status`):** installed dev IPA
`097bb2cc` (`097bb2ccb5626a108524ad3a9861d84f15f21edc4489645c49032d1057bf4831`),
recorded against checkout `833a172`, iPhone18,4 iOS 27.0.1, profile expires
2026-11-03 15:47, battery ~77% unplugged, free space 14.3 GB, no lock held, no app
running, unattended mode off. The Witcher 3 4.x payload (68.8 GB) is installed;
the classic 1.32 branch is not. A 0-byte `oom_report_*.json` sits in
`Documents/prefix/drive_c/Games/The Witcher 3/bin/x64_dx12/` from the run.


## What the phone runs proved (2026-10-27, IPA `0107f809`)

The phone runs the dev IPA `Playport-26.5-0107f809` (sha256
`0107f8096ec1f1234e1cfa8812850c1faa198b34ffad2828b30b4f070ac3a38a`), iPhone18,4, iOS 27.0.1.
The installed payload is Steam `app-292030` build `25773555`, executable
`bin\x64_dx12\witcher3.exe` (4.x Remastered, about 68.8 GB); its container has no
`bin\x64` folder at all.

Four runs, all ending the same way about 1 s after the game starts:

| Run | Settings | Outcome |
| --- | --- | --- |
| `.work/ui-runs/regression-2026-10-27/27-witcher-3-play`, `…/27-witcher-3-play2` | page defaults | `done nonce=… exit=0xc000001d after_s=1` |
| `.work/ui-runs/avx-2026-10-27/witcher-3-enableavx` | Runtime keys `env.FEX_HOSTFEATURES=enableavx,disableafp` | same `exit=0xc000001d after_s=1` |

Everything Playport owns was healthy at the fault: `jit: acquire(896 MiB) -> 0 after 3.10 s`,
pool `size_mb=896 … exhausted=none`, band `size_mb=16384 used_mb=459 refused=0`, limits
`wx_dropped=0 x18_images=0 x18_sites=0 split_lock=0`, no iOS crash report, no backend failure.

The fault is a guest instruction. FEX's Windows frontend logs
`Invalid instruction in entry block`, and the patched instruction dump names it:
`[generated-fault-window] module=witcher3.exe rva=0x27e8fef at=c5f829742450…`, i.e.
`vmovaps [rsp+0x50], xmm6` — a VEX-encoded AVX128 store in the game's first prologue. The
SSE fallback code path is therefore never reached.

The `enableavx` experiment proves the switch cannot help: the launch did carry it
(`host-cpu: …; fex: FEX_HOSTFEATURES enableavx,disableafp,enablelrcpc2`) and the ml538
marker for the game process moved from the shipped `HostFeatures=288` to `292`, yet the same
VEX store still decoded invalid.

## The gap in the tree

| Fact | Where |
| --- | --- |
| The decoder takes the VEX tables only when `SupportsAVX`: `VEXTableOps` with `SupportsSVE256`, else `VEXTableOps_AVX128`; with AVX off the VEX group is the invalid table, so a VEX opcode at block entry is `INVALID_INST` | `FEXCore/Source/Interface/Core/Frontend.cpp:82` |
| The AVX128 dispatch FEX already has for this instruction: `AVX128_VMOVAPS`, and the rest of the AVX128 table | `FEXCore/Source/Interface/Core/X86Tables/VEXTables.cpp:20` |
| The iOS host hand-builds its baseline `HostFeatures` (AES, CRC, atomics, RCPC, SHA, PMULL, FCMA, FlagM/M2, AFP) and **returns** there, so the common path never reaches `OverrideFeatures()`, which is where `HOSTFEATURES`/`enableavx` would set `SupportsAVX` | `Source/Windows/Common/CPUFeatures.cpp` under `FEX_IOS_HOST`; `Source/Common/HostFeatures.cpp:742` |
| That hand-built list is the shipped state: `SupportsAVX = false`, recorded in `patches/fex-port/0009` ("SVE is left off because Wine arm64ec doesn't have SVE context save/restore yet") | `patches/fex-port/0009` |
| The 256-bit state is gated the same way: `ReconstructXMMRegisters`/`SetXMMRegistersFromState` copy the high halves only `if (YMM_High != nullptr && HostFeatures.SupportsAVX)` | `Interface/Core/Core.cpp:365`, `:389` |
| The ARM64EC context already passes the high halves: `ReconstructXMMRegisters(Thread, &ECContext.V[0], &ECContext.V[16])`; the host→guest direction passes `nullptr` unless the request carries `CONTEXT_XSTATE` with `XSTATE_AVX` | `Source/Windows/ARM64EC/Module.cpp:620`, `:549`/`:552` |
| Upstream's own AVX attempt was reverted: with `disableavx` shipped, the Chromium corruption was unchanged, and the wider vector mode was slower for the webhelper spawn (t+11.2 s vs t+15.5 s) | `FEXCore/Source/Interface/Config/Config.json.in` ml538 note |
| PLA-132's host-CPU switches only disable absent ARM features, they never add AVX | that record, `33162cf` |

So the missing capability is one flag on the iOS host plus the state and honesty around it —
the decode tables and their `AVX128_*` handlers are already in the tree.

## Chunks

One writer at a time, each chunk built, committed and used on the phone before the next starts.

1. ~~**Give the iOS host AVX128**~~ ✅ `7c93589`, narrowed to the ARM64EC host by
   `a7f48f2` (chunk 1b): `patches/fex-port/0064` sets `SupportsAVX` in the
   `FEX_IOS_HOST` branch of `Source/Windows/Common/CPUFeatures.cpp`.
2. ~~**Make the marker honest and the gate decisive**~~ ✅ `28a323c`
   (`patches/fex/0082`) and `48c26f1` (the phone): the VEX store decoded, and the
   next faulting guest RIP was named — which turned out not to be AVX at all.
3. ~~**256-bit state correctness**~~ ✅ `3670c47`: the copy conditions are right and
   the high halves never travel through a context; the two real gaps are PLA-453 and
   PLA-454. Residual risk stays as that report states it.
4. **Make it per-title, not global (PLA-269)** — *open, next.* Let the cohort entry
   carry FEX features, so only titles that need AVX get it; and give Witcher 3 its
   compatibility default in `app/PlayportKit/Titles/compat-defaults.json` only if 4.x
   ever boots. Until this lands the AVX change is global to every x86-64 title.
5. **Measure what AVX costs** — *open.* `pp perf` on a vector-heavy title with AVX on
   and off (ml538 measured the webhelper spawn only). Hollow Knight's own frame times
   answer whether AVX128 taxes the shipped games, and PLA-454's flush would be measured
   the same way.
6. **Witcher 3 play gates** — *blocked, not by AVX.* The 4.x build needs a 64 GiB
   contiguous guest reservation this phone cannot serve (PLA-452), so its first frame
   cannot come from this plan's work; the classic 1.32 build that PLA-43's Best known
   names is unreachable through the UI (PLA-450).

## Exit criteria

The plan is done when Witcher 3's installed 4.x build reaches a first frame and a human play
shows gameplay, AVX is recorded in the runtime marker, its cost is measured on a shipped
title, and titles that do not need it are unchanged (Hollow Knight and the compatibility
ledger still pass).

**Rewritten 2026-10-27 after the evidence: the first clause cannot be met by AVX work.**
The 4.x build reaches its own `red::memory` initialiser and dies in its own OOM handler on a
64 GiB reservation the phone cannot serve (PLA-452). So this plan's own goal is now: **AVX128
lands and is honest** (marker says which way it shipped — done), **its blast radius is
contained** (chunk 4, per-title, open), **its cost is measured on a shipped title** (chunk 5,
open), and **nothing that did not need it changed** (Hollow Knight's first frame and the
compatibility ledger — partially shown: one HK boot on `097bb2cc`; the measurement is chunk
5). The Witcher 3's own gates move to PLA-452 and PLA-450.

## Risks, open questions and what this does not cover

- **AVX is not Witcher-only.** Turning it on changes every title's vector routines — Skia in
  the Steam overlay/webhelper, DXVK/DXMT's own code paths, games' SSE-vs-AVX choices. Chunks
  4 and 5 exist because nobody has measured that; until they run, the change is not
  "verified", it is an experiment.
- **Silent corruption.** An AVX block that decodes but loses the upper halves of a register
  looks like a wrong image, not a fault. Chunk 3 must pass before any title's status moves.
- **Correctness gap already accepted** (ml512/ml513 record): x86 orders SSE/AVX accesses under
  TSO and FEX emits them unordered; enabling AVX puts more games on that path.
- **The classic branch stays the proven fallback** and is still untested on this phone:
  `install:APP` selects no branch (PLA-450), and free space was 14.6 GB against a 41.6 GB
  payload, so that route needs a page that picks a Steam branch and a decision about which
  installed title to free. Nothing was uninstalled for this diagnosis.
- **No pins move** in this plan; a later DXMT rebase still means rerunning
  `gen_remote_guard.py`, `gen_api_names.py` and `pp slots`.

## Phone state as written (2026-10-27)

Installed dev IPA `0107f809`; phone iPhone18,4, iOS 27.0.1, `dev.playport.app`, app pid
10127; free space 14.6 GB; Witcher 3's 4.x payload installed (68.8 GB); unattended mode not
used for the experiment. Reports and scratch for this plan go to
`.work/agent-notes/witcher3-avx/`.

## Linear and evidence to write as work proceeds

PLA-451 tracks the plan; PLA-43 already carries the 2026-10-27 diagnosis comment (run dirs,
the `vmovaps` bytes, the `enableavx` marker result). The first phone result worth relying on
gets its own `docs/evidence/2026-10-27-witcher3-avx*.md` with the IPA sha256 and the run
directory; screenshots stay in `.work`, described in the text.
