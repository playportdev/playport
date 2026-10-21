# AFP off with FPCR.FIZ, the disk-cache key, and the QPC stub (PLA-364, PLA-320)

**Linear:** PLA-364 (RDR2 gameplay CPU), PLA-320 (Hollow Knight black without AFP), PLA-42 (Hollow Knight).
**Decision:** [0154](../decisions/0154-every-game-runs-without-afp-with-fiz-from-daz.md). **Patches:** fex 0080
(`MADEIRA_FEX_AFPOFF_FPCR`, from the `afp` side worktree; [afp-off](2026-10-21-afp-off.md)), fex 0081 (the
disk-cache key).

IPAs (dev):

- `0dfe14fe95c5574f29819ea9eac24ef4aae6f89e65fae822c2a80acb5dc18c01`: fex 0080 and 0081, defaults as 0153.
- `1823e9c0f6c393ae688183d72033343acc22234d0c2f0a2cd9a97be4f088a906`: the same FEX, with decision 0154's
  defaults.

The phone stayed on its charger at 80 %, with 4.6–5.3 GB free (`pp phone status`). RDR2 runs used
`.work/agent-notes/pla413e/afarm.sh` (qarm.sh with the IPA as a variable): Story, aspect 16:9, no stick input,
first frame+420. The save opens in the cabin, so they compare with qd1b of
[the switch queue](2026-10-21-switch-queue.md) (cabin window: first cabin screenshot +60 s, for 60 s; `cabin.py`).

## 1. fex 0081: the disk cache keys on every switch that changes a compiled block

- **The gap.** The process bucket covered FEX's config options (`SerializeForCache`), but not the environment
  switches read outside it. Those that change what a block compiles to:

  | Variable | What it changes |
  | --- | --- |
  | `MADEIRA_FEX_EC_RET` | `IosEcReturnWithRet`: BranchOps' BL into ARM64EC code |
  | `MADEIRA_X64_QPC_FASTPATH` | `IosRdtscSelfSync`: OpcodeDispatcher's RDTSC |
  | `MADEIRA_FEX_AFPOFF_FPCR` | `IosAfpOffFpcr`: SetRoundingMode, FillStaticRegs |
  | `MADEIRA_NO_DFE` | the pass list (no DeadFlagCalculationElimination) |
  | `FEX_TRACE_RIP` | a Print at each listed 32-bit address |

- **0080's key did not work.** `DiskCache::Init` runs in the context's constructor (`CreateNewContext`), and
  ARM64EC's ProcessInit sets `IosAfpOffFpcr` (and `IosEcReturnWithRet`, `IosRdtscSelfSync`) after it, so the
  key always read 0.
- **The fix.** `IosCodegenSwitches.h` lists the five variables. Init reads them itself, and each one that is
  set adds `name=value` to the process bucket's hash. With none set the bucket is as before.
- **Checked, and not keyed** (no compiled block changes):
  - `MADEIRA_FEX_EC_CALLRET_POP` and `MADEIRA_FEX_EC_BITMAP_CACHE`: the dispatcher, emitted each run;
  - `MADEIRA_FEX_BATCH2` (and `_SKIP`): Module.S's transitions, the sweeper, where a backpatch is written;
  - `MADEIRA_FEX_SMC_FASTPATH`, `MADEIRA_FEX_EC_EXIT_LEAN`, `MADEIRA_KEEP_SMC`, `FEX_EC_CALL_RING`: runtime paths;
  - `FEX_SMCCHECKS_FOR`: sets SMCChecks, a config option already in the key.
- **Test.** `tools/tests/test_fex_codegen_switches.py` builds the header's `AppendIosCodegenSwitches` on the
  host. It also fails when a fex patch reads a variable (`getenv("…")`) that is neither keyed nor named in
  its list of variables that change no block.
- **Stale blocks did not cause qp1 and x5.** The app clears the whole cache before a launch when the phone
  has under 10 GB free (`EmulatorCache.keepWithinBudget`). This phone has had less for days. x5
  (`…T122756-rdr2-x5`, "9.47 GB free … cleared") and qp1 (`…T125213-rdr2-qp1`, "8.71 GB free … cleared")
  both started with an empty cache, as did every run below. 0081 matters on a phone with room for the cache.
- **Not observed on the phone.** Because of that clearing, no run here shows two process buckets side by side.

## 2. Hollow Knight without AFP, by FPCR mode (IPA 0dfe14fe)

Each run: `--settings 'app-367520:{"runtime":"env.FEX_HOSTFEATURES=disableafp env.MADEIRA_FEX_AFPOFF_FPCR=<mode>"}'`,
first frame+25, one screenshot at the end.

| Run (`.work/ui-runs/…`) | Mode | `afpoff-fpcr` line (every process) | First frame | Screen at +25 |
| --- | --- | --- | --- | --- |
| `20261021T190310` | AFP on (gate, no settings) | none | +11.16 s | menu (at +10) |
| `20261021T190426` | `fiz` | `mode=1 (fiz)` | +10.33 s | **menu** |
| `20261021T190607` | `ah` | `mode=2 (ah)` | +11.11 s | **menu** |
| `20261021T190729` | `ahx` | `mode=3 (ahx)`, `ec-exit-lean-v1 … enabled=false` | +10.33 s | **menu** |
| `20261021T190901` | `0` (control) | `mode=0 (0)` | +11.15 s | **black** (only the touch controls) |

- **FIZ is what Hollow Knight needs.** `fiz` leaves AH clear, so the -NaN default, NaN order and FTZ-on-input
  differences are not what blacks it out. What does is MXCSR.DAZ (denormal inputs as zero) going unapplied.
- **The smallest mode is `fiz`.** It writes FPCR only on LDMXCSR (or when FIZ is wrong after a runtime call),
  never on a transition, and it leaves ARM64EC code's behaviour IEEE except for FIZ, as AFP did.
  [afp-off](2026-10-21-afp-off.md) §4's AH list is not needed for this decision, and was not checked
  against the Arm ARM.

## 3. RDR2 with `fiz`, and the QPC stub

| Run (`.work/ui-runs/…`) | IPA | Keys over the defaults | Thermal | Scene | fps | E GHz | fps/E-GHz | GPU ms/frame | CPU cores | CPU mW | x64->EC/s | Peak MB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| qd1b `T175004` ([switch queue](2026-10-21-switch-queue.md)) | d95adbbd | none | serious at launch | cabin, drawn | 16.6 | 1.33 | 12.5 | 23.9 | | 317 | | 7492 |
| af1 `T191104-rdr2-af1` | 0dfe14fe | `env.MADEIRA_FEX_AFPOFF_FPCR=fiz` (RDR2's entry: `disableafp`) | nominal at launch, serious 19:15:30 | cabin, drawn | 19.6 | 1.60 | **12.3** | 22.0 | 2.86 | 399 | 497 k | 7662 |
| aq1 `T193325-rdr2-aq1` | 1823e9c0 | `env.MADEIRA_X64_QPC_FASTPATH=1` (0154's defaults: `disableafp`, `fiz`) | nominal at launch, serious 19:36:40 | cabin, drawn | 18.9 | 1.59 | **11.9** | 21.9 | 2.73 | 391 | 423 k | 7475 |

- **af1, `fiz` on RDR2.** The cabin draws as qd1b does: on the screenshots compared, Arthur on the bench by the
  bright doorway, with the same white hat brim and red ear. Its 12.3 fps per E-GHz is within the spread
  against 12.5 (qd1b was hotter, and a hotter, slower-clocked run scores higher).
  - Signed in at +110.5 s, no `0xc0000005`, no jetsam.
  - The title process logged `FEX: afpoff-fpcr mode=1 (fiz)`.
- **So `fiz` works for both titles, and became every game's default** (decision 0154, IPA 1823e9c0). RDR2's
  entry keeps only `graphics: vulkan`.
  - Hollow Knight gate on 1823e9c0 with no session settings: `20261021T192845`, menu fading in at first frame+10
    (+11.83 s); `20261021T192950`, the full menu at +25.
  - The title's config shows `FEX_HOSTFEATURES=disableafp` and `MADEIRA_FEX_AFPOFF_FPCR=fiz` from the default,
    and every process logs `mode=1 (fiz)`.
- **aq1, the QPC stub, is good this time.**
  - It bound by name in each process (`[x64-qpc] KERNEL32.QueryPerformanceCounter … bound by name`). The
    `[xp-api-top]` entry `ntdll.dll+0x69090` (57 k/s in af1) is gone, and transitions fell 15 %
    (423 k/s against 497 k).
  - The cabin drew to the end of the run. Signed in at +107.6 s, no `0xc0000005`, no jetsam, peak
    7475 MB.
  - **But it is not faster.** 18.9 fps against 19.6, and 11.9 fps per E-GHz against af1's 12.3, at the same
    clock and heat, with 0.13 fewer cores and 8 mW less. One run each, so this is within the spread.
  - It is **not proposed as a default**: the switch stays off.
  - What turned qp1 black is not known. It was not a stale cache (§1), and aq1 started in the cabin, not on
    the porch where qp1 went black on leaving.
  - Nothing here points at the host side (time going backwards between the stub and the EC path).
    `test_x64_qpc_fastpath.py` interleaves both paths with no value going back. The rule allowed one more run
    only for a bad result, so none was made.
- **The black loading screen** after the game's Social Club end (qe2c, xs1) did not appear in af1 or aq1.

## Also seen

- **Processes in one launch can need different disk-cache directories.** In the Hollow Knight runs,
  process 68 runs with `FEX_HOSTFEATURES=288` (LRCPC2 on) and the others with 32. The host features key FEX's
  machine bucket, and opening one bucket removes every other directory (`PruneStaleEntries`). So within a
  launch, such processes delete each other's cache. It is moot while the app clears the cache every launch
  on this phone (§1).
- **`pp phone lock --help`** treats `--help` as the command to run, and fails with a Python traceback.

## Gates

- `./pp build`: IPA 0dfe14fe (fex 0080 + 0081; `verify-ipa: 89 checks passed, 0 failed`).
  - Its build records change only for `xtajit64.dll` and `xtajit.dll`, which confirms the side worktree's
    claim that only those rows move. Main's rows supersede the worktree's, which carried 0080 alone.
  - Then IPA 1823e9c0 (decision 0154, the app only): 89 passed.
- `./pp test`: all passed, on each commit. `./pp names` and `./pp secrets`: clean.
- Hollow Knight first frame+10: `20261021T190310` (0dfe14fe, the menu) and `20261021T192845`/`T192950`
  (1823e9c0, the menu by +25).
