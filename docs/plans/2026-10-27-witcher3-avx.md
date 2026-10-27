# The Witcher 3's current 4.x build needs an AVX128 path in the iOS FEX host

**Linear:** [PLA-451](https://linear.app/playportdev/issue/PLA-451). Related:
[PLA-43](https://linear.app/playportdev/issue/PLA-43) (the title),
[PLA-444](https://linear.app/playportdev/issue/PLA-444) (the sweep that hit it),
[PLA-450](https://linear.app/playportdev/issue/PLA-450) (branch selection),
[PLA-269](https://linear.app/playportdev/issue/PLA-269) (cohort FEX features),
[PLA-81](https://linear.app/playportdev/issue/PLA-81) (the Witcher 3 DX12 candidate waits on this).

**Status:** started 2026-10-27; chunk 1 in progress.
**Branch:** `dev/pla-451-fex-ios-host-avx`, from `main` at `5317c13`, not pushed.

## Runner state (2026-10-27)

**HEAD:** `2c4e79f` (the plan commit) on `dev/pla-451-fex-ios-host-avx`; `main` is at
`5317c13`. Not merged, not pushed.

**Finished:** nothing yet.

**Running now:** chunk 1 (writer child, hard model). If a new session finds no
chunk-1 report in `.work/agent-notes/witcher3-avx/reports/`, check
`git log --oneline main..HEAD` and `patches/fex-port/series` before launching
anything — a committed `0064-*` patch means chunk 1 landed.

**Queue, in order** (one writer at a time; each item is one child):

1. Chunk 1 — `patches/fex-port/0064-*` sets `SupportsAVX = true` on the iOS
   host. PLA-451. Check: `pp test`, `pp build`.
2. Chunk 2 — honest runtime marker rev, then Hollow Knight `--until
   first-frame+10 --shot` (the runtime smoke gate) and one Witcher 3 play
   (`app-292030`, page settings). PLA-451. Writes the first
   `docs/evidence/2026-10-27-witcher3-avx*.md`.
3. Chunk 3 — 256-bit (ymm) state correctness across the ARM64EC context and the
   `CONTEXT_XSTATE`/`XSTATE_AVX` host→guest path; host round-trip check, no play.
   PLA-451.
4. Chunk 4 — per-title FEX features in the cohort entry (PLA-269) and Witcher 3's
   entry in `app/PlayportKit/Titles/compat-defaults.json`. PLA-451, PLA-269.
5. Chunk 5 — AVX on/off cost on a shipped vector-heavy title: Hollow Knight
   `pp perf`, plus a Witcher 3 play. PLA-451.
6. Chunk 6 — Witcher 3 play gates and the PLA-43 comparison; a human play moves
   PLA-43's status and `site/compatibility/games.json`. PLA-43.

The performance numbers that decide anything come from a human `pp perf` run the
supervisor starts, not from a child's scripted run.

**Phone state (2026-10-27 15:52, `pp phone status`):** installed dev IPA
`0107f809` (`0107f8096ec1f1234e1cfa8812850c1faa198b34ffad2828b30b4f070ac3a38a`),
installed from `ce36a49`, iPhone18,4 iOS 27.0.1, profile expires 2026-11-03,
battery 80% unplugged, free space 14.7 GB, no lock held, unattended mode off,
app pid 10186.

**Scratch:** `.work/agent-notes/witcher3-avx/` — `reports/` (child reports, one
per chunk), `queue.md` (build-area copy of the order above).

**Owner, 2026-10-27:** after the boot-regression sweep left Witcher 3 as the only title
without a first frame, the diagnosis asked whether AVX is the only blocker. One short
phone experiment answered it (below), and the owner chose to plan the runtime work rather
than execute it.

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

1. **Give the iOS host AVX128** ✅ started 2026-10-27 — a Playport patch `patches/fex-port/0064-*` (next free
   number) that sets `SupportsAVX = true` in the `FEX_IOS_HOST` branch of
   `Source/Windows/Common/CPUFeatures.cpp`, with `Class:`, `Evidence:` and
   `Offered-upstream:` trailers and a `series` entry. Pins stay: Madeira is frozen at
   `8c050d0` (decision 0054), this is a Playport patch on the existing tree.
   Check: `pp test` (name gate, secrets, pin and series checks), then `pp build`.
2. **Make the marker honest and the gate decisive** — the ml538 line says
   `DISABLEAVX expected`, so it must carry a new rev saying AVX is on; otherwise a later
   grep cannot tell which way it shipped (the ml513/ml538 lesson). Then one Witcher 3 play
   on the phone with the page's saved settings, `--until first-frame+10 --shot`: the run
   either reaches a first frame (the VEX store decoded) or names the next faulting guest
   RIP, which is the next thing to fix.
3. **256-bit state correctness** — read the EC context's `V[16]` high halves against FEX's
   ARM64EC convention, the `CONTEXT_XSTATE`/`XSTATE_AVX` path for host→guest, and Wine's
   save/restore of ymm across exceptions and signals; the guest exception work in
   `patches/fex-port/0063` and the ARM64EC transition machinery is the place to check.
   A wrong high half is silent corruption, not a crash, so this chunk needs a host check
   (a round-trip of known ymm bytes through the EC context) rather than a play.
4. **Make it per-title, not global (PLA-269)** — let the cohort entry carry FEX features, so
   only titles that need AVX get it; and give Witcher 3 its compatibility default in
   `app/PlayportKit/Titles/compat-defaults.json` (there is no Witcher entry today) if the
   title needs it shipped rather than set by hand.
5. **Measure what AVX costs** — `pp perf` on a vector-heavy title with AVX on and off
   (ml538 measured the webhelper spawn only). Hollow Knight is the required regression play
   for any FEX series move; its own frame times answer whether AVX128 taxes the shipped games.
6. **Witcher 3 play gates** — first frame, then the PLA-43 comparison: gameplay in Kaer
   Morhen at 720 rows on the DX12 path, and `pp perf --compare` against the classic 1.32
   record (first frame +17.73 s, GPU 32–34 ms, IPA `965b7f27`). PLA-43's status, **Best
   known** and `site/compatibility/games.json` move only with a human play behind them.

## Exit criteria

The plan is done when Witcher 3's installed 4.x build reaches a first frame and a human play
shows gameplay, AVX is recorded in the runtime marker, its cost is measured on a shipped
title, and titles that do not need it are unchanged (Hollow Knight and the compatibility
ledger still pass).

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
