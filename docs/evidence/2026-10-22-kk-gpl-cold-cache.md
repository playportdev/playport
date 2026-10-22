# KosmicKrisp GPL with a cleared shader cache: Hollow Knight and Portal 2 (PLA-429)

**Linear:** [PLA-429](https://linear.app/playportdev/issue/PLA-429). This follows
[decision 0158](../decisions/0158-kk-gpl-stays-experimental.md) and the phone evidence in
[2026-10-22-kk-gpl-phone.md](2026-10-22-kk-gpl-phone.md).

## Result

- **Clear did not clear everything before `ac515b8`.** Settings › Storage › Shader cache ›
  Clear removed Mesa's and DXMT's caches, but not Metal's own caches under
  `Library/Caches/<bundle id>/`: `com.apple.metal` (a 287 MB `functions.data`), `com.apple.metalfe`
  and `com.apple.gpuarchiver`. The row showed 738 MB before Clear.
  - After a Clear, KosmicKrisp translated its MSL again. Metal then found every library and
    pipeline in its own cache.
  - So a launch after Clear never paid the compiles that a person's first launch does.
  - G5 and G5c measured that warm case: there, the flag off has no build over 20 ms.
  - `ac515b8` adds Metal's three directories to `ShaderCache.directories`, so Clear empties them
    and the row counts them. After Clear the row shows 0 B.
- **With the cache cleared, Hollow Knight stalls less with `MESA_KK_EXPERIMENTAL=gpl`.**
  - **Whole route:** 5.5–5.9 s of stall against 7.4–7.5 s with the flag off.
  - **Gameplay** (after +60 s, the King's Pass slashes and walk): 0.5–1.0 s against 1.7 s.
  - Same route, two runs each, alternating off, on, off, on, each after a Clear.
  - FPS and rendering match the flag off; there were no `link FAIL`.
- **Portal 2 stalls twice as long with the flag** (below): 29.6–30.1 s against 16.6–17.2 s.
  - DXVK compiles a pipeline library for each of the 600 shaders that Source creates at load,
    and a KosmicKrisp fragment library costs up to about 510 ms of Metal compile.
  - So decision 0158 stands: the flag stays off. It helps a title that creates only the shaders
    it draws and hurts one that creates them all at load.
- **What is still kept:** DXVK 3.1.1's own shader cache (`%LOCALAPPDATA%\dxvk\*.dxvk.bin`, in
  the prefix). It holds DXVK's IR of the game's shaders: it saves DXBC translation, not Vulkan
  or Metal compiles, and Clear leaves it.

## The runs

- **IPA:** dev, SHA256 `f4683fbe6ab17296f493690676c4021f68d91ce6233c05c2aa78a71bfc91be73`
  (`ac515b8`).
  - The build also carried an uncommitted Settings section list scroll change in
    `SettingsView.swift` from another writer. It is not in this evidence's commits.
- **Route:** `.work/agent-notes/pla429/route.sh`, one `pp phone lock` per run, in this order:
  1. Settings › Storage, the Shader cache row, A (`pp ui` pad actions; the shot shows 0 B);
  2. `pp ui --pad --play app-367520 --until first-frame+25`;
  3. `hk-new-game`, `hk-walk`, then `hk-roam` for 90 s: the lumafly room, with jumps and slashes.
- **Graphics options:**
  - flag off: `MESA_KK_DEBUG=compile,memory`;
  - flag on: also `MESA_KK_EXPERIMENTAL=gpl`.
- **Measures:** `hitch.py` in the same directory. It reads the time between `[frames]` lines, one
  per 16 frames, against 16 frames at 60 FPS.

| Run | `pp ui` run | First frame | Stall beyond 60 FPS | after +60 s | gaps > 0.35 s (after +60 s) | longest |
| --- | --- | --- | --- | --- | --- | --- |
| off1 | `20261022T065816` | +10.97 s | 7.5 s | 1.7 s | 7 (4) | 3.41 s |
| on1 | `20261022T070543` | +11.57 s | 5.9 s | 1.0 s | 5 (2) | 2.90 s |
| off2 | `20261022T071247` | +11.39 s | 7.4 s | 1.7 s | 7 (3) | 3.35 s |
| on2 | `20261022T071931` | +11.58 s | 5.5 s | 0.5 s | 4 (1) | 3.00 s |

- **Big gaps in every run:**
  - The two at about +12 s (2.9–3.4 s) are the title menu's first draws.
  - Those at about +45 s (2.2–2.5 s) are the load into King's Pass.
  - Both are shorter with the flag, by about 0.4 s and 0.3 s.
- **Gaps after +60 s:** in gameplay, the flag off has 3–4 gaps (0.33–0.88 s), the first
  slash-and-particle draws. With the flag there are 1–2 (0.42–0.74 s).
- **Compiles, flag off:**
  - 37–39 whole pipelines, all translated: 5.5–5.8 s in all, 150–270 ms each;
  - the fragment library is most of that (170–240 ms);
  - 36–38 of them are on one thread, DXVK's draw path.
- **Compiles, flag on:**
  - 37 separate links: 2.2–2.3 s in all, about 60 ms each;
  - 60 whole pipelines (8.3–8.4 s), which DXVK's workers build in the background and switch to
    when ready: 25 on one thread, 34 on another;
  - 0 `link FAIL`.
- **`[kk-mem]`:**
  - flag off: `shaders=98–100 pipelines=50–51 msl=0.3`;
  - flag on: `shaders=223 pipelines=87 msl=1.8`.
- **FPS** over the whole route: off 58.2 and 58.1; on 58.6 and 58.6. Over the last 100 s,
  59.7–60.0 in every run.
- **Screenshots** in each run's directory under `.work/agent-notes/pla429/` show the same scenes
  as G5c's, with no rendering difference.

## What it means

The link still costs about 60 ms on the draw path. It is a Metal render pipeline built from
libraries already compiled, not the 150–270 ms whole compile.
- That is where the reduction comes from. It is less than the whole compile, because the
  vertex and fragment libraries are compiled when DXVK creates the GPL libraries, and in Hollow
  Knight that is often just before the first draw.
- A title that loads its shaders well before drawing would gain more.

Hollow Knight was removed from the phone after these runs, to make room for Portal 2.

## Portal 2: the flag doubles the stalls

Portal 2 (`app-620`) was installed after Hollow Knight was removed: 12.8 GB, in 115 s. It was
measured on dev IPA `58b57b1958f4cf5727e7ce28001ea8ff62c811453fe0d46737447ba856ae7337` (`7103952`,
with mesa 0102 and 0103, below).

**Steam API.** The first play stopped at the game's "Steam is not running" box.
- Every game's default is Playport's Steam client (decision 0153), which is
  `steamclient64.dll` only. Portal 2 is 32-bit and looked for `steamclient.dll`.
- Every run here therefore set `"steamAPI":"emulated"` for the title.
- That gives a fresh install no save, so SINGLE PLAYER opens on NEW GAME.
  `.work/agent-notes/pla429/p2-fresh-new-game.txt` is `p2-new-game` without its DOWN.

**Route:** `.work/agent-notes/pla429/p2route.sh`, one `pp phone lock` per run.
1. Clear, as for Hollow Knight.
2. Play to first frame+30.
3. New Game, chapter 1 and its load, the look tutorial.
4. `p2-walk` for 90 s in the relaxation vault.

| Run | `pp ui` run | First frame | Stall beyond 60 FPS | after +60 s | gaps > 1 s | longest | FPS (240 s) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| p2off1 | `20261022T075810` | +11.57 s | 16.6 s | 7.4 s | 4 | 5.72 s | 54.9 |
| p2on1 | `20261022T080407` | +13.02 s | 30.1 s | 12.0 s | 6 | 11.77 s | 50.8 |
| p2off2 | `20261022T081010` | +13.43 s | 17.2 s | 7.7 s | 5 | 6.00 s | 54.8 |
| p2on2 | `20261022T081614` | +11.64 s | 29.6 s | 11.7 s | 7 | 10.51 s | 50.9 |

- **Why the flag loses here:**
  - Flag off: the route builds 30 whole pipelines, 5.7–5.9 s in all.
  - Flag on:
    - DXVK makes a pipeline library for every shader the game creates, and Source creates its
      shaders at load.
    - So KosmicKrisp built 213 vertex and 390 fragment libraries, about 104 s of compiles. A
      fragment library is up to about 510 ms, most of it Metal's library compile.
    - Each launch also paid 24 separate links (1.0 s in all) and 31 whole pipelines that DXVK
      optimizes in the background.
  - The chapter load's gap doubles: 5.7–6.0 s off against 10.5–11.8 s on. Later gaps are longer
    too.
- **Same with the flag:** rendering (the vault shots match), FPS over the last 100 s (60.0), and 0
  `link FAIL`.
- **`[kk-mem]`:** off `shaders=77 pipelines=43 msl=0.3`; on `shaders=98 pipelines=37 msl=1.9`.

**GPU time.** Two `pp perf` runs, each 150 s with the same pads, compared over 90–150 s, the
walk (`.work/agent-notes/pla429/perf-p2-{off,on}`):

| | FPS | GPU ms | gpu% |
| --- | --- | --- | --- |
| off | 60.0 | 12.75 | 83.5 |
| on | 59.8 | 13.73 | 86.8 |

The on run came right after the off run and the eight cold runs. Its thermal budget fell to
404 mW, and the process ran on the E cores, so part of the +1 ms may be the GPU's clock rather
than the separate pipelines.

## mesa 0102 and 0103

- **0102 (PLA-428):** a GPL link's key and compile state leave out the dynamic blend constants.
  No compile reads them:
  - a whole pipeline's shader loads them from the root table;
  - a separate link's Metal blend has them set on the encoder.
  - **Host check:** two draws with other constants now make 1 separate link, not 2. `run.sh` counts
    11 `link separate`; without the change the count is 12 and the test fails.
- **0103 (PLA-430):** a whole pipeline's static sample mask with every rasterization sample (DXVK's
  `0x1` at one sample) no longer adds the sample-mask output and KK_WORKAROUND_7's discard.
  - **Host check:** pipelines with `0x1` at 1 sample and `0xf` at 4 write no `sample_mask_out`, and
    `0x5` at 4 does. Without the change, `0x1` gave 2 and the test failed.
  - Every MSL file from before (158 flag off, 211 with the flag, 25 Zink) is byte-identical. The 6
    new files are the new check's.
- **On the phone:** Portal 2 ran on these with defaults (the p2off runs) to its chapter at 60 FPS.
- **Not run:** Hollow Knight's smoke gate on `58b57b19`. It was uninstalled on the owner's request
  for room.

## 32-bit games and Playport's Steam client (PLA-432)

- **The fix** (`b233798`, then this change): `SteamAPISwap.launchMode` gives a game whose
  executable is i386 (`InstalledTitle.isI386`) the emulator in place of `client`.
  - The executable decides, not the DLLs: Portal 2 ships `bin/win64/steam_api64.dll` for its
    tools.
  - The first version, which looked at the DLLs, kept `client` and the game still stopped.
- **On the phone:**
  - Dev IPA `45cc0148f09ce663f6a14e1755a29feb429d0b4d35002f136a46ad5fdbdb1418`, Portal 2 installed again with no settings.
  - Run `.work/ui-runs/20261022T085839`:
    - first frame +9.12 s;
    - the log has `steamapi: Portal 2 is 32-bit: emulated, not client`;
    - New Game reaches chapter 1's look tutorial;
    - no "Steam is not running".
- **Room on the phone:** to install the IPAs, Portal 2 was uninstalled and installed again twice
  (121–139 s each). The phone has 1.2 GB free beside it and RDR2, under `pp install`'s 2 GB.

## What a pipeline library's build costs (PLA-437)

- **mesa 0104** (`MESA_KK_DEBUG=compile`): after each `[kk-compile] gpl` line, a `gpl-phases` line
  gives the build's phases:
  - NIR lowering for the library;
  - the rest of the NIR passes;
  - `nir_to_msl`;
  - the Metal library (`MTL4Compiler newLibraryWithDescriptor`, synchronous on the calling thread);
  - the Metal library and pipeline builds in flight, and the MSL's size.

  `MESA_KK_DEBUG=serial_libraries` builds one Metal library at a time, process-wide. KosmicKrisp
  holds no lock of its own around a library build: the calling thread (one of DXVK's workers)
  runs every phase.
- **Host check:** `run.sh` counts 16 `gpl-phases` lines. With `serial_libraries` and
  `parallel_stages`, every pipeline builds, one library at a time, with the same MSL.
- **On the phone:** dev IPA `03838a71a8779a89ecbd09854e27a9ea6fff81389b7c213b24244a4b8bb3f2aa`,
  Portal 2 with a cleared shader cache and the PLA-429 route (New Game, chapter 1, 90 s walk).
  Every run reached chapter 1's look tutorial.

  | run | ui run | stall beyond 60 FPS | chapter-load gap |
  | --- | --- | --- | --- |
  | gpl | `.work/ui-runs/20261022T094110` | 32.7 s | 12.21 s |
  | gpl | `.work/ui-runs/20261022T095752` | 31.9 s | 12.38 s |
  | gpl, `serial_libraries` | `.work/ui-runs/20261022T094811` | 66.3 s | 35.59 s |

  PLA-429's gpl runs: 29.6–30.1 s and 10.5–11.8 s. Off: 16.6–17.2 s and 5.7–6.0 s.

  Times per library (ms):

  | library | in flight | front end (NIR + MSL), median | Metal library, median / p90 | MSL, median |
  | --- | --- | --- | --- | --- |
  | vertex (205, 235) | 3 | 13.0, 13.7 | 344 / 710, 432 / 731 | 247, 285 KB |
  | fragment (390, 391) | 3 | 4.0, 4.0 | 1,060 / 1,607, 1,000 / 1,544 | 66 KB |
  | vertex, serial (202) | 1 | 9.4 | 229 / 459 | 245 KB |
  | fragment, serial (360) | 1 | 2.9 | 645 / 916 | 68 KB |

- **What it shows:**
  - The Metal library build is 97–99% of a library's cost. Mesa's front end (NIR passes and
    `nir_to_msl`) took 4.9–5.7 s for about 600 libraries; Metal took 512–513 s.
  - DXVK runs three worker threads, so libraries in flight are 3 at the median and 6 at most;
    600 at once never happens.
  - Three in flight cost each library 1.5–1.65× its serial time. Throughput is still about 1.7×
    higher: the libraries' wall-clock span was 192 s at 2.7 in flight against 314 s serial.
  - A library's time grows with its MSL: about 1.2 ms per KB for vertex, 1.65 ms per KB for
    fragment, serial.
  - Library MSL is much larger than a whole pipeline's: vertex 245 KB against 11 KB, fragment
    66 KB against 12 KB (whole-pipeline builds over 20 ms, PLA-429 off run). Each vertex
    attribute's runtime vertex fetch is inlined, about 27 KB per attribute on the host.
  - The libraries keep building for about 190 s, long after chapter 1 appears (about +62 s). A
    chapter-load gap has about 60 library builds in flight, and 335 more start after it.
  - The draw thread waits for them:
    - Serialized, the draw thread's own link pipelines took 2.4 s, against 7.6 s with 3 in flight.
      Its gap still grew to 35.6 s.
    - Concurrent library builds slow the draw-time link pipelines about 3×: link median 122 ms and
      max 2,254 ms, against 67 ms and 276 ms serial.
- **Not run:** a gpl-off run on this IPA; the comparison uses PLA-429's off runs. Hollow Knight's
  smoke gate passed on this IPA: first frame at +12.28 s, `.work/ui-runs/20261022T093339`.
- **The IPA's app** was built from a working tree with another change's uncommitted
  `SettingsView.swift`. The Settings screen is not on these runs' path, which reach it only to
  clear the shader cache.

## Building pipeline libraries in the background: tried and reverted (PLA-437 step 2)

**Result:** a KosmicKrisp queue that builds a pipeline library's Metal library after
`vkCreateGraphicsPipelines` returns missed both targets, so it was reverted (`082540c`). Step 1's
synchronous library builds stay, and the flag stays off (decision 0158).

- **Portal 2** (cold cache, flag on) stalled 26.7–27.9 s, against 17.1 s flag-off on the same IPA.
- **Hollow Knight** stalled 6.7–9.1 s, against 5.5–5.9 s for step 1's synchronous builds.

**What was tried.** Commits `1b741e4` and `d046a5f` (mesa 0105 and 0106) hold the code; the
revert removed it. A third patch was measured but never committed.

- **0105:** `vkCreateGraphicsPipelines` made the MSL and queued the Metal library.
  - One thread built the queue at utility QoS, oldest first.
  - A link whose libraries were not built yet compiled the whole pipeline
    (`fallback=library-pending`) and moved them to the queue's front.
  - A library destroyed while queued was never built.
  - Deserialized libraries were built at once.
  - `MESA_KK_DEBUG=sync_libraries` kept the old path.
- **0106:** a deserialized library whose MSL had been dropped unbuilt was queued too (below).
- **Uncommitted, measured:** three threads at default QoS. A build started no sooner than 10 ms
  after it was queued, unless a link had moved it to the front.
- **Host test** (mock Metal, with a gate holding the queue's builds) covered:
  - a link before the build, which falls back;
  - a pipeline cache read meanwhile, whose libraries deserialize and link fast;
  - libraries destroyed while queued and while building;
  - the drained queue, which links fast;
  - device destroy with builds running and one queued.

  With the old path the test fails: the libraries made 6 MSL libraries, not 1. Flag-off MSL
  stayed byte-identical: 164 files, before and after the revert.

**IPAs** (dev, each built from `main` plus the other writer's uncommitted `SettingsView.swift`, as
in step 1):

- `177203b28a09601d1d9d4e052da94c97771c77b65e7e163b4322d46643df65c9` (0105);
- `130556426a2d7b09c7390c99e61fd1e9bc1e3c927dcbbfe36cdbd328eedf7fea` (0105, 0106);
- `a7f70fe17ba92f52012553e815f4cf49decdca9a7ba9b17cfab34434b8e44188` (plus the hold);
- `6345fd16579215cd87c6fdb97727a5fb5b6061f68043ab7984a3a7da99f5324f` (0105, 0106);
- `d58f1c029570f6827ecd0cf3a721089484d1020c4d4b30c1b2cadd02ea550c7f` (plus three threads);
- after the revert, `6e9fce2f2e3c4ca2f31314554cac92185e61a4be2ab3ace3a214ddbd826d5bd3` (`082540c`),
  left installed. It has step 1's mesa (0104 last), which passed Hollow Knight's smoke gate on
  `03838a71`; it got no run of its own.

**Runs.** Portal 2 used the PLA-429 route with a Clear first. Every run reached chapter 1's look
tutorial, with 0 `link FAIL` and 60 FPS over the last 100 s.

| IPA (sha256 prefix) | mesa | run | `pp ui` run | stall | chapter-load gap | links: separate / library-pending |
| --- | --- | --- | --- | --- | --- | --- |
| `177203b2` | 0105 | gpl | `20261022T103255` | 27.1 s | 7.61 s | 22 / 2 |
| `130556426` | 0105, 0106 | gpl | `20261022T105531` | 26.7 s | 8.16 s | 0 / 25 |
| `a7f70fe1` | + a hold* | gpl | `20261022T111116` | 27.0 s | 7.93 s | 0 / 25 |
| `6345fd16` | 0105, 0106 | gpl | `20261022T112532` | 27.7 s | 8.41 s | 0 / 25 |
| `6345fd16` | 0105, 0106 | off | `20261022T113127` | 17.1 s | 5.99 s | – |
| `d58f1c02` | + 3 threads | gpl | `20261022T122545` | 27.9 s | 8.03 s | 2 / 23 |
| `d58f1c02` | + 3 threads | gpl | `20261022T123138` | 27.7 s | 7.98 s | 2 / 23 |

\* The hold kept the queue from starting a build while a link compiled. It changed nothing and was
dropped.

Hollow Knight used the PLA-429 route.

| IPA | queue | run | `pp ui` run | first frame | stall | links: separate / library-pending |
| --- | --- | --- | --- | --- | --- | --- |
| `6345fd16` | 1 thread | gpl | `20261022T113933` | +12.95 s | 8.0 s | 7 / 35 |
| `6345fd16` | – | off | `20261022T114614` | +12.71 s | 8.5 s | – |
| `6345fd16` | 1 thread | gpl | `20261022T115248` | +13.58 s | 9.1 s | 7 / 35 |
| `d58f1c02` | 3 threads | gpl | `20261022T120809` | +12.87 s | 7.1 s | 31 / 10 |
| `d58f1c02` | 3 threads | gpl | `20261022T121456` | +11.90 s | 6.7 s | 31 / 11 |

- **Hollow Knight, other measures:**
  - FPS 57.8–58.4, 59.7–60.0 over the last 100 s; 0 `link FAIL`.
  - The lumafly-room shots show the same scene as PLA-429's.
  - Smoke gate on `d58f1c02`, defaults: first frame +10.73 s, `20261022T121924`.
- **Per library, Hollow Knight:**
  - one thread: vertex 137–142 ms and fragment 309–314 ms (median), but a median 0.7–2.3 s in the
    queue;
  - three threads: 103–156 ms and 259–283 ms, with 0.1–0.35 s in the queue.

**Why it failed.**

- **Portal 2 is 32-bit, and DXVK destroys each of its libraries as soon as it is made.** This is
  `DxvkShaderPipelineLibrary::compilePipeline` when `mustTrackPipelineLifetime()` is true:
  `dxvk.trackPipelineLifetime` is Auto, which means true for a 32-bit process on any driver but
  RADV.
  - DXVK counts on the driver's disk cache to make the library again when a draw needs it.
  - So 1,709–1,730 queued libraries per run were dropped within about a millisecond (median
    0.1 ms).
  - The draw then made each one again from the disk cache.
- **Before 0106 the draw paid an uncached Metal build.** Deserializing built the Metal library at
  once on the draw's thread, from nothing: 0.1–0.75 s each, giving a 10 s gap at about +67 s. In
  step 1 the first build had warmed Metal's cache, so the same deserialization took 0.1 ms.
- **With 0106 every draw link fell back.** 0106 queued those deserializations, and DXVK destroys
  the library again after use, so 23–25 of 25 links were whole-pipeline compiles.
  - Each took about 480 ms on the draw's thread, against about 190 ms flag-off.
  - Its fragment MSL is about twice a flag-off pipeline's: unspecialized library NIR.
  - DXVK's own optimized compile of the same pipeline runs at the same time.
  - Flag-off's draw thread built 29 pipelines in 5.8 s; with the queue it built 24–25 in
    11.6–12.4 s.
- **Waiting at the link instead was not taken.** The alternative was to wait for a running build,
  or build a queued one on the draw's thread. Step 1's uncontended medians make that slower:
  - a library costs 229 ms (vertex) and 645 ms (fragment);
  - the fast link adds 60–120 ms;
  - against a 150–270 ms (Hollow Knight) or about 480 ms (Portal 2) whole compile.
- **The load before the chapter is longer too:** gaps of 5.1–5.3 s and 7.6–8.4 s, against
  3.8 s and 6.0 s off. All 1,700 libraries now pass the front end (4–14 ms each) and are
  serialized, which step 1's slow builds never reached.
- **Hollow Knight links right after it creates its libraries.** One utility thread left most of
  them pending (35 of 42 links fell back). Three threads brought that to 10–11, but the fallbacks
  still cost more than step 1's draws waiting on DXVK's three compile threads.

## Where a library's Metal time goes: MSL front end, not pipelines (PLA-437 check A)

- **Method.** An uncommitted experiment build (dev IPA
  `bbc344c483b270032cbde11b18dfb19f66c32070657ec8b036396d7a9c8a81f0`) timed each stage serially
  at Portal 2's device creation, 3 rounds each, with entry points renamed every round so no Metal
  cache hit. Run `.work/ui-runs/20261022T145046`.
  - Shaders are real Portal 2 MSL from the step 3 dumps. Each was built three ways:
    - from source as MSL 4.1 (what KosmicKrisp asks for on iOS 27);
    - from source as MSL 4.0;
    - from an AIR metallib built on the workstation by Apple's Windows Metal tools (6.2) under
      Wine, loaded with `newLibraryWithData`.
  - Pipelines used the same fixed descriptor on every path.
- **Results, median ms on iPhone18,4, iOS 27.0:**

  | Shader | Library from source, MSL 4.1 | MSL 4.0 | Library from metallib | Pipeline (from source / from metallib) |
  | --- | --- | --- | --- | --- |
  | fragment library a20eb (3 texture types) | 349.6 | 136.4 | 0.01 | 13.1 / 13.8 |
  | a20eb without texture types | 14.3 | 10.5 | 0.01 | 9.6 / 9.2 |
  | a20eb without textures plus one unused `texture2d<float>` | 147.8 | 63.0 | 0.01 | 9.3 / 9.2 |
  | fragment library 158a | 390.3 | 152.1 | 0.01 | 34.5 / 32.7 |
  | vertex library 3bee | 312.1 | 173.9 | 0.02 | 77.0 / 72.3 |
  | DXVK whole pipeline 867de (vs, fs) | 15.0, 159.6 | 11.8, 64.3 | 0.01 | 17.1 / 18.1 |

  - Function creation (`newFunctionWithName`, MTL4 function descriptors) is ≤0.02 ms.
  - A repeated pipeline build takes 0.1 ms, which is what a cache hit looks like. No timed row
    shows it.
- **What it shows:**
  - A library's cost is the phone's MSL→AIR front end. The step 3 texture-type cost is in that
    front end: with AIR it disappears, and the pipeline does not grow.
  - The same MSL compiles 2–2.6× faster as MSL 4.0 than as 4.1. In KosmicKrisp, 4.1 only enables
    `shaderSharedFloat32AtomicAdd`.
  - Precompiled AIR would save about 350 ms per a20eb-like fragment library, 312 ms per 3bee-like
    vertex library and 175 ms per whole pipeline, serial. The cost of generating AIR in the app is
    not counted.
- **GPU binaries.** The Windows tools make `applegpu_g18p` (A19 Pro) archives only for iOS ≤ 26:
  `-ios-version-min 27.0` is refused. iOS 27 rejects the iOS 26 archive ("deployment target …
  not compatible with current OS"). A GPU binary could only save the 8–77 ms pipeline step.
- **Phone state afterwards:** the committed build
  `69d360e0aef8d4e9e8ea7d3fc3c62909463e57912f814a3a92e3d0b0d4459467` is installed, with Portal 2
  installed. Nothing was changed in the patch series.
