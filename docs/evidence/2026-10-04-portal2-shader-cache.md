# KosmicKrisp's shader cache for Portal 2

## Result

- **The Mesa disk cache is written and hit.** With mesa 0014–0016, a second Portal 2
  launch read every KosmicKrisp shader back from the disk cache and translated none:
  `translated=0 deserialized=128`, against `translated=64 deserialized=0` on the first
  launch after the install.
- **It does not change the frame time or the hitches.** Translating a shader from NIR
  to MSL took about 2.7 ms and reading it back about 0.26 ms, so a whole launch saves
  about 0.3 s, spread over the chapter load. No Metal library and pipeline build took
  more than 20 ms in either run. The 0.1–0.5 s hitches of the chapter load are there
  with a warm cache too, so they are not KosmicKrisp's shader compiles.
- **Hollow Knight** (DXMT, which this does not touch) passes `first-frame+10` on the
  same IPA.

IPA: `.work/out/20261004-195427-090b7613/Playport-26.5-090b7613.ipa` (dev). SHA256:
`090b761335b498b92573faa2395eda162d0c18bc11d85aba0e5eb590e1472054`. `pp build` passes
its 78 IPA checks. The phone was on external power, battery 32–36%.

The commit (`60dd46b`) differs from that build only in a stray `kk_shader.c.orig`
dropped from mesa 0015. Its IPA is
`.work/out/20261004-201408-7d7f5036/Playport-26.5-7d7f5036.ipa`, SHA256
`7d7f5036e0ac6dcae1e46753f05bc53fb24d4122df1e0775f2740a6cda98283b`, with the same
78 checks passing. It is installed, and the 720p run below used it. Hollow Knight has
not been played on it.

## What was missing

The draft only created the physical device's disk cache. That alone would never be
read: the Vulkan runtime consults it through a pipeline cache, and DXVK creates every
pipeline with `VK_NULL_HANDLE`. Other Mesa drivers then use their implicit device cache
(`vk_device.mem_cache`), but KosmicKrisp created none. So nothing was cached at all,
not even in memory: a shader that several pipelines share was translated for each.

Turning a cache on also makes the shader key matter. `kk_hash_graphics_state` is the
key under which the runtime gives one pipeline's shaders to another, and it left out
five pieces of state that the compile reads (input primitive class, point fill, the
depth clip/clamp lowering, alpha to coverage and alpha to one, the color attachment map).

## The patches

- **mesa 0014** adds those five to the vertex and fragment keys.
- **mesa 0015** creates the weakly referenced device cache in `kk_CreateDevice`, as hk
  and nvk do, and the disk cache in `kk_physical_device_init_pipeline_cache`. Its
  driver ID (also the pipeline-cache and shader-binary UUIDs) hashes the build ID, GPU
  family, MSL version, disabled workarounds and forced robustness. The creation's
  failure path now frees it as well.
- **mesa 0016** adds `MESA_KK_DEBUG=compile`. Every 64 shaders it logs running totals,
  `[kk-compile] totals translated=N (ms) deserialized=M (ms) metal=ms`, and it logs
  each Metal build over 20 ms with its wall-clock end and an MSL hash.
- **The app.** `wine_host.c` sets `MESA_SHADER_CACHE_DIR` to the container's
  `Library/Caches/kosmickrisp` (before HOME becomes the prefix) and
  `MESA_SHADER_CACHE_MAX_SIZE=256M`, and logs both (`Mesa shader cache: …`). The dev
  app sets `MESA_KK_DEBUG=compile` (`WineHostRuntime.start`, `#if !PLAYPORT_RELEASE`);
  the release app does not.

A disk-cache hit saves the NIR-to-MSL translation only. `kk_deserialize_shader` still
builds the Metal library and pipeline, and iOS's own Metal cache seems to make that
cheap: 128 builds took 33 ms in all.

## Host checks

`build/mesa-host-test` (mock Metal bridge, 24 pipelines) passes. The pipeline
`xfb-gs-streams-rast1` differs from `xfb-gs-streams` only in the rasterization stream,
which reaches the shader as per-draw data, so the device cache now gives it the earlier
pipeline's shaders. The test's "a vertex function writes transform feedback" check now
skips a pipeline that built no new library. The test runs with
`MESA_SHADER_CACHE_DISABLE=true`.

The same binary was also run twice by hand with a cache directory under `.work`,
counting calls with gdb breakpoints:

- run 1: `kk_compile_shaders` 21 times, `kk_deserialize_shader` none, 76 cache files;
- run 2: `kk_compile_shaders` none, `kk_deserialize_shader` 57 times.

Both runs built and drew all 24 pipelines.

## Two matched Portal 2 runs

`pp perf --title app-620 --secs 180 --pad first-frame+30:p2-cold-boot --pad
first-frame+75:p2-walk --cool 5`. The first run (`.work/perf-runs/p2c-cold`) was the
first launch after the install, so its Mesa cache started empty. The second
(`.work/perf-runs/p2c-warm`) came after 5 minutes' rest. DXVK's own cache was warm in
both (`Found cache file … 07d95fa26640a02f.dxvk.bin`). Both went nominal → fair →
serious.

| Run | KK shaders | FPS mean / p10 | Frame ms | GPU ms | Hitches ≥50 / ≥100 ms | Longest (all in the chapter load) |
| --- | --- | --- | --- | --- | --- | --- |
| cold | translated 64 in 172 ms; Metal 36 ms | 58.4 / 51.4 | 17.0 | 12.2 | 17 / 8 | 542, 358, 258 ms |
| warm | deserialized 128–191, the first 128 in 33 ms; Metal 33 ms | 58.0 / 51.0 | 17.1 | 11.4 | 19 / 7 | 475, 350, 267 ms |

The cold run's totals line comes every 64 shaders, so its count is 64 to 127. In the
chamber (60–180 s) neither run had a hitch of 100 ms or more. Their 30-second FPS
buckets match within 2 FPS.

## Follow-ups in the same session

- **The map change out of `sp_a2_laser_intro`** was dropped. Steering by pad from
  screenshots is too slow to make progress. The chamber was solved again from a save
  (`.work/p2m5`), but the elevator was not reached, and that transition is left to a
  person playing. Map loads themselves are covered by the chapter-select loads
  (chapters 1 and 2) and by the save and load from the main menu.
- **A long 720p run** on IPA `7d7f5036…`: `pp perf --title app-620 --secs 1800
  --settings '{"screen":"720"}' --pad first-frame+30:p2-cold-boot --pad
  first-frame+70:p2-walk` (`.work/p2t/long720`), on battery from 36%.
  - First frame came 5.9 s after Play.
  - The run was stopped by hand after about 23 minutes because the phone was needed.
    The person watching saw it hold a steady 60 FPS.
  - The app's log was not pulled, so this run has no per-frame numbers and no
    footprint series. What it kept is the following:
    - `thermalmonitord`'s `mTLL` went 3, 2, 1 (20:44–20:45), then 2, 3, 4 (20:48–20:52),
      then 6 (21:00:36).
    - The whole phone drew 3.8–4.2 W (`SystemLoad`), and the battery went from 36% to
      22%.
  - Not measured yet:
    - 540p against 720p at "serious";
    - whether the footprint growth stops in a longer run.
