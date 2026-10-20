# KosmicKrisp Metal-build levers for RDR2 (PLA-364): built and host-tested, phone gates not run

**Date:** 2026-10-20. **Linear:** [PLA-364](https://linear.app/playportdev/issue/PLA-364).
Built in the side copy `.work/worktrees/kkcompile` (decision 0117), branch `kkcompile`.
**Phone gates not run:** nothing here was installed or played.

## What changed

- **mesa 0052, instrumentation** (`MESA_KK_DEBUG=compile`, which a dev build sets):
  - The Metal bridge's library and pipeline builds report why they failed (`struct mtl_build_error`).
    The report holds the NSError's domain and code, and whether its text names an interrupted
    compiler-service connection.
  - A failed build is always logged:
    `[kk-compile] render FAIL ms= step=vertex-library|fragment-library|pipeline err=DOMAIN:CODE interrupted=0|1 vs= fs= pipe= par= retries= src= tid= bytes= wall_ms= msl=`
    (compute: `step=library|pipeline`, `lib= pipe=`). It counts in the totals' `metal=` and in a new
    `failed=`.
  - Builds over 20 ms are logged as before, with each step's ms added (`vs=`, `fs=`, `pipe=`, or
    `lib=`/`pipe=`).
  - Each line also gives `src=translated|deserialized` (where the MSL came from), `tid=` (the
    system-wide thread ID, `pthread_threadid_np`) and `bytes=` (the MSL size, vertex+fragment).
  - The compiler-service pid is not logged: Metal has no API for it. Match `wall_ms` against the
    system log's `MTLCompilerService[pid]` lines instead.
- **mesa 0053, three `MESA_KK_EXPERIMENTAL` flags**, all off by default, so what is built is
  unchanged unless one is set:
  - `compile_retry`: a build that failed with `interrupted=1` is built again, at most twice,
    200 ms after each failure. Each retry logs
    `[kk-compile] … retry N/2 step= after_ms= err= src= tid=`.
  - `parallel_stages`: the fragment library builds on a second thread (`thrd_create`) while the
    calling thread builds the vertex library. The lines then show `par=1`. If the thread cannot
    be made, the two libraries build one after the other.
  - `library_size_opt`: libraries build with `MTLCompileOptions.optimizationLevel =
    MTLLibraryOptimizationLevelSize`.
- **The switches reach the phone** through a game's Graphics options. Decision 0135 (the owner's,
  this day) lets that row set any variable; these switches use `MESA_KK_EXPERIMENTAL`, which 0060
  already allowed. Setting `MESA_KK_EXPERIMENTAL` leaves the dev build's
  `MESA_KK_DEBUG=compile,memory` in place.

## Why the retry and parallel builds are off by default: the jetsam finding

The device syslogs of the PLA-364 RDR2 runs (`$PLAYPORT_BUILD/agent-notes/pla364r/{r1,r2,r3}/play/syslog.txt`)
show who ends MTLCompilerService:

```
memorystatus: MTLCompilerService [pid] exceeded mem limit: ActiveSoft 150 MB (non-fatal)
memorystatus: killing_highwater_process pid … [MTLCompilerService] (highwater 40 9s …) 153601KB …
```

- **Kills per run:** `killing_highwater_process … MTLCompilerService` lines number **11 in r3, 8 in
  r1 and 6 in r2**.
- **What ends it:** each kill comes when the compiler is over its **ActiveSoft 150 MB** limit while
  the system is short of memory.
- **When:** each kill comes **6–13 s** after that service process started its compile (the
  `highwater 40 Ns` field, and the `Compilation BEGIN` line before it).
- **What follows:** after each kill the app reconnects (`activating connection …
  com.apple.MTLCompilerService`) and the build starts again. This is Metal's own "This error
  occurred after multiple retries" in the `Failed to create MTLLibrary` lines.

**Reading:**
- One failed library costs several such 6–13 s attempts, which fits m10b's 48.6 s for 7 translations.
- A driver retry 200 ms later most likely repeats those cycles while memory stays short. That
  lengthens the stall, so `compile_retry` is off by default.
- Two libraries built at once may raise one service process's peak; most r3 builds went to one
  pid. That would mean more kills, so `parallel_stages` is off by default.
- Whether `library_size_opt` lowers the compiler's peak memory is unknown: Apple documents it only as
  "extra optimizations to reduce code size". The other MTLCompileOptions on the iOS 26.5 SDK
  (`mathMode`, `preserveInvariance`, `maxTotalThreadsPerThreadgroup`, `enableLogging`,
  `compileSymbolVisibility`) document no memory effect, and the MTL4CompilerTaskOptions hold
  only `lookupArchives`. So `library_size_opt` is the one option offered, and it is off by default.
- `bytes=` shows whether the failing builds are the large ones.

## Lever 6 (keep Mesa's disk cache across Mesa rebuilds): not done

- **What the key would have to cover:** NIR to MSL depends on `src/kosmickrisp/{vulkan,compiler}`,
  `src/compiler/{nir,spirv}` (including `nir_opt_algebraic`'s generated code), `src/poly`,
  `src/vulkan/runtime` (pipeline hashing and serialization) and `src/util` (blob, hashes), as
  well as the build options.
- **Why it is not safe:** meson cannot hash a directory without listing every file in it. A key
  that misses one file would serve stale MSL with no sign of it on the phone.
- **What it would gain:** the 35–38 s first-run translation after each Mesa build, in dev builds
  only. That gain does not justify the risk, so patch 0015's build-ID key stays.

## Builds and host checks (side copy)

- **`./pp test --quick`, then `./pp test` (Swift included):** all passed. 353 PlayportKit
  tests, including `testGraphicsOptionsSetAnyVariable`.
- **`build/stages/mesa.sh … hosttest`, the mock-Metal host test**, on 0001–0049 + 0052–0053:
  - All 34 cases are `ok`, with 139 MSL libraries, and `zink-host-test: ok`.
  - A new run in `build/mesa-host-test/run.sh` sets
    `KK_MOCK_INTERRUPT_BUILDS=2 MESA_KK_EXPERIMENTAL=compile_retry,parallel_stages`. The mock
    fails the first two library builds as interrupted (`make-mock-bridge.py`).
  - That run passes the same 34 cases and logs exactly 2 retries:
    `render retry 1/2 step=vertex-library` and `render retry 1/2 step=fragment-library`, on two
    different `tid=`. The build line is
    `render ms=200.1 vs=200.1 fs=200.1 pipe=0.0 par=1 retries=2`: the two 200 ms waits overlapped.
- **The failure path, by hand:** `KK_MOCK_INTERRUPT_BUILDS=1 MESA_KK_DEBUG=compile` without the
  retry logs
  `[kk-compile] render FAIL ms=0.0 step=vertex-library err=kk-mock:2 interrupted=1 vs=0.0 fs=0.0 pipe=0.0 par=0 retries=0 src=translated …`.
  `vkCreateGraphicsPipelines` returns `VK_ERROR_INVALID_SHADER_NV`, as before.
- **`./pp build` (dev):** IPA `out/20261020-102059-3ed322b3/Playport-26.5-3ed322b3.ipa` in the
  copy's build area.
  - sha256 `3ed322b3ca8bbabceeb5bb213321d65ac78a62277b86614f7251745623fa4307`,
    562,655,034 bytes.
  - `verify-ipa: 89 checks passed`.
  - KosmicKrisp is staged as `ed6b8546a0ffa83b` (14,339,000 bytes). Its strings include the FAIL
    and retry formats, `parallel_stages` and `library_size_opt`.
- **Build records:** the copy's build changed only `lib/libdxmt_combined.a` and
  `lib/libidevice_ffi.a` in `app/artifacts.tsv`. Both rows come from the copy's path (decision
  0117), so they keep main's values. KosmicKrisp has no row.
  - A later `pp verify` of that IPA against the committed records therefore reports the one
    expected `bundled artifacts.tsv` difference.
  - The main checkout's build regenerates the records.

## Owed on the phone (main checkout)

1. **Hollow Knight** (`app-367520`) through first frame+10 on the rebased build.
2. **RDR2 Story, defaults** (no `MESA_KK_EXPERIMENTAL`): count the `[kk-compile] … FAIL` lines
   and their `step=`/`err=`.
   - Record the exact NSError domain:code of the XPC interruption.
   - Sum the per-step `vs=`/`fs=`/`pipe=` ms by `src=`, and count the distinct `tid=`.
   - Compare the per-pipeline `ms=` against r3's 0.58–5.83 s.
   - Grep the syslog for `MTLCompilerService` kills.
3. **Then one arm per flag**, with
   `--settings 'app-1174180:{"graphicsOptions":"MESA_KK_EXPERIMENTAL=parallel_stages"}'`
   (`compile_retry`, `library_size_opt` in turn), merged with the run's usual RDR2 settings.
   Compare the FAIL/retry counts, `par=1` builds' `ms=` against `vs=`+`fs=`, and the
   MTLCompilerService kill count.
