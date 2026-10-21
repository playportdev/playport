# 0152: RDR2's compatibility default takes the x64 critical-section stubs and FEX's batch 2

**Status:** accepted, 2026-10-21, under the supervisor's delegation for this session's RDR2 defaults
(PLA-364). Amends [0142](0142-rdr2-owner-test-defaults-heap-size-semaphores-and-afp.md), whose
defaults stay. Revisit if an owner play, or a title other than RDR2, shows a cost.

## Context

- **RDR2 is CPU-bound under the SoC's power clamp.** It runs at about 15–16 frames/s at the cabin porch, with
  the GPU under half busy. Each frame makes about 27,000 x64→ARM64EC transitions
  ([2026-10-20-rdr2-perf-arms.md](../evidence/2026-10-20-rdr2-perf-arms.md)).
- **Two switches cut that work, both off by default:**
  - `MADEIRA_X64_CS_FASTPATH=1` (wine-pe 0050) binds an x64 module's imports of Enter/LeaveCriticalSection
    to x64 stubs that take a free section without leaving the emulator.
  - `MADEIRA_FEX_BATCH2=1` (fex 0071) has four parts:
    - x64→EC translation by one probe of a 64 KB-granule table;
    - ExitToX64's bypass to the pool copy;
    - enter_jit without `dmb ish`;
    - FEX's unaligned-atomic backpatch through the RW alias.

    Its fix fex 0070 is always on. See [2026-10-21-batch2.md](../evidence/2026-10-21-batch2.md).
- **Measured on the phone** ([2026-10-21-rdr2-combined-arms.md](../evidence/2026-10-21-rdr2-combined-arms.md)).
  All runs were on IPA 7910e2a3, back to back, at `thermal: serious`, with 60 s porch windows:
  - **Defaults, four runs (d2–d5):** 14.8–15.4 fps at E 1.39–1.48 GHz, 10.4–10.6 fps per E-GHz,
    366–385 mW.
  - **Both switches, two runs (x10, x11):** 15.7 fps at E 1.35 GHz, 11.6 fps per E-GHz, 342–351 mW.
    x10's 300 s window gave 15.6 fps at 1.34 GHz.
  - **Against defaults:**
    - fps per E-GHz +9–12 %, outside the defaults' own ±1 % spread;
    - fps +2–6 %;
    - CPU power −5 to −11 %.
  - **No faults.** Neither run crashed. Both signed in, held the porch and peaked at 6.97–7.15 GB, within
    the defaults' 6.9–7.4 GB.
  - **x9 excluded.** A third run, x9, gave 17.8 fps, but its porch drew a third of the indexed draws a
    frame (627 against 1,860–1,950), so it was not the same scene.
  - **The gain is modest.** It is mostly the same frame rate for less CPU clock and power under the
    clamp.
- **What does not go in:**
  - `MADEIRA_X64_QPC_FASTPATH=1`: the game left the porch for a black screen (qp1), and a run with it
    died (x5).
  - `MESA_KK_BATCH2=1`: a run with it went past the memory limit at the porch load (x6), and with
    `_SKIP=alloc` the porch stayed black (x8).
  - `MESA_KK_SAFE_MATH=1`: GPU time per frame rose 28 % (x7), and the porch does not show the hair
    artefact it is for.
  - `MADEIRA_ECO_NATIVE=1`: only measured together with SAFE_MATH.
  - `PLAYPORT_SC_SINGLE=1`: the owner decides (decision 0150).

## Decision

- **RDR2's compatibility default (`app-1174180`) adds two runtime keys:** `env.MADEIRA_X64_CS_FASTPATH=1` and
  `env.MADEIRA_FEX_BATCH2=1`, after 0142's `jumbo-mb=8960 env.PLAYPORT_VK_HEAP_MB=3072
  env.MADEIRA_FASTSYNC_SEM=1 env.FEX_HOSTFEATURES=disableafp`.
- **Overrides.** Like every runtime key of a default, a person's Runtime keys row (dev build) overrides each
  by key: `env.MADEIRA_X64_CS_FASTPATH=0`, `env.MADEIRA_FEX_BATCH2=0`. `MADEIRA_FEX_BATCH2_SKIP=alias,ffs,dmb,uabp`
  turns parts off for a bisect.
- **Scope.** The switches stay off for every other title.

## Costs and risks

- **The defaults reach a release build too** (0126), where a person cannot override them. Both switches
  are the same code in the release build.
- **Only RDR2 has run with them.** Only its launch to the porch was measured, about 5 minutes of play.
  The critical-section stubs do not cover `GetProcAddress` callers.
- **Separate effects were not measured.** Which of the two switches (and which of batch 2's four parts) gives
  the gain is not separated. The critical-section stubs alone had given the same fps per E-GHz
  ([2026-10-21-rdr2-cs-fastpath-and-heap.md](../evidence/2026-10-21-rdr2-cs-fastpath-and-heap.md)).
