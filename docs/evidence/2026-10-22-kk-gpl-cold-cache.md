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
