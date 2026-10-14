# Shader caches: Mesa's 1 GB cap, the Storage row, and Zink's disk cache on

**Date:** 2026-10-14. **Kind:** phone runs (dev app), iPhone18,4, iOS 27.0.1.
**Linear:** [PLA-279](https://linear.app/playportdev/issue/PLA-279),
[PLA-346](https://linear.app/playportdev/issue/PLA-346).
**Build:** 65faeb0 plus this change (branch `dev/pla-279-shader-caches`). **IPAs:** dev
`05518a7a1744035b1a842070ba053c0e7e59b2f403b43f84d40d334aacda6da4` (runtime change), then
`2e47d6e36fba3677a96d2a230e3c561b5fab7a44f686fb6f1599859e07d343b3` (the Storage row counting
allocated space; the runtime is the same). Run directories under `$PLAYPORT_BUILD/pla279/`.

## What changed

- **`app/Sources/WineHost/wine_host.c`:** `MESA_SHADER_CACHE_MAX_SIZE` is 1G, Mesa's own default
  (it was 256M). One directory, `Library/Caches/kosmickrisp`, serves every title.
- **Settings › Storage › Shader cache** (`ShaderCache.swift`): the size of `Library/Caches/kosmickrisp`
  and `Library/Caches/dxmt` together, and Clear (only while no game runs). The size is the space
  the files take, which is what Mesa counts against its limit (`st_blocks * 512` in
  `disk_cache_os.c`). Most entries are a few KB, so it is about a quarter more than their byte
  lengths: the same cache read 182 MB by byte length and 242 MB allocated.
- **`patches/mesa` 0026 dropped** ("zink: no disk cache on iOS"). Zink now keeps its disk cache, and
  through it Mesa's GLSL cache, in the same directory as KosmicKrisp's (0015).

## Results

- **The old cap was being reached.** Before any of the runs below, Mesa's index (its first 8 bytes
  are the cache's counted size) read 232,505,344 bytes, against the 256 MB cap.
- **Most of that size was stale.** KosmicKrisp's cache key hashes the driver build (0015), so each
  Mesa build starts a fresh set of entries. The old entries stay until the size limit evicts them.
  Hollow Knight from an empty cache (after Clear) wrote 450,560 bytes. So the 232 MB was entries
  from earlier builds and other titles, not one title's working set. Every release changes the
  build too, so players accumulate stale entries in the same way. 1 GB leaves room for several
  heavy titles across builds. A per-title size is not needed for anything measured so far.
- **Zink's cache is written and read back.** Two launches each of the `wgl` probe (x86-64,
  `dir-wgl`) and the `gl21` probe (i386, `dir-gl21-i386`):

  | Run | First frame | Mesa cache growth | Probe checks |
  | --- | --- | --- | --- |
  | `wgl-1` (Zink's cache empty) | +3.37 s | +151,552 B | all as before (below) |
  | `wgl-2` | +3.24 s | 0 B | the same |
  | `gl21-1` (Zink's cache empty) | +3.31 s | +102,400 B | all ok |
  | `gl21-2` | +3.18 s | +20,480 B | all ok |

  The second `wgl` launch added nothing: every Zink and KosmicKrisp entry it needed was a hit. Both
  second launches reached their first frame about 0.13 s sooner. These probes have few shaders, so
  a game with many GLSL programs should gain more; not measured.
- **No stale pipelines.** The probes' read-backs were identical on the cold and warm launches. `wgl`
  without arguments fails only `msaa` (`format 142, GL_SAMPLES 0`), as it did before this change
  (run `20261011T150258`). The probe asks for a 4x format only with its `msaa` argument.
- **Clear.** The row showed 242 MB, and 0 B after A (Clear). `Library/Caches/dxmt` was empty
  afterwards. Hollow Knight then started normally (first frame +9.36 s, `hk-after-clear`), and Mesa
  made its cache directory again (91 subdirectories).
- **The gate.** Hollow Knight (`app-367520`) to first-frame+10 on `05518a7a…`: first frame +8.44 s
  (`hk`).

## Not checked

- Half-Life (`-gl`) was not installed on the phone, so no game ran on OpenGL. The probes stood in.
- vkd3d-proton's cache (`vkd3d-proton.cache` in the working directory): no Direct3D 12 title was run.
