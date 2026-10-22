# KosmicKrisp GPL with a cleared shader cache: Hollow Knight (PLA-429)

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
