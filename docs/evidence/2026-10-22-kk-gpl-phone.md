# KosmicKrisp graphics pipeline library on the phone: G0's baseline and G5 (PLA-424)

**Linear:** [PLA-424](https://linear.app/playportdev/issue/PLA-424). **Plan:**
[kk-graphics-pipeline-library](../plans/2026-10-21-kk-graphics-pipeline-library.md). **Host
results:** [2026-10-21-kk-gpl-host](2026-10-21-kk-gpl-host.md).
**Patches:** `patches/mesa` 0096–0101, all behind `MESA_KK_EXPERIMENTAL=gpl`.

## IPA and runs

- **IPA (dev):** `.work/out/20261022-010839-eb64cb9a/Playport-26.5-eb64cb9a.ipa`, SHA256
  `eb64cb9a1af1492f4129c5fff019fcc2546dd5304d8d101c5ff338afb5070c13`. It was built in the main
  checkout from `dev/kk-gpl-phone` rebased onto `main` `6871884`, and it passed 89 IPA checks.
  The build changed no committed build record. `pp install` upgraded the app in place.
- **Runs:** in `$PLAYPORT_BUILD/ui-runs/<run>`. All are Hollow Knight (`app-367520`) on the
  defaults of decision 0153 (Vulkan, 720 rows, 60 FPS). The Graphics options were set for the
  session only, through `pp ui --settings 'app-367520:{"graphicsOptions":"…"}'`
  ([0137](../decisions/0137-graphics-options-set-any-variable.md)).

| Run | Graphics options | Until | First frame | Result |
| --- | --- | --- | --- | --- |
| `20261022T011042` | none (smoke gate) | first-frame+10 | +11.39 s | title menu |
| `20261022T011205` | `MESA_KK_DEBUG=compile` | first-frame+20 | +11.13 s | title menu; no `[kk-compile]` line |
| `20261022T011337` | `MESA_KK_DEBUG=compile MESA_SHADER_CACHE_DISABLE=true` | first-frame+20 | +10.93 s | title menu; no `[kk-compile]` line |
| `20261022T011620` | `MESA_KK_DEBUG=compile,memory MESA_SHADER_CACHE_DISABLE=true` | first-frame+20 | +11.15 s | title menu; no `[kk-compile]` line |
| `20261022T011738` | `MESA_KK_EXPERIMENTAL=gpl MESA_KK_DEBUG=compile,memory` | first-frame+20 | +10.88 s | title menu; first flag-on launch |
| `20261022T011921` | the same | first-frame+20 | +10.22 s | title menu; second flag-on launch |

Each run's `screen-stop.png` shows Hollow Knight's title menu: the logo, the five menu items and
the particles. The flag-on screenshots look the same as the flag-off one. They stay in the run
directories.

## Results

- **DXVK uses GPL with the flag on.** Each of the two DXVK devices logs
  `graphicsPipelineLibrary : 1` and `Graphics pipeline libraries supported`. With the flag off
  the lines are `graphicsPipelineLibrary : 0` and `Graphics pipeline libraries not supported`.
- **No `link FAIL`, and nothing was skipped.** `failed=0` in the `[kk-compile] totals` line of
  both flag-on launches, and the menu rendered.
- **No fast link happened.** In both flag-on launches, every one of the 26 links was
  `[kk-compile] link full fallback=sample-mask` (count 1 to 26). No `link separate` or
  `link separate-vertex` line was logged. So GPL as built gives Hollow Knight nothing yet. It
  costs more at the first launch (below). This blocks G6.
- **Why every link falls back (from the code; the mask value is not logged).** DXVK gives the
  pipeline the D3D sample mask cut to the sample count:
  `msSampleMask = state.ms.sampleMask() & ((1u << msInfo.rasterizationSamples) - 1)`
  (`src/dxvk/dxvk_graphics.cpp:384` at the `dxvk` pin). That is `0x1` for a single-sample
  target. G3's check in `kk_gpl_fragment_blocker` (`kk_shader.c`, `patches/mesa` 0098) falls
  back on `state->ms->sample_mask != UINT16_MAX`. So every mask that covers all the samples
  there are, but not 16 of them, falls back. The fix would compare the mask to the samples that
  exist. It is not made here: G5 does not fix runtime bugs.
- **The disk cache works for library shaders.** The second launch logged `gpl vertex deserialized`
  16 times and `gpl fragment deserialized` 18 times, with no `gpl … built` line except the one
  empty fragment shader per device. Deserializing took 2.2 ms (vertex) and 0.8 ms (fragment) in
  total. The 26 fallback links then took 35.7 ms in total (the longest 4.9 ms): their whole
  pipelines also came from the cache. Totals line:
  `[kk-compile] totals translated=10 (15 ms) deserialized=54 (16 ms) metal=10 ms failed=0`.
- **Counts (`[kk-mem]`, both flag-on launches, at the menu):**
  `shaders=149 pipelines=58 msl=0.7 | … | gpl sources=34 shaders=35 libraries=35 links=26`.
  That is 34 DXVK shaders plus the empty fragment shader, as G4 expected. The flag-off launch
  has `shaders=62 pipelines=32 msl=0.2`: with the flag on, the libraries and the fallback
  pipelines are kept beside DXVK's optimized pipelines.
- **Not seen:** `[kk-compile] link totals` (printed every 64 links, and there were 26) and
  `[kk-mem] gpl device finish` (`pp ui` ends the app before the device is destroyed).

### First flag-on launch (`20261022T011738`, cold for library shaders)

The library shaders' cache key is new (`kk-gpl-separate-v4`), so this launch compiled them all.

| What | Count | Total | Range |
| --- | --- | --- | --- |
| `gpl vertex built` (library creation) | 16 | 3,348 ms (`library_ms` 3,271) | 70–415 ms |
| `gpl fragment built` (library creation) | 18 | 4,990 ms (`library_ms` 4,984) | 171–438 ms |
| `link full fallback=sample-mask` over 20 ms (at the draw) | 18 | 3,388 ms | 147–484 ms |
| `link full fallback=sample-mask` under 20 ms (the pipeline was already linked) | 8 | 8.7 ms | 0.8–1.4 ms |

The 18 slow fallbacks are the 18 `[kk-compile] render` lines, all on one thread
(`tid=1043848`), `src=translated`. Their steps add up to `vs=226 fs=2640 pipe=503` ms. The vertex
Metal library took about 0 ms in 17 of them and 225 ms in one, so Metal's own cache had the
vertex MSL; the fragment MSL was new to it. Totals line:
`[kk-compile] totals translated=18 (2776 ms) deserialized=46 (9 ms) metal=2769 ms failed=0`.

## G0's baseline, flag off

- `MESA_KK_DEBUG=compile` logged no `[kk-compile]` line at the menu: no Metal build over 20 ms,
  and fewer than 64 shaders translated or read from the cache (the `totals` line comes every
  64). `[kk-mem]` with `memory` gives `shaders=62 pipelines=32`.
- **The logging threshold has no variable.** The plan asked for the threshold "lowered", but
  `kk_note_metal_build` logs a successful build only over a fixed 20 ms (`patches/mesa` 0052).
  No patch was added for G0. The three flag-off runs used the threshold as it is.
- **`MESA_SHADER_CACHE_DISABLE=true` changed nothing visible.** It is Mesa's switch to turn the
  disk cache off, set to get cold builds. Whether it took effect is not known: no line counts the
  cache's reads below 64 events. Metal's own cache may also have had these MSL. So the flag-off
  numbers are "no build over 20 ms at a warm Hollow Knight menu", not a cold split.
- **The split of small DXVK shaders comes from the flag-on launch instead.** The 18 whole-pipeline
  builds of Hollow Knight's shaders that Metal had not seen spent 2,866 ms in libraries (85 %) and
  503 ms in the Metal pipeline (15 %). That is close to RDR2's 87 % and 13 %. Built on their own,
  Hollow Knight's libraries took 70–438 ms each.

## Not run

- **Portal 2** (`app-620`) is not installed. The Library shows `Installed · 2`: Hollow Knight and
  Red Dead Redemption 2. It was not installed (7.7–7.9 GB free), so the chapter-load hitch
  comparison flag off against on was not made.
- **A D3D12 title.** The only one installed is RDR2. It is not a G5 title in the plan, and starting
  it on D3D12 would change its saved graphics setting. vkd3d-proton also logs nothing about GPL
  without trace logging. Not checked.
- **GPU time flag on against off.** With every link a full fallback, the flag-on draws run the
  same monolithic pipelines as flag off. A measurement would not show the runtime vertex fetch
  or the fixed-function blend. Not measured.
- **Play past the menu.** Only the title menu was reached in each run.

## Phone

80 % battery on external power, 7.7–7.9 GB free, unattended mode on. The app was not uninstalled
and no title was installed.

## G5b: the sample-mask fix (mesa 0100) and Hollow Knight played with the flag on

**Patch:** `patches/mesa` 0100. A link's static sample mask counts as all ones when it has the
bit of every rasterization sample (`mask & BITFIELD_MASK(samples) == BITFIELD_MASK(samples)`), so
DXVK's `0x1` at one sample no longer forces a whole pipeline. The separately compiled fragment
shader never lowers a sample mask, and a Metal pipeline has no sample mask of its own, so such a
link draws as one with `0xffff`. The link key hashes the draw's whole state, mask included, so
nothing else changes. The whole-pipeline path (`kk_lower_fs`, the static sample mask lowering)
still compares with `0xffff` and is unchanged, so flag-off MSL is byte-identical; it lowers DXVK's
`0x1` at one sample into every fragment shader, which is harmless but not needed (follow-up, not
changed).

**Host** (`build/mesa-host-test/run.sh`, main checkout's `.work/run/mesa`): exit 0.
- New links in `check_gpl`: a fragment shader and a fragment output library with `pSampleMask`
  `0x1` at one sample fast-link (`ok gpl fast sample-mask 0x1 of 1 rgba8: MSL libraries at link
  0, at draw 0`). With `0x5` at four samples, drawn into a 4-sample target, the link still falls
  back (`link full fallback=sample-mask count=1`, `at draw 2`).
- Without 0100 the same test fails: `gpl fast sample-mask 0x1 of 1 rgba8: MSL libraries at link
  0, at draw 2`.
- Against a baseline copied before any change: flag-off MSL 158 of 158 and Zink 25 of 25
  byte-identical. Flag on, all 204 earlier `msl-gpl` files come back in the same order and
  bytes. The 4 new ones are the two new fragment libraries (byte-identical to the existing
  fragment library's MSL) and the `0x5` fallback's whole pipeline (with `[[sample_mask]]`).
  `msl-compile.sh` was not run: no new MSL text besides that whole pipeline from the unchanged
  path.

**IPA (dev):** `.work/out/20261022-013602-0afe7d74/Playport-26.5-0afe7d74.ipa`, SHA256
`0afe7d74d19b8399c214139446050bc0c6f09100af2e8064c57f12ee2a68f632`, 89 IPA checks passed, no
build record changed, `pp install` upgraded in place.

| Run | Graphics options | Route | First frame | Result |
| --- | --- | --- | --- | --- |
| `20261022T013805` | none (smoke gate) | first-frame+10 | +10.98 s | title menu |
| `20261022T013918` (`on1`) | `MESA_KK_EXPERIMENTAL=gpl MESA_KK_DEBUG=compile,memory` | pad route | +10.87 s | gameplay; **40 `link FAIL`** |
| `20261022T014505` (`off1`) | none | pad route | +11.00 s | gameplay |
| `20261022T014953` (`off2`) | `MESA_KK_DEBUG=compile,memory` | pad route | +11.09 s | gameplay |

The pad route, under one `pp phone lock` each:
- `pp ui --pad --play app-367520 --until first-frame+25 --leave-running --shot`;
- `pp pad push hk-new-game --wait` (profile 1's save, King's Pass), then `hk-walk --wait`;
- `hk-roam` for 90 s;
- `pp phone log`, `pp phone kill`.

About 4 minutes of play each. The screenshots after each script and the pulled `s1-host.log`
are in `$PLAYPORT_BUILD/agent-notes/kk-gpl/g5b/<run>/` (not committed).

### Flag on: every fast link fails in Metal

- `on1` is the only flag-on launch. Flag-on runs stopped there, as the G5b task required on a
  `link FAIL`.
- DXVK: `Graphics pipeline libraries supported` (two devices). `graphics options:
  MESA_KK_DEBUG=compile,memory MESA_KK_EXPERIMENTAL=gpl`.
- 0100 works: no `link full fallback` line at all (G5 had 26 of 26 `sample-mask`).
- **But all 40 links that now link apart fail.** 40 `[kk-compile] link FAIL ms=… stages=0x11`
  (812 ms in total, 8 over 20 ms, the longest 104.5 ms) and no `link separate`. Each is preceded by
  `Failed to create MTLRenderPipelineState: Vertex shader writes point size but
  inputPrimitiveTopology is MTLPrimitiveTopologyClassTriangle` and
  `[kk-compile] render FAIL … step=pipeline err=AGXMetalG18P:3` (34 distinct MSL hashes).
  `[kk-compile] totals translated=2 (187 ms) deserialized=62 (14 ms) metal=500 ms failed=26`.
- **Cause, from the code:** G2's vertex shader compiled on its own always writes a point size
  (`kk_lower_nir`, "always writes a point size, so that it can draw any topology", mesa
  0097). The pipeline descriptor sets `inputPrimitiveTopology` to the draw's class
  (`vs->info.vs.topology`, "Layered rendering in Metal requires setting primitive topology
  class"). Metal refuses that pair for triangles. The host mock does not check it, and G5 never
  linked apart (every link fell back), so this is the first separate link on Metal. The host
  library MSL shows the same: the vertex libraries 0158, 0160 and 0164 all have `[[point_size]]`.
- Not seen: `link separate`, `link separate-vertex`, `link totals` (40 links, under 64),
  `gpl … deserialized` (0100's build changed the driver's build ID, so the library shaders were
  cold again) and `[kk-mem] gpl device finish`.
- Library compiles at library creation: `gpl vertex built` 23 (1,007 ms, 1.4–216 ms), `gpl
  fragment built` 31 (2,963 ms, 0.1–389 ms), `gpl empty-fragment built` 1.
- `[kk-mem] … shaders=161 pipelines=54 msl=0.9 | … | gpl sources=54 shaders=55 libraries=55
  links=40`. Flag off (`off2`): `shaders=106 pipelines=54 msl=0.3`.

### Rendering, flag on against off

At the same three places, flag on (`on1`) and flag off (`off1`, `off2`) look the same:
- after `hk-new-game`, the Knight standing in King's Pass' opening cave, with the HUD (soul
  vessel, five masks), the grass and the particles;
- after `hk-walk`, the lumafly room, the floating platforms and the dark overhang on the right,
  the "Sound and Score by Christopher Larkin" credit;
- 90 s into `hk-roam`, the Knight under the overhang.

The differences are the run's state: the geo count (3–4 against 2) and the masks lost. No
missing sprite, wrong blend or broken geometry was seen. This shows nothing about GPL's
rendering, though. With every fast link failed, the frames come from DXVK's optimized (whole)
pipelines, which `deserialized=62` read from the cache. A failed link's draws are skipped until
then, between screenshots. The fixed-function blend and the runtime vertex fetch have still not
drawn on the phone.

### First frame, compile totals, frame rate

- First frame: +10.87 s on, +11.00 s and +11.09 s off, +10.98 s smoke gate.
- `[kk-compile] totals` off (`off2`): `translated=0 (0 ms) deserialized=64 (13 ms) metal=13 ms
  failed=0`. On: `translated=2 (187 ms) deserialized=62 (14 ms) metal=500 ms failed=26`, plus
  3,970 ms of library compiles on DXVK's workers.
- Frame rate from the `[frames]` counter (a line every 16 frames): 60.0 FPS over the last 100 s
  in all three. Over the 241 s, 56.7 on against 57.0 off. Gaps over 0.4 s between `[frames]`
  lines: 36 on against 32 (both off runs), the longest 2.01 s against 1.49 s. That is loading and
  the cinematic in all runs; GPU time was not measured.

### Not run

- The second flag-on launch (the cache path) and the longer flag-on play: stopped on `link FAIL`.
- GPU time on against off (`pp perf`): nothing to measure until a fast link draws.
- Portal 2 and D3D12, as in G5.

## G5c: separate links with an unspecified topology class (mesa 0101), Hollow Knight twice with the flag on

**Patch:** `patches/mesa` 0101. A link of a vertex shader compiled on its own (both separate link
paths, `kk_gpl_link_libraries` and `kk_gpl_link_separate`) now leaves the Metal pipeline's
`inputPrimitiveTopology` unspecified when the vertex shader writes a point size and the draw's
class is lines or triangles (`kk_gpl_link_topology`). Point lists keep the point class. Whole
pipelines are unchanged: they still set the class and drop the point size for lines and
triangles.

**Why this option.** Of the three options in the G5c task, it is the most conservative:
- (a) the unspecified class is Metal's default for a render pipeline descriptor;
- it changes no MSL, so it adds no compile and no new library;
- (b) a point-size function constant would cost a backend compile at every link;
- (c) a second vertex library would double the vertex library compiles and their memory.

Metal needs a class for layered rendering (KosmicKrisp's own comment where the class is set). So
a vertex shader that writes a layer or viewport index as well as the point size, drawn as lines
or triangles, falls back to the whole pipeline (`fallback=point-size-layer`). Multiview is covered
by the same rule: its lowering writes the layer. Hollow Knight never hits it (0 such lines).

**Other separate-link rules of Metal, read in the code (none changed):**
- *Varyings by `[[user]]` name and type:* a fragment input the vertex shader does not write
  falls back (`varying-unwritten`), and so does a type mismatch (`varying-type`, or for a
  fragment shader compiled at link, `kk_gpl_fs_match`). Extra vertex outputs are allowed.
- *`index(1)` against Source1 blend factors:* `dual-source` falls back unless the factors and the
  shader's second output agree, with one colour attachment.
- *Alpha to coverage:* it falls back without colour output 0. The raster sample count comes from
  the draw's multisample state, as for whole pipelines.
- *Depth write without a depth attachment, logic op, non-native formats, output type against
  format:* all fall back.
- *Not checked:* a stencil export without a stencil attachment, and a colour output with no
  attachment format. The phone showed no failure of either (0 `link FAIL`).

**Host** (`build/mesa-host-test/run.sh`): exit 0.
- **The mock now validates as Metal does** (`make-mock-bridge.py`):
  - a library records whether its MSL has `[[point_size]]` or `[[render_target_array_index]]`;
  - a function descriptor and the pipeline descriptor's vertex function carry that, and the
    descriptor records its topology class;
  - `mtl_new_render_pipeline` fails, with an error as Metal returns it, for a point size with the
    line or triangle class (the phone's failure), or a layer with an unspecified class.
- **New links in `check_gpl`:**
  - a point-list vertex input library links fast with the point class (`ok gpl fast points
    rgba8: MSL libraries at link 0, at draw 0`);
  - a vertex shader that writes `gl_Layer` (`shaders/gpl-layer.vert`) falls back (`link full
    fallback=point-size-layer count=1`, `at draw 2`).
  - `run.sh` now expects 5 vertex libraries built, 10 `link separate` and that fallback.
- **The test fails without the fix:**
  - without 0101's mesa change, 9 `kk-mock: Failed to create MTLRenderPipelineState: Vertex
    shader writes point size but inputPrimitiveTopology is a line or triangle class` and a
    `link FAIL`: every fast triangle link, as on the phone;
  - without the `point-size-layer` fallback, the layer link fails (`Vertex shader writes a layer
    but inputPrimitiveTopology is unspecified`).
- **MSL against a baseline copied before any change:**
  - flag off: 158 of 158 byte-identical; Zink: 25 of 25 byte-identical;
  - flag on: all 208 earlier `msl-gpl` files come back in order and byte for byte. The 3 new ones
    are the layer vertex library (`[[point_size]]` and `[[render_target_array_index]]`) and its
    fallback's whole pipeline (vertex without a point size; fragment identical to an earlier one).
  - `msl-compile.sh` (Metal tools under Wine) compiled all 3: "3 files, 3 compiled, 0 failed".
- **Checks:** `pp test` passed; `pp names` and `pp secrets` are clean.

**IPA (dev):** `.work/out/20261022-021330-0712b0ce/Playport-26.5-0712b0ce.ipa`, SHA256
`0712b0cec80845d5147f6aa823625c270e07ecf1134e183f6a4959308ae00f56`, 89 IPA checks passed, no
build record changed, `pp install --no-build` upgraded in place (30 s, container kept).

| Run | Graphics options | Route | First frame | Result |
| --- | --- | --- | --- | --- |
| `20261022T021448` | none (smoke gate) | first-frame+10 | +10.37 s | title menu |
| `20261022T021946` (`on1`) | `MESA_KK_EXPERIMENTAL=gpl MESA_KK_DEBUG=compile,memory` | pad route | +11.16 s | gameplay; 40 `link separate`, 0 `link FAIL` |
| `20261022T022518` (`on2`) | same | pad route | +11.24 s | gameplay; 40 `link separate` (cache path), 0 `link FAIL` |
| `20261022T023011` (`off`) | `MESA_KK_DEBUG=compile,memory` | pad route | +11.10 s | gameplay |

- **Route:** the same pad route as G5b, with G5b's script.
- **Logs and screenshots:** in `$PLAYPORT_BUILD/agent-notes/kk-gpl/g5c/<run>/`, not committed.
- **Flag-off reference:** `off` on this IPA, and G5b's `off1` and `off2` at the same places.
- **One launch that did not happen:** a first attempt with a malformed `--settings` argument made
  `pp ui` exit 2 before launching (the pads then pushed into nothing). Its directory is
  `on1-badarg`; it is not counted.

### Flag on: every separate link builds

- **Flag in effect:** `graphics options: MESA_KK_DEBUG=compile,memory MESA_KK_EXPERIMENTAL=gpl`;
  DXVK reports `Graphics pipeline libraries supported` (two devices).
- **`on1`, the first launch after the driver build changed:**
  - 40 `[kk-compile] link separate ms=… stages=0x11`, 0 `link separate-vertex`, 0 `link full`,
    0 `link FAIL`, 0 `render FAIL`, no `Failed to create MTLRenderPipelineState`;
  - the links took 1,164 ms in all. 23 took over 20 ms; the longest took 101.9 ms. That is Metal
    building the pipeline from the two libraries;
  - library compiles: `gpl vertex built` 23 (103 ms in all, at most 11.6 ms), `gpl fragment built`
    31 (24 ms), `gpl empty-fragment built` 1. That is a tenth of G5b's (1,007 ms and 2,963 ms) for
    the same MSL. This is likely Metal's own shader cache on the phone (inferred, not
    measured);
  - `[kk-compile] totals translated=2 (6 ms) deserialized=62 (14 ms) metal=773 ms failed=0`.
- **`on2`, the second launch:**
  - every library shader came from the pipeline cache: `gpl vertex deserialized` 23 (3 ms in all)
    and `gpl fragment deserialized` 31 (1.5 ms). The empty fragment shader is built again
    (0.4 ms);
  - 40 `link separate`, 40 ms in all, the longest 2.3 ms, 0 `link FAIL`. Metal's pipeline cache
    now has the cold run's pipelines;
  - totals lines `translated=0 (0 ms) deserialized=64 (19 ms) metal=13 ms failed=0`, then
    `deserialized=128 (33 ms) metal=25 ms failed=0`.
- **Not seen:**
  - `link totals`: the route makes 40 links in each launch, and it prints every 64;
  - `[kk-mem] gpl device finish`: the app is killed, not closed.
- **Memory, last `[kk-mem]` line:**
  - on: `shaders=241 pipelines=94 msl=1.9 | … | gpl sources=54 shaders=55 libraries=55 links=40`;
  - off: `shaders=106 pipelines=54 msl=0.3`.

  With the flag on, DXVK still builds every optimized pipeline, so the links and libraries come
  on top.

### Rendering, flag on against off

- **Title menu at first frame +25 s** (`on1`'s `screen-stop.png`, during and after 20 of the
  links): the logo glow, the particles and the menu, as in the flag-off smoke gate.
- **After `hk-new-game`, after `hk-walk`, and 90 s into `hk-roam`:** `on1` and `on2` look like
  `off1`, `off2` and `off`:
  - the King's Pass cave with the HUD, grass and particles;
  - the lumafly room with its additive glows, the floating platforms, the dark overhang and the
    credit text.

  The differences are the run's state: geo 2–3, masks lost, the Knight's position, where the
  particles are, and the credit's fade.
- **No missing sprite, wrong blend, broken geometry or corruption** was seen in any screenshot.
- **Unlike G5b, the fast links now draw.** No link failed, so DXVK's first draws of each new
  pipeline used them: the runtime vertex fetch and Metal's fixed-function blend. The links fall
  at the title, the menu, the load and in King's Pass. What the screenshots cannot show is which
  frames at the shot times came from a fast link and which from DXVK's optimized pipelines,
  which replace them once built. So "renders the same" rests on five screenshots per run.

### First frame, frame rate, hitches

- **First frame:** +11.16 s and +11.24 s on, +11.10 s off, +10.37 s at the smoke gate (G5b:
  10.87–11.09 s).
- **Frame rate** from `[frames]` (a line every 16 frames):

  | | `on1` | `on2` | `off` |
  | --- | --- | --- | --- |
  | last 100 s | 60.0 | 60.0 | 60.0 |
  | whole 240 s | 57.1 | 57.2 | 57.0 |

- **Gaps between `[frames]` lines** (about 0.27 s at 60 FPS):

  | | `on1` | `on2` | `off` |
  | --- | --- | --- | --- |
  | over 0.3 s | 35 (21.0 s in all) | 36 (20.8 s) | 38 (21.9 s) |
  | over 0.4 s | 31 | 30 | 32 |
  | over 1 s | 2 | 2 | 2 |
  | longest | 1.84 s | 1.50 s | 1.50 s |
  | over 0.3 s from +60 s | 23 | 24 | 27 |

  Loading and the cinematic make most of them in every run. The cold links (up to 102 ms each)
  do not show as more gaps. Flag off has no stall to remove here either: its 64 whole pipelines
  all come from the pipeline cache (`deserialized=64`).
- **GPU time:** not measured. `pp perf` was not run, and the logs do not give it.

### Not run

- `link totals`: this route never reaches 64 links.
- GPU time on against off.
- A title whose pipelines are not cached, where GPL should cut stalls. Hollow Knight's are all
  cached with the flag off.
- Portal 2 and D3D12, as in G5.
