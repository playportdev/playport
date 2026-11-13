# Cold shader compiles: where the time goes and why games freeze (2026-11-13)

**Linear:** [PLA-852](https://linear.app/playportdev/issue/PLA-852), Playable with no shader cache (decisions
[0185](../decisions/0185-kosmickrisp-builds-cheaper-msl-under-one-compile-budget.md),
[0186](../decisions/0186-dxvk-skips-a-draw-whose-pipeline-is-still-compiling.md),
[0187](../decisions/0187-pipeline-records-and-shader-preparation.md)). Log analysis of phone runs
and host measurements. **No phone gate was run for this record.**

## The runs

| Title | Run (s1-host.log) | IPA (dev) | API | Pipelines compiled | Compile time | Longest freeze |
| --- | --- | --- | --- | --- | --- | --- |
| THPS3+4 (Xbox) | `.work/pla485-thpslog` | `17ad7fed27937c84449527ccd201035972a1aaaf90842ad426107e18203d042e` | D3D11, DXVK | 1,088 (3 from cache) | 316 s, all on `dxvk-cs` | 125 s (114 s compiling) |
| Moonlighter 2 (Xbox) | `.work/ui-runs/20261112T150655` | same | D3D11, DXVK | 1,517 (120 from cache) | 269 s, all on `dxvk-cs` | 66 s |
| Witcher 3 4.x | `.work/ui-runs/pla835-w3x-gate2` | `bee5165c802d04f315bc0ab29f534cad9899dc6cebd1737801cf9cbd5a3fbc69` | D3D11, DXVK | 230 | 40 s | 26.9 s (24.6 s compiling) |
| Witcher 3 1.32 | `.work/ui-runs/pla837-nokey-repaired` | `671ca956da228dcd6f3d023c341c814d4bb703967e3b5734cee5ba784904910c` | D3D11, DXVK | 52 | 24 s | 7.4 s; single pipelines 1.4–3.2 s |
| RDR2 (comparison) | `.work/ui-runs/20261031T195324-rdr2-p605m1` | – | D3D12, vkd3d-proton | 1,702 | 824 s, about 25 % on each of 4 threads | barely stalls (compiles at load) |

- **The freezes are compiles.** In frame gaps over 1 s, `[kk-compile]` accounts for:
  - Moonlighter 2: 89 % of the gap time;
  - Witcher 3 4.x: 98 %;
  - Witcher 3 1.32: 70 %;
  - THPS's three longest freezes (77, 125 and 79 s): 72, 114 and 53 s of compiling.
- **One thread.** DXVK without `VK_EXT_graphics_pipeline_library` builds every whole pipeline
  synchronously on `dxvk-cs` at its first draw. Its compiler workers only prepare SPIR-V.
- **Not repeats.** THPS compiled 1,085 unique pipelines out of 1,088, and Moonlighter 2 1,514 out
  of 1,517.
- **QoS is not the cause.** Every DXVK thread ran at UI QoS 47 (`[xp-qos]`).

## Why the same games used to be cheaper: Apple's cache

- **Apple's cache made Mesa misses cheap.** Mesa's disk cache misses after every KosmicKrisp
  rebuild (the key holds the build id), but Apple's own Metal cache, keyed by MSL text, hit:
  - In October, Witcher 3 rebuilt 368 pipelines in 3.9 s, about 10 ms each, after rebuilds.
  - Re-seen MSL cost 23–62 ms per pipeline.
- **On 10–11 Nov Apple's cache went cold.** That is the night the phone reached 160 MB free
  ("iPhone Storage Full", and iOS purges `Library/Caches`) and iOS went from 27.2 to 27.2.1.
  Since then the same MSL costs 145–412 ms per pipeline:
  - Witcher 3: 162 pipelines first built on 2 Nov, now 261 ms each;
  - Moonlighter 2: 1,318 pipelines first built on 3 Nov, now 145 ms each.

  From 11 Nov 02:20 on, re-seen MSL hits again (22–50 ms).
- **The default MSL did not change.** 1,315 of Moonlighter 2's pipelines on 12 Nov have the same
  MSL hash as on 3 Nov, and GPL (PLA-424) is off in every run (`graphicsPipelineLibrary : 0`).

## Where a cold pipeline's time goes

**The split:**
- **Mesa (NIR passes, `nir_to_msl`): 2–4 %**, 3–17 ms a pipeline.
- **Metal's front end (`newLibrary`, MSL to AIR): 72–79 %**.
- **Metal's pipeline build (AIR to GPU): 21–28 %**:
  - THPS: median 66 ms, 79 s in all;
  - Moonlighter 2: median 15 ms.

**Apple's cache shares vertex libraries but rarely fragment ones** (a library build under 1 ms is a
hit; one cold session):

| Title | Vertex hits | Fragment hits | Distinct vertex / fragment MSL sizes |
| --- | --- | --- | --- |
| THPS | 70 % | 6 % | 281 / 920 of 1,051 pipelines |
| Moonlighter 2 | 62 % | 12 % | 503 / 941 of 1,457 |

**Whole-pipeline fragment MSL bakes in state** that Metal could set on the pipeline instead:
- blend (`nir_lower_blend`), write mask, alpha to coverage and alpha to one;
- exact attachment formats;
- the sample mask;
- cross-stage varying elimination.

**The front end's fixed cost is texture type instantiation.** Apple's compiler instantiates
`metal_stdlib`'s texture class templates once per distinct texture type a library names.

Host measurements: Apple's Metal tools 6.2 under Wine, `-std=metal4.0`, `-ftime-trace`:

| Library | Total | Texture class instantiation | LLVM |
| --- | --- | --- | --- |
| a 15 KB fragment body, no textures | 38 ms | 0.7 ms | 3.7 ms |
| the same plus one unused `texture2d<float>` | 84 ms | 44.5 ms | – |
| the same plus `texture2d<float>`, `texture2d<int>`, `depth2d<float>` | 146 ms | 104 ms | – |

Notes on these numbers:
- A second declaration of the same type adds nothing.
- The phone agrees (PLA-437 probe, MSL 4.0): 10.5 ms without textures, 63 ms with one unused
  `texture2d<float>` ([0159's evidence](2026-10-22-kk-gpl-cold-cache.md)).
- Game libraries name 1.5–2.3 distinct texture types on average (DIRT 5 dump: 1,575 files; owner
  test dump: 1,385 files).
- Fragment libraries under 8 KB still take a median of 68–89 ms on the phone.

**Compiler builtins avoid the instantiation.** Writing the same shader with the compiler's
`__metal_texture_2d_t` and `__metal_sample_texture_2d_t`/`__metal_get_width_texture_2d_t` builtins
(what the header's members call):
- On the host it compiled in 34 ms instead of 116 ms.
- Its AIR has the same `air.sample_texture_2d` and `air.get_width_texture_2d` calls; only one
  TBAA tag and the handle load differ.
- Twenty real Portal 2 whole-pipeline fragment libraries rewritten that way: −47 ms per library on
  the host.

**Zero-initialised SSA temporaries cost superlinearly.** KosmicKrisp predeclares every temporary
as `T tN = T(0);`. Dropping the initialiser:

| RDR2 kernel | Before | After |
| --- | --- | --- |
| 822 KB | 748 ms | 474 ms |
| 536 KB | 488 ms | 388 ms |

- No measurable change below about 100 KB.
- Libraries over 200 KB are about 30 % of Moonlighter 2's and Witcher 3's render compile time, and
  5 % of THPS's.
- Upstream Mesa has the same change under review (merge request 45954).

**Parallel builds give about 2×, not N×.**
- RDR2 kept 3.5–3.8 builds in flight, each at 4.3 ms/KB against 2.3–2.7 ms/KB single-threaded.
- PLA-437 measured 1.7× throughput with 3 in flight.
- iOS ends MTLCompilerService above 150 MB ActiveSoft
  ([kk-compile-levers](2026-10-20-kk-compile-levers.md)).
- `parallel_stages` (mesa 0053) could save at most Σ min(vs, fs): 8 % of THPS's render compile time,
  5 % of Moonlighter 2's and 9–14 % of Witcher 3's.

**A Mesa cache hit saves little.** It saves only NIR to MSL, about 10 ms of a 100–300 ms
pipeline. What makes a pipeline cheap is Apple's cache.
