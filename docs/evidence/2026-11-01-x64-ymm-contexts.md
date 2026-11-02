# The ymm high halves through an x86-64 guest's exceptions, APCs and thread contexts (2026-11-01)

**Linear:** spec [PLA-516](https://linear.app/playportdev/issue/PLA-516) (World of Warcraft's
x86-64 client through FEX); the two gaps are [PLA-454](https://linear.app/playportdev/issue/PLA-454)
(G1) and [PLA-453](https://linear.app/playportdev/issue/PLA-453) (G2); the switch is part of
[PLA-588](https://linear.app/playportdev/issue/PLA-588).

**Status: the high halves are not kept as Windows keeps them, and the gaps were not fixed. Instead
FEX's `disableavx` now works on the iOS host (`patches/fex` 0088), and every World of Warcraft
product turns AVX off by its compatibility default. Code reading and desktop Wine only: no phone
run yet.** Written in the side copy `.work/worktrees/fexavx` (decision 0117), branch
`dev/pla-516-fex-avx`.

## The question

FEX on the ARM64EC host reports AVX and AVX2 to every x86-64 guest (`patches/fex-port` 0064)
and runs 256-bit operations as two 128-bit halves, keeping each ymm register's high half in its
thread state (`State.avx_high`). On Windows the context of an exception, an APC and
Get/SetThreadContext carries those halves as `CONTEXT_XSTATE`, and `NtContinue` restores them. Are
they kept on the phone? WoW's start handles many exceptions (PLA-514), and it takes AVX2 paths when
told AVX.

## What the code does (pins: `build/ymm-context/test.py`)

- **Exceptions.** FEX packs a faulting guest's state with `StoreStateToPackedECContext`, which
  publishes the high halves in `V[16..31]`; Wine's `prepare_exception_arm64ec` converts it with
  `context_arm_to_x64` (`dlls/ntdll/unwind.h`), which copies `V[0..15]` only and never sets
  `CONTEXT_XSTATE`. `NtContinue`/`RtlRestoreContext` go back through `context_x64_to_arm`, which
  zeroes `V[16..31]` and sets no `CONTEXT_ARM64_FEX_YMMSTATE`, so FEX's `LoadStateFromECContext`
  calls `SetXMMRegistersFromState(…, nullptr)` and leaves `avx_high` as it is. The halves survive
  only by not being touched: a handler cannot read or set them (no XSTATE), and its own AVX writes
  (a `vzeroupper`, a memcpy built with AVX, any VEX-128 write) reach the code it resumes (G2).
- **A fault in the middle of a block.** FEX flushes only the GPR and XMM static registers before
  each instruction (`FlushRegisterCache(true)`, Core.cpp); a high half written earlier in the block
  can still be in the register cache when a later instruction faults, and `ReconstructThreadState`
  spills only the static registers. A continued fault then resumes with the high half last stored
  to `avx_high` (G1). An `int3` is not affected: `Break` flushes the whole cache first.
- **APCs.** `dispatch_apc` converts with `context_arm_to_x64` and ends in `NtContinue`: as above.
- **Suspend, Get/SetThreadContext.** Another thread's context comes from FEX
  (`BTCpu64IosGuestContext`, high halves in `V[16..31]`) through `context_arm_to_x64` (dropped);
  `NtSetContextThread` goes through `context_x64_to_arm` (no high halves, so `avx_high` stays). A
  suspended thread keeps its halves; nobody can read or set them.
- **What the guest is told.** CPUID and XCR0 report AVX (CPUID.cpp from `SupportsAVX`), but
  `user_shared_data->XState` is filled only on x86 hosts (`init_xstate_features`, unix
  `system.c`), so on the phone `GetEnabledXStateFeatures()` returns 0 [INFERENCE: not observed]
  and `InitializeContext` with `CONTEXT_XSTATE` fails (`exception.c`, `STATUS_NOT_SUPPORTED`).

Upstream: FEX says it implements AVX for ARM64EC "with wine patches"
([FEX-Emu/FEX#5993](https://github.com/FEX-Emu/FEX/issues/5993)); those Wine patches are not in
WineHQ's tree, and Playport's Wine has none (pinned by `test.py`: no `FEX_YMMSTATE`, no `XSTATE`
in `unwind.h`).

## The probe: `tools/compat/probes/ymmctx.c`

Built by `tools/compat/probes/build.sh` (llvm-mingw, x86-64; `ymmctx.exe` sha256
`f5f3ffd122c5baba9b0343474a06006acb937ec513822de073172649cbd4c2a2`, 88,064 bytes). Each check
loads all 16 ymm registers in assembly, lets one event happen and stores them in assembly; its
header lists the checks (a–k) and what Windows does in each. `noavx` as its arguments checks
instead that AVX, AVX2, FMA, F16C, BMI1/2 and XCR0's AVX bit are absent.

**Desktop Wine 11.20** (x86-64 workstation, AMD, real AVX; scratch prefix): exit 0, `done ok`,
every check `ok`. Informational: `f` (RaiseException) kept both halves; `h` (an APC that overwrites
ymm, run inside `SleepEx`) kept the low halves and not the high ones, which the x64 ABI allows (the
high halves are volatile across a call). With `noavx` the probe fails on this CPU, as it should.

**Expected on the phone with AVX on** [INFERENCE from the code above, to be run]: `told AVX` BAD
(`GetEnabledXStateFeatures` 0), `a` ok, `b` BAD (G1), `c` BAD (G2), `d`/`e` BAD (no
`CONTEXT_XSTATE`), `g` BAD (G2), `i` BAD (`InitializeContext` with XSTATE fails; the thread itself
keeps its halves), `k` ok; `done FAIL`, exit 1. **With `disableavx`:** both `noavx` checks ok,
`done ok`, exit 0.

## The change

- **`patches/fex` 0088:** the iOS branch of `FetchHostFeatures` honours `FEX_HOSTFEATURES`'
  `disableavx`, after its hand-set `SupportsAVX`. The guest then sees what a CPU without AVX
  reports (CPUID, XCR0, `IsProcessorFeaturePresent` from the same CPUID), and a VEX opcode is an
  invalid instruction. The disk cache keys on the host features (`HashForCaching` covers
  `SupportsAVX`). Nothing changes without the switch. Compiled here for arm64ec with the main
  tree's compile command; not built into an IPA.
- **Compatibility defaults** (decision 0074): `bnet-wow`, `bnet-wow_classic`,
  `bnet-wow_classic_era` and `bnet-wow_anniversary` set
  `env.FEX_HOSTFEATURES=disableafp,disableavx`. The key replaces every game's
  `env.FEX_HOSTFEATURES=disableafp` (decision 0154), so it names `disableafp` again; dev and release
  builds both take a compatibility default's runtime keys. It reaches the x86-64 session and any
  x86-64 client; the ARM64 client runs without FEX and is not affected.
- Whether WoW's x86-64 client starts and plays without AVX is not known: it logs CPUID-gated paths
  (feasibility study, `cpu.log`), and Blizzard's minimums name no AVX.

**Host checks in the side copy:** `pp test --quick`: names, secrets, patches and every C test ok
(ymm context skipped: no run tree there); `tools/tests` failed only in `test_rebase` (2) and
`test_x18_abi` (1, no `upstream/madeira` checkout), which fail the same on the base commit without
this change. `pp test --swift PlayportKit --filter CompatDefaultsTests`: 14 passed, including the
WoW entries' resolved `env.FEX_HOSTFEATURES`.

## To run on the phone (main checkout, after the branch is merged and built)

```sh
./pp build && ./pp install
bash tools/compat/probes/build.sh
P=$PLAYPORT_BUILD/compat/probes
./pp phone put $P/ymmctx/ymmctx.exe Documents/Import/ymmctx/ymmctx.exe
./pp ui --action import:Import/ymmctx
# 1. AVX as every other title has it: expect exit 1, done FAIL, with the BAD lines listed above
./pp ui --play dir-ymmctx --wait 120
./pp phone pull Documents/prefix/drive_c/Games/ymmctx/ymmctx.log $PLAYPORT_BUILD/ui-runs/ymmctx-avx
# 2. AVX off as World of Warcraft has it: expect exit 0, done ok
./pp ui --settings 'dir-ymmctx:{"runtime":"env.FEX_HOSTFEATURES=disableafp,disableavx","arguments":"noavx"}' \
    --play dir-ymmctx --wait 120
./pp phone pull Documents/prefix/drive_c/Games/ymmctx/ymmctx.log $PLAYPORT_BUILD/ui-runs/ymmctx-noavx
# 3. The smoke gate on the same IPA
./pp ui --play app-367520 --until first-frame+10 --shot
```

The host log's `FEX: iOS host AVX=` line says which way each launch ran (`AVX=0` in run 2).
