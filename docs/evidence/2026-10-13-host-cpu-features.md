# Host CPU features reach FEX as `disable<x>` (PLA-132)

**Linear:** PLA-132. Code: 33162cf (`FEXProfile.hostFeatures`, `HostCPU`), 08c02fc (the switches reach
every process before the session root starts). Dev IPA `42d9ad91043eb460fb25a4f6dba1490db49c8d7ab63985647adb0d13131ae122`.

## What changed

FEX cannot read the ID registers on iOS and sets every feature on by hand (fex-port 0009), so an A12
(ARMv8.3: no FlagM, FlagM2, AFP, LRCPC2) was given `rmif` and `cfinv`. The app now reads the kernel's
`hw.optional.arm.FEAT_*` and passes `disable<x>` for each one it reports 0. A sysctl the kernel lacks
(nil) leaves FEX's value. A switch the player's own `FEX_HOSTFEATURES` names, either way, is kept; a
numeric bitmask is left alone. The app is unchanged on a CPU with everything: our phone's string is
still `enablelrcpc2`. No FEX patch.

| sysctl `hw.optional.arm.` | FEX switch | our phone |
| --- | --- | --- |
| `FEAT_FlagM` | `disableflagm` | 1 |
| `FEAT_FlagM2` | `disableflagm2` | 1 |
| `FEAT_AFP` | `disableafp` | 1 |
| `FEAT_LSE` | `disableatomics` | 1 |
| `FEAT_LRCPC` | `disablelrcpc` | 1 |
| `FEAT_LRCPC2` | `enablelrcpc2` when 1 (as before) | 1 |
| `FEAT_FCMA` | `disablefcma` | 1 |
| `FEAT_PMULL` | `disablepmull128` | 1 |
| `FEAT_AES`, `FEAT_SHA1`, `FEAT_SHA256`, `FEAT_CRC32` | `disablecrypto` if any is 0 | 1, 1, 1, 1 |

Every name is in FEX's `HOSTFEATURES` enum (`Config.json`) and honoured on the iOS host by fex 0005, 0008
and 0023. An A12 gets `disableflagm,disableflagm2,disableafp`. fex 0009 sets FlagM2 and FlagM separately,
so both names are passed.

The title's launch merges the string (`LaunchCoordinator.applyEnvironment`, one FEX_HOSTFEATURES for
x86-64 and i386 processes alike: one FEX, `CPUFeatures.cpp`, built into both). The disable part is also
put in the app's process environment before the session root starts, so no Wine process starts without
it: before, the first FEX instance (the session root) always logged `FEX_HOSTFEATURES=0`. Nothing is set
on our phone (the log line `host-cpu: FEX_HOSTFEATURES … for every process` is absent).

The log line `host-cpu: FEAT_FlagM=1 … ; fex: FEX_HOSTFEATURES <value>` shows what the app computed.

## Tests

`./pp test --swift PlayportKit` (233 tests, 0 failures) with `testHostFeaturesDisableWhatTheKernelReportsAbsent`
(A12-like table: `disableflagm,disableflagm2,disableafp`, no `enablelrcpc2`; every switch absent; one crypto
part absent; the player's switch wins; a bitmask is left alone) and the existing LRCPC2 test, now an
all-present table (unchanged output). `./pp test --quick`, `./pp check`, `./pp names`: clean.

## Phone (iPhone18,4, dev IPA above, Vulkan, 16:9 default, `--until first-frame+10 --shot`)

| Run | Settings | FEX log (title process) | Result |
| --- | --- | --- | --- |
| `.work/ui-runs/20261013T063445` | normal | `AFP=1 LRCPC2=1 FlagM=1 FlagM2=1 (FEX_HOSTFEATURES=256)` | HK menu, first frame +9.8 s |
| `.work/ui-runs/20261013T063545` | `runtime: env.FEX_HOSTFEATURES=disableflagm,disableflagm2,disableafp,disablelrcpc2` | `AFP=0 LRCPC2=0 FlagM=0 FlagM2=0` | first frame +10.6 s, **black** screenshot, 8.5k `Unhandled JIT SIGBUS` lines |
| `.work/ui-runs/20261013T063648` | same, Portal 2 (`app-620`) | same | first frame +6.0 s, Source logo and legal text on the screenshot |

(The first normal run on the previous IPA, `20261013T063137`, showed the same unchanged profile.)

Hollow Knight with the set forced off is black, so I bisected it (same IPA, HK, one run each, switches as
the whole `FEX_HOSTFEATURES` value; the app adds `enablelrcpc2` when the set does not name it, which is why
the first rows keep LRCPC2=1):

| `FEX_HOSTFEATURES` | LRCPC2 in FEX | SIGBUS lines | Screenshot |
| --- | --- | --- | --- |
| `disableflagm,disableflagm2` (`20261013T063843`) | 1 | 2 (as normal) | first frame +10 |
| `disableafp` (`20261013T063943`) | 1 | 2 | first frame +10, **black** (re-read 2026-10-21) |
| `disableflagm,disableflagm2,disableafp` (`20261013T064052`) | 1 | 2 | first frame +10, **black** (re-read 2026-10-21) |
| `disablelrcpc2` (`20261013T064151`) | 0 | 8.5k | HK menu |
| `disableflagm,disableflagm2,disablelrcpc2` (`20261013T064545`) | 0 | 8.5k | picture (not black) |
| `disableafp,disablelrcpc2` (`20261013T064441`) | 0 | 8.5k | **black** at +15 |
| all four (`20261013T064317`, +25 s) | 0 | 8.5k | **black** |

So FlagM, FlagM2 and LRCPC2 off are fine on HK. **Correction (2026-10-21):** the two `disableafp`
rows with LRCPC2 on were black as well (their screenshots), so AFP off alone is black on HK, whatever
LRCPC2 does; see [2026-10-21-afp-off.md](2026-10-21-afp-off.md). The original text read:
So FlagM, FlagM2 and AFP off are fine on HK, as is LRCPC2 off alone. What an A12 gets from the app is
`disableflagm,disableflagm2,disableafp` and no `enablelrcpc2`, which is the last row: the games on an A12
will show the same black until that is understood. Not caused by the new profile logic, which only
supplies the string; the rows show the combination "AFP off and no TSO imm9" misbehaves on this build.
The SIGBUS lines are the stores to a JIT page after "Handled self-modifying code" (`STR q1,[x0]` and
`STUR q1,[x6,#-80]`; two such lines happen on a normal run too), and with LRCPC2 off they repeat about 8.5k times.

## State

- The app side of PLA-132 is done and tested: the correct feature set reaches FEX in every process.
  Whether an A12 then runs the titles could not be shown without one: the forced-off HK run above is
  the nearest test, and it is black. Open: HK black with AFP and LRCPC2 both off (follow-up).
- Not covered: LSE2 (`FEAT_LSE2`, an A12 lacks it) and the GPU family (PLA-315).
