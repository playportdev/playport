# 0139: KosmicKrisp drops costly unroll hints and skips MSL that Metal's compiler service lost twice

**Status:** accepted, 2026-10-20, by the worker under the brief for PLA-364 (the MSL-size task:
"a change that is safe and clearly smaller is default ON"; the supervisor's known-fail list,
"default ON if safe"). Phone gates not run yet: both are on by default, and the main checkout's
Hollow Knight and RDR2 runs confirm them or turn them off (below).

## Context

- **What fails.** In RDR2's runs on the phone the same three fragment shaders (5.3–6.7 MB of MSL)
  failed in every run, 4 failures of 34–47 s each, with `MTLLibraryErrorDomain:3 interrupted=1`:
  iOS ended MTLCompilerService at its 150 MB ActiveSoft limit (13–15 kills a run).
- **Why they are so large.** Their SPIR-V marks a lighting loop of up to 64 iterations, which may
  break earlier, with an unroll hint. Mesa's `nir_opt_loop_unroll` unrolls a hinted loop whatever
  its size, into 64 ifs each nested in the last. The host replay of RDR2's captured pipelines
  shows nine such shaders, every MSL over 1 MB
  ([evidence](../evidence/2026-10-20-kk-msl-size.md)).

## Decision

- **Costly unroll hints are dropped** (mesa 0060). Before each `nir_opt_loop_unroll`, a loop whose
  NIR instruction cost times trip count is over 4096 loses its hint and stays a loop for Metal's
  compiler, as an unhinted loop already does. Geometry shaders keep theirs (poly counts their
  vertices from unrolled loops). On RDR2's captured pipelines only those nine MSL change
  (5.3–6.7 MB to 67–308 KB); the other 2,212 distinct MSL are byte for byte the same, so their
  Metal caches stay warm. `MESA_KK_DEBUG=unroll_hints` keeps every hint, for the A/B, and keys
  the shaders apart.
- **The known-fail list** (mesa 0062). A Metal build that fails with the compiler service
  interrupted records its MSL hash in `kk-known-fail-UUID.txt` in `MESA_SHADER_CACHE_DIR`; once one
  MSL has failed so twice, its later builds fail at once with the result the failed builds
  returned (`VK_ERROR_INVALID_SHADER_NV`) and log `[kk-compile] skip known-fail`. UUID is the
  device's `pipelineCacheUUID`, so any Mesa change empties the list, and a changed MSL has another
  hash. `MESA_KK_DEBUG=no_known_fail` turns it off.
- **The dump stays off** (mesa 0061, `MESA_KK_DUMP_MSL_MIN_KB`): it is a dev diagnostic.

## Costs and risks

- **A dropped hint may run slower** than the unrolled loop would have, where the unrolled one
  built at all. Only loops over the limit are affected; in RDR2 those are the nine that failed.
- **A known-fail MSL that would build on a calmer phone stays skipped** until Mesa changes, its
  MSL changes, or Settings › Storage clears the shader cache. Its draws stay missing, as they were
  when the build failed after 40 s.
- **Turning them off:** the Graphics options items above, for one game, in a dev build.
