# KosmicKrisp's MSL size: SPIR-V unroll hints made RDR2's failing shaders (PLA-364); host checks

**Date:** 2026-10-20. **Linear:** [PLA-364](https://linear.app/playportdev/issue/PLA-364).
**Decision:** [0139](../decisions/0139-kosmickrisp-drops-costly-unroll-hints-and-skips-known-failing-msl.md).
**Change:** `patches/mesa` 0060 (unroll hints), 0061 (`MESA_KK_DUMP_MSL_MIN_KB`), 0062 (the
known-fail list); host test `build/mesa-host-test/shaders/unroll-hint.frag`, `kk-host-test.c`,
`run.sh`. Built in the side copy `.work/worktrees/kkmsl` (decision 0117), branch `kkmsl`.

**Phone gates not run.** Nothing here was installed or played. Sizes come from replaying RDR2's
captured pipelines on the host mock of KosmicKrisp, not from the phone.

## 1. What failed on the phone

- **The failures.** The PLA-413e s1 host log has 4 `[kk-compile] render FAIL` lines, all
  `step=fragment-library err=MTLLibraryErrorDomain:3 interrupted=1`, 33.8–39.7 s each, for 3 MSL:
  `de82d6177585f77c` (twice, `bytes=472930+6677852`), `23e8338639c9ccc6` (`472930+6683006`) and
  `390dca776b6133fc` (`286105+6160473`). Their fragment MSL is 6.2–6.7 MB.
- **The rest.** 1,986 translations in that run took 25 s in all. The supervisor's count: in s1 and
  s2 iOS killed MTLCompilerService 15 and 13 times.

## 2. Measuring on the host

- **The corpus.** RDR2's Fossilize captures from the Vulkan route (the route s1 played:
  `graphics=vulkan`), from PLA-364's earlier work: `rdr2-sga.foz`, `rdr2-sga-ingame.foz`,
  `rdr2-sga-ingame2.foz` and `rdr2-sga-ingame-h1b.foz`, and the DX12 route's
  `rdr2-vkd3d-h3.foz`. Reflinked into the copy's build area; not committed.
- **The replay.** `fossilize_replay --num-threads 8` with `VK_DRIVER_FILES` naming the mock ICD
  that `build/stages/mesa.sh ROOT hosttest` builds, `MESA_SHADER_CACHE_DISABLE=true` and
  `KK_MOCK_MSL_DIR` set, so the mock writes every MSL library it is given. `h1b` replays 1,933
  graphics and 731 compute pipelines in 16–39 s.
- **Sizes before the change** (mesa 0001–0053, `h1b`):

  | | libraries | total | median | p90 | p99 | largest | over 1 MB |
  |---|---|---|---|---|---|---|---|
  | before | 3,820 | 316.4 MB | 27.5 KB | 226 KB | 453 KB | 6,683,769 B | 9 |
  | after (0060) | 3,824 | 261.8 MB | 27.6 KB | 223 KB | 445 KB | 927,867 B | 0 |

  The other Vulkan captures give the same 9 over 1 MB before and none after.
- **The nine are the phone's.** All nine are fragment shaders of 5,303,722–6,683,769 bytes. The
  three largest are 6,683,769, 6,683,188 and 6,678,034 bytes, against the phone's 6,683,006 and
  6,677,852; the phone's vertex MSL, 472,930 bytes, is not among them because the mock's vertex
  state differs. The exact phone hashes were not matched (that needs the dump below).

## 3. The cause

- **Indentation is a symptom.** In the largest library (63,543 lines) 75 % of the bytes are
  leading spaces: lines run 90 levels deep. Predeclared SSA values (`float t1 = float(0);`) are
  9.5 %, `#pragma METAL fp math_mode` blocks 6 %.
- **The nesting comes from unrolling.** The depth grows by one every ~538 lines, each step one copy
  of the same body: a loop of up to 64 iterations with a data-dependent `break`, unrolled into 64
  ifs, each nested in the last.
- **Why it unrolls.** KosmicKrisp sets no `max_unroll_iterations`, so `nir_opt_loop_unroll`
  unrolls no loop by size. But a loop the SPIR-V marks with `LoopControl Unroll` (HLSL `[unroll]`)
  is unrolled whatever its size (`check_unrolling_restrictions`). Logging every hinted loop while
  the `h1b` corpus replayed:

  | trip count | exact | NIR cost | cost × trips | times seen |
  |---|---|---|---|---|
  | 64 | no (may break earlier) | 692 | 44,288 | 9 |
  | 4 | yes | 9–365 | ≤ 1,460 | 26 |
  | 1, 2, 3, 6, 16 | yes | 32–332 | ≤ 720 | 7 |
  | unknown | — | — | (not unrollable) | 3 |

- **Without hints** (every hint dropped, an experiment): the largest library is 927,867 bytes and
  none is over 1 MB.
- **The other candidates, checked in the same corpus:** none makes MB-sized MSL.
  - Indirect local arrays become real `scratch` arrays (105 libraries, at most 1,152 bytes), not
    if-ladders (`nir_lower_vars_to_scratch` takes arrays over 32 bytes first).
  - `nir_opt_large_constants` already runs: 173 libraries have a `constant_data` table, at most
    320 words.
  - Loops without a hint stay loops (1,000 libraries have one).
  - The largest libraries after the change are compute kernels of 0.5–0.93 MB, which never go
    through the unroll pass. They built on the phone (no FAIL for them in s1).
- **A synthetic shader** (`shaders/unroll-hint.frag`, the shape of RDR2's: a hinted 64-iteration
  lighting loop with an early `break`, plus a hinted 4-iteration loop) gives 1,505,787 bytes of
  fragment MSL with every hint kept and 10,252 bytes with 0060.

## 4. The patches

- **0060, costly unroll hints are dropped, on by default.** Before each `nir_opt_loop_unroll` in
  `nir_opts`, a loop whose `instr_cost` × trip count is over 4096 loses its hint. The limit sits
  between 1,460 (the largest hinted loop that unrolls in RDR2) and 44,288. Geometry shaders keep
  their hints. `MESA_KK_DEBUG=unroll_hints` keeps every hint and keys the shaders apart.
  - **Why default on:** the semantics are the same (unrolling is an optimisation), and only loops
    over the limit change. On `h1b`, 2,221 distinct MSL before and after; exactly 9 differ (the nine
    above, now 66,592–308,357 bytes, 1.32 MB in all instead of 56.3 MB), and the other 2,212 are
    byte for byte the same, so their Metal caches stay warm. The same holds for `rdr2-sga`,
    `-ingame` and `-ingame2` (9 of 2,215–2,220 change) and `rdr2-vkd3d-h3` (none of 109).
    `MESA_KK_DEBUG=unroll_hints` reproduces the old 2,221 MSL exactly.
  - **The risk:** a dropped hint's loop may run slower than the unrolled one would. Here those
    loops did not build at all.
- **0061, `MESA_KK_DUMP_MSL_MIN_KB=N`, off by default.** A Metal build (render or compute) whose
  MSL is over N KB writes, before Metal gets it, into `kk-dump` beside `MESA_SHADER_CACHE_DIR`
  (on the phone `Library/Caches/kk-dump`):
  - `MSL.STAGE.metal` per stage, and `MSL.STAGE.spv`, the stage's SPIR-V as the game gave it;
  - `MSL.txt` last: kind, the full MSL hash, each stage's MSL bytes and entry point, SPIR-V bytes,
    entry point and specialization constants (`ID:hex`).
  - MSL is the 16 hex digits of `[kk-compile]`'s `msl=`. A hash already there is not written
    again, and nothing more once the directory holds 200 MB (logged once). Each dump logs
    `[kk-dump] KIND msl=… bytes=…`. A dump is written before the build, so a build that is killed
    still leaves it.
  - The Vulkan runtime remembers, per thread, the stage create infos of the pipeline being
    created; `vk_pipeline_creating_stage_spirv` reads a stage's SPIR-V from them.
- **0062, the known-fail list, on by default** (the supervisor's request). A build that fails with
  the compiler service interrupted appends its MSL hash to
  `MESA_SHADER_CACHE_DIR/kk-known-fail-UUID.txt`. Once an MSL has failed so twice, in one launch or
  over several, its later builds fail at once with `VK_ERROR_INVALID_SHADER_NV`, the result the
  failed builds returned, and log
  `[kk-compile] skip known-fail render msl=… interrupted=2 src=… tid=…`.
  - UUID is the device's `pipelineCacheUUID` (driver build, GPU, MSL version): files of another
    UUID are deleted when the list is read, so any Mesa change empties it, and changed MSL has
    another hash. Settings › Storage, which clears `kosmickrisp/`, clears it too.
  - `MESA_KK_DEBUG=no_known_fail` turns it off: everything builds and nothing is recorded.
  - **The risk:** an MSL that would build on a calmer phone (less memory pressure) stays skipped
    until one of those changes; its draws stay missing, as after a failed 40 s build. With 0060
    RDR2's three known failures have new MSL, so the list matters only for failures still left.
- **Not done: terser MSL.** Dropping indentation would remove 26 % of the corpus's bytes after
  0060, and predeclarations are another 24 %. It would change every library's MSL, so every
  Metal cache would go cold once, and nothing shows that source bytes, rather than the code's
  size, drive the compiler's memory.

## 5. Host checks

- **`build/stages/mesa.sh ROOT hosttest`** on mesa 0001–0062 (scratch root in the copy's build
  area): all 35 cases `ok` (34 before, plus `unroll-hint`), 140 MSL libraries, `zink-host-test: ok`.
  - `ok unroll-hint`: the pipeline's fragment MSL has exactly one loop (the 64-iteration one; the
    4-iteration one unrolled). With `MESA_KK_DEBUG=unroll_hints` the same case fails with
    "unroll-hint: 0 loops in the MSL, not 1", and the fragment MSL is 1,505,787 bytes.
  - The other 139 libraries total 2,904,331 bytes before and after.
  - `MESA_KK_DUMP_MSL_MIN_KB=8`: 23 pipelines dumped, and the dumped `.frag.spv` of
    `unroll-hint` is byte for byte `unroll-hint.frag.spv`.
  - The known-fail list: two launches with `KK_MOCK_INTERRUPT_BUILDS=1` fail the first pipeline as
    interrupted (`msl=3c71e4ab1bd1614e`); the third launch logs
    `skip known-fail render msl=3c71e4ab1bd1614e interrupted=2` and fails that pipeline; with
    `MESA_KK_DEBUG=no_known_fail` everything builds.
  - The compile retry run (0053) still retries 2 interrupted builds.
- **The replays** above, on 0060 alone and on 0060–0062 (the same 2,221 MSL).
- **`./pp build` (dev):** `out/20261020-121824-8eb6200e/Playport-26.5-8eb6200e.ipa` in the copy's
  build area, sha256 `8eb6200e451f00e7339c7dfd0040233fcf540da35ea690d2fe3498f01e9bf4c3`,
  562,660,323 bytes, `verify-ipa: 89 checks passed`. KosmicKrisp is staged as `982abcd37397171e`
  (14,339,472 bytes); its strings include `[kk-dump]`, `skip known-fail`, `unroll_hints` and
  `no_known_fail`. The mesa build had no warning in the changed files.
- **Build records:** the copy's build changed only `lib/libdxmt_combined.a` and
  `lib/libidevice_ffi.a` (the copy's path, decision 0117); they keep main's values. KosmicKrisp
  has no row.
- **`./pp test --quick`:** all passed (names, secrets, patches and trailers, `tools/tests`, the C tests).

## 6. Owed on the phone (main checkout, after the branch is rebased onto `main`)

1. **Hollow Knight** (`app-367520`) through first frame+10, for 0060–0062 (its Vulkan route needs
   no setting).
2. **RDR2, defaults** (the s1 route, `graphics=vulkan`), with the dump on:
   `--settings 'app-1174180:{"graphicsOptions":"MESA_KK_DUMP_MSL_MIN_KB=1024"}'`, merged with the
   run's usual RDR2 settings.
   - In the host log: `grep -E '\[kk-compile\] .*FAIL|skip known-fail|\] known-fail|\[kk-dump\]'`.
     Expected: no `FAIL` with `bytes=` over 1 MB, and the `[kk-dump]` lines name what is still over
     1 MB.
   - In the syslog: `grep -c 'killing_highwater_process.*MTLCompilerService'`, against s1's 15.
   - The pull: `./pp phone ls Library/Caches/kk-dump`, then for each file
     `./pp phone pull Library/Caches/kk-dump/NAME DIR`. A `.spv` with its `.txt` replays on the
     host mock.
   - The first launch after the install translates every pipeline again (a new build ID) and
     builds the nine new MSL; the other MSL hit Metal's cache.
3. **The A/B:** the same route with
   `"graphicsOptions":"MESA_KK_DEBUG=compile,memory,unroll_hints,no_known_fail MESA_KK_DUMP_MSL_MIN_KB=1024"`
   (a `MESA_KK_DEBUG` here replaces the dev build's own `compile,memory`, decision 0060). That
   restores the old unrolling and turns the list off; its dumps are the phone's 6 MB shaders, named
   by their `msl=`. Compare the `FAIL` lines and their `ms=`, the kill count, and the frames where
   the shaders draw.
4. **The known-fail list on its own:** in the A/B arm without `no_known_fail`, the second
   interrupted build of an MSL logs `known-fail`, and later attempts log `skip known-fail` instead
   of a 40 s `FAIL`.

## 7. Unverified

- That the nine host MSL are the phone's three exactly (sizes within 0.01 %, hashes not matched).
- That Metal compiles the 67–308 KB versions within the 150 MB limit, and how fast the loop runs
  against the unrolled form; Metal's own compiler may unroll it again.
- That AFC reaches `Library/Caches` on the phone: `pp phone pull` vends the whole container
  (`documents_only=False`), but no pull from there was made.
- The known-fail list's effect on a game that retries a failed pipeline differently.
