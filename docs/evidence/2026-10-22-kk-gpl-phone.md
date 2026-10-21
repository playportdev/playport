# KosmicKrisp graphics pipeline library on the phone: G0's baseline and G5 (PLA-424)

**Linear:** [PLA-424](https://linear.app/playportdev/issue/PLA-424). **Plan:**
[kk-graphics-pipeline-library](../plans/2026-10-21-kk-graphics-pipeline-library.md). **Host
results:** [2026-10-21-kk-gpl-host](2026-10-21-kk-gpl-host.md).
**Patches:** `patches/mesa` 0096–0099, all behind `MESA_KK_EXPERIMENTAL=gpl`.

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
