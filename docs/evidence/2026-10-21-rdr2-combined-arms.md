# RDR2: wine-pe 0051 fixed, the flashing fixed, single-process Social Club and the combined arms (PLA-364, PLA-413)

**Linear:** PLA-364, PLA-413. Follows [the critical-section arms](2026-10-21-rdr2-cs-fastpath-and-heap.md)
and [the x18 patcher fix](2026-10-21-x18-patcher-x64-code.md). The phone was on its charger at first, later
on battery (80 %). Runs went back to back (the owner's rule: RDR2 throttles at once and breaks do not
change it), every measured window after `thermal: serious` (most runs started at `serious at launch`), and
the runs ended once their question was answered.

## Method

- **Scripts.** They are in `.work/agent-notes/pla413e/` (`story.sh`, `landing.py`, `dialog-ok2.py`, `watchdog.sh`,
  `arm.py`, `sheet.py`) and `.work/agent-notes/pla364d/` (`xarm.sh`, `scarm.sh`, `fp.py`).
- **Session settings.** `donorPoolMB=auto` and aspect 16:9. Story is pressed by the landing script, and
  there is no stick input.
- **Social Club workarounds.** Without `PLAYPORT_SC_SINGLE`: `endGameSocialClubAfterSignIn=true` and
  `refuseGameSocialClubRestart=true`. With it, both are false, so the helper lives.
- **Runtime keys.** The `env.` keys named per run are merged over RDR2's compatibility default.
- **The porch view.** Each window starts 10 s after the porch view appears in the run's screenshots and
  lasts 60 s.
- **Normalising.** Single runs move by about 10 %, and the E-core clock moves with them, so the tables
  give fps per E-core GHz as well.

## IPAs and Hollow Knight

| IPA (dev) | Commit | What | Hollow Knight first frame+10 |
| --- | --- | --- | --- |
| `6aa8353e09c76effaa4399c44183bc1fb89557eb4191728081f172fad95b61a6` | f4f998c | madeira-unix 0204, wine-pe 0051 as first written, 0052 QPC, 0053 InitOnce | passed (`.work/ui-runs/20261021T103559`; ntdll `[x18-patch] … x64_skipped=1`) |
| `375c7233932b185292c9a9db68f2358f7b39587f6e46cb369dee349e635bcbf2` | 03a458a | + wine-pe 0051 fixed (below) | passed (`…T105309`) |
| `6ab8471c6fdd27f3e4a9fa6219b70b5b0169d08a15f8a5402dd19fb64ebae0f1` | e704edf | + madeira-unix 0205 / mesa 0083 (one window owns the layer), batch 2 merged ([2026-10-21-batch2.md](2026-10-21-batch2.md)) | passed (`…T120007`) |
| `7910e2a383b1e051ce161804a9cb088c39e84e7caa1873d29ac0281a0c32d186` | cd377ae | + wine-pe 0052 binds KERNEL32's QueryPerformanceCounter by name | passed (`…T122657`) |
| `ae8dbb17c2498bbc07ac2245f6d4f458d60fed5a4143083509dea8d89870d836` | this commit | + RDR2's compatibility default with decision 0152's two keys | passed (`…T140859`) |

## wine-pe 0051 was a no-op; fixed

- **q1** (`…T103706-rdr2-q1`, 6aa8353e, defaults) shows that madeira-unix 0204 works. The launcher started and
  signed in, and RDR2 started.
- Then the "frida" crash came again. RDR2's main thread read `0x707a630000`, the process heap's base
  (`0x707a620000`) + 0x10000 (`NO wine view`), and the process ended with `exit_code=0xc0000005`.
- **The cause.** wine.inf writes `HeapSegmentReserve` and `HeapSegmentCommit` as 0 to the Session Manager key
  (`app/Sources/S1Probe/Runtime/registry/system.reg`, as in every Wine prefix). The PEB fields are therefore 0,
  and 0051 passed 0 on, so the first region stayed 64 KB.
- **The fix.** 0051 now takes Windows' 1 MB reserve and 64 KB commit where the PEB's values are 0
  (commit 03a458a).
- **After it, 0 of 9 runs on 375c7233 or later had the fault.** y1, d2, d3, x3–x9 and qp1 have no
  `0xc0000005` exit after the PlayRDR2 box. The crash was intermittent before (r1, n1, a1 and q1).
- **Log cap.** No `s1-host.log` came near 256 MiB: the largest was 17.9 MB (y1). The prev-log rotation
  was therefore not exercised.

## The flashing: two swap chains on one layer (madeira-unix 0205, mesa 0083)

- **What the owner saw.** With `env.PLAYPORT_SC_SINGLE=1`, the screen alternated between the Rockstar
  launcher's progress page and the "A game is currently running" / sign-in popup (runs x1 and x2, ended by
  the owner).
- **The cause.** The launcher's Social Club browser, now in one process, draws its sign-in window
  (`hwnd 0x100a6` under "Rockstar Games - Sign In") through its own Vulkan surface: a 700x800 chain beside
  the launcher's 1280x600 one.
  - In game mode every surface is the one phone layer, so the two chains took it in turns.
  - Mesa 0045 reconfigures the layer for whichever chain acquires.
  - `[kk-wsi] layer back to the presenting chain` appears 37 times in scA1, x1 and x2 alike: the trace
    caps kind 3 at 40 lines (3 creates + 37), so the fight went on unlogged.
  - q1 (multi-process) has one launcher chain (1280x720) and no such line.
- **Not the cause.**
  - No process restarted: PlayRDR2, Launcher, RDR2 and SocialClubHelper started once each.
  - Only 193 `[win-pos]` lines in all.
  - Memory: the footprint was 5.0–5.2 GB.
  - The log cap: logs of 9–13 MB.
  - The main queue: one `main queue has not run` line, at the kill.
- **The fix.** The win32u driver keeps game mode's Vulkan surfaces with their top-level window and exports
  `playport_vk_surface_shown`. KosmicKrisp's swap chains ask it before they touch the layer.
  - **Ownership.** While one top-level window has all the surfaces, each surface owns the layer, as before.
    Otherwise the owner is the first window with a surface. It changes only when the foreground window
    changes to another window with a surface, or when the owner is destroyed or hidden and a visible window
    presents. A present alone never moves it.
  - **A chain whose window does not own the layer** configures nothing on it. It draws to an offscreen
    layer of its own, and its present waits complete at once.
  - **Logs.** `[vk-shown]` and `[kk-wsi] the WxH chain now draws …` are logged at most once a second.
  - **Host test.** `tools/tests/test_vk_shown.py` runs 0205's code against win32u stand-ins.
- **On the phone (x3, 6ab8471c, SC_SINGLE).** Three ownership changes:
  1. first window `0x2006c`;
  2. foreground `0x2003a` (the 1280x600 chain goes offscreen);
  3. foreground `0x2006c` (the 700x800 chain goes offscreen).

  Then the owner was stable, with no flashing. The launcher went on, RDR2 signed in at +136.6 s, and
  Story was pressed. Hollow Knight (one window) is unchanged.
- **The RDR2 stall in x1 and x2.** RDR2.exe stopped making threads about 33 s after it started (at tid 0440,
  after its second `audio_client_timer`) and never signed in. With 0051 cleared by y1, the likeliest cause is
  the launcher stuck in the layer fight: x3, with the fix, went on. That is an inference, not a measurement.

## Single-process Social Club (`env.PLAYPORT_SC_SINGLE=1`)

| Run | IPA | SC | Gate counts | Box after first frame | Signed in | Result |
| --- | --- | --- | --- | --- | --- | --- |
| scA1 (`…T104332-rdr2-scA1`) | 6aa8353e | single, workarounds off | preflight 2, verified 2, `[sc-rph]` 2, refusing 0, race 0, fallback 0, `[sc-runst]` 0 | 84 s | +96.3 s | Story pressed; `pp ui` stopped early ("exited" while the app ran); footprint 7.8 GB at the end |
| x3 (`…T120112-rdr2-x3`) | 6ab8471c | single + all switches | the same, 2/2/2/0/0/0/0; `[sc-crashpad]` 1 refusal | 120 s | +136.6 s | to the porch load (run ended at +300 s) |
| x4 (`…T121057-rdr2-x4`) | 6ab8471c | the same | 2/2/2/0/0/0/0 | 69 s | +95.2 s | **jetsam highwater** at the porch load (8,389,601 KB) |
| y1, d2, d3 | 375c / 6ab8 / 7910 | multi-process, workarounds on | — | 33–37 s | +87.7 / +139.0 / +145.9 s | porch held |

- **Processes.** Multi-process (y1): 95 `SocialClubHelper.exe` starts. The game restarts its helper
  every ~5 s, and 0135/0138 end or refuse each one. Single-process (scA1, x3): 2 starts, the launcher's
  and the game's. The game's stays alive: one process, 45 threads, about 300 MB resident + compressed.
  - x4, at the kill: `image=313/53/16 private=125/54/4 fex=758/157/33` MiB, committed/resident/compressed.
  - scA1: `image=312/15/37 private=129/41/20 fex=710/109/87` MiB.
- **Footprint.** At the Story press and press +60 s: scA1 5374/5462 MB, y1 5182/5394 MB, x3 5506/5453 MB.
  But the porch load then exceeded the limit in x4, and scA1 reached 7.8 GB. Defaults peak at 7.0–7.4 GB.
- **Sign-in.** It held to the porch in every single-process run. Ten minutes of gameplay were not run
  (shorter runs, the owner's rule).
- **Verdict.** Single-process works: it signs in, makes fewer processes, and the flashing is fixed. With the
  workarounds off, though, the live helper costs about 300 MB and RDR2 then reaches the memory limit at the
  porch load (x4). It also delays the launcher by 35–85 s. Defaults unchanged (owner decision). Not tried:
  single-process with `endGameSocialClubAfterSignIn=true` (since run: [xs1](2026-10-21-rdr2-sc-single-with-end.md)).

## The performance arms

60 s porch windows, all at `thermal: serious`:

| Run | IPA | Keys | fps | GPU busy | gpu/frame | cores | E GHz | fps/E-GHz | mW | x64→EC/s | peak MB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| y1 (`…T113226-rdr2-y1`) | 375c7233 | defaults | 16.6 | 43 % | 26.0 ms | 3.05 | 1.59 | 10.4 | 431 | 630 k | 7310 |
| d2 (`…T121700-rdr2-d2`) | 6ab8471c | defaults | 15.4 | 42 % | 27.6 ms | 2.90 | 1.48 | 10.4 | 377 | 564 k | 7439 |
| d3 (`…T123515-rdr2-d3`) | 7910e2a3 | defaults | 15.4 | 42 % | 27.6 ms | 3.04 | 1.45 | 10.6 | 385 | 544 k | 7038 |
| d4 (`…T132605-rdr2-d4`) | 7910e2a3 | defaults | 15.4 | 42 % | 27.5 ms | 2.97 | 1.45 | 10.6 | 378 | 564 k | 6918 |
| d5 (`…T135614-rdr2-d5`) | 7910e2a3 | defaults | 14.8 | 41 % | 27.8 ms | 3.06 | 1.39 | 10.6 | 366 | 546 k | 6988 |
| x7 (`…T130024-rdr2-x7`) | 7910e2a3 | CS, ECO_NATIVE, SAFE_MATH, FEX_BATCH2 | 14.3 | 50 % | 35.4 ms | 3.13 | 1.17 | 12.2 | 312 | 415 k | 7014 |
| x10 (`…T133428-rdr2-x10`) | 7910e2a3 | CS, FEX_BATCH2 | 15.7 | 43 % | 27.4 ms | 3.06 | 1.35 | 11.6 | 351 | 457 k | 7149 |
| x11 (`…T134726-rdr2-x11`) | 7910e2a3 | CS, FEX_BATCH2 | 15.7 | 43 % | 27.3 ms | 3.00 | 1.35 | 11.6 | 342 | 457 k | 6966 |
| x9 (`…T131800-rdr2-x9`) | 7910e2a3 | CS, FEX_BATCH2 | *17.8* | 32 % | 23.4 ms | 1.99 | 1.43 | *12.4* | 305 | *49 k* | 7169 |

300 s windows: y1 16.3 fps at E 1.53 GHz (10.7 fps/E-GHz); x10 15.6 fps at E 1.34 GHz (11.6).

x9 is not the same scene. Its porch window drew 627 indexed draws a frame (`vkCmdDrawIndexed` 11,158/s), against
1,860–1,950 in d3, d4, x7, x10 and x11; its x64→EC rate and core count fell with it. It is left out of the
comparison.

Arms that did not reach a measured window:

| Run | IPA | Keys | Result |
| --- | --- | --- | --- |
| x1 (`…T110134-rdr2-x1`) | 375c7233 | SC_SINGLE, CS, QPC, ONCE, CALLRET_POP, SAFE_MATH, ECO_NATIVE | flashing + RDR2 stall (above); ended by the owner. The InitOnce stub bound in five processes (`[x64-once]`), and the launcher ran with ONCE and CALLRET_POP on |
| x2 (`…T112105-rdr2-x2`, log in `.work/agent-notes/pla413e/x2/host`) | 375c7233 | SC_SINGLE, CS, QPC, SAFE_MATH, ECO_NATIVE | the same; ended by the owner |
| x5 (`…T122756-rdr2-x5`) | 7910e2a3 | CS, QPC, SAFE_MATH, ECO_NATIVE, FEX_BATCH2, KK_BATCH2, SC_BLOCK_CRASHPAD | the app died during the porch load (12:34:07; a crash corpse, no jetsam line; peak 6855 MB) |
| x6 (`…T124552-rdr2-x6`) | 7910e2a3 | x5 without QPC | **jetsam per-process-limit** at the porch load (peak 8015 MB) |
| x8 (`…T130932-rdr2-x8`) | 7910e2a3 | x7 + KK_BATCH2 with `MESA_KK_BATCH2_SKIP=alloc` | loading screens, then black with the orange spinner at 60 fps (GPU 0.6 ms a frame) where the porch should be; the next run (x9) loaded the porch, so the save is unchanged |
300 s windows: y1 16.3 fps at E 1.53 GHz (10.7 fps/E-GHz); x10 15.6 fps at E 1.34 GHz (11.6).

x9 is not the same scene. Its porch window drew 627 indexed draws a frame (`vkCmdDrawIndexed` 11,158/s), against
1,860–1,950 in d3, d4, x7, x10 and x11; its x64→EC rate and core count fell with it. It is left out of the
comparison.
 | 7910e2a3 | QPC only | the porch showed once (12:57:45), then a black screen at 60 fps with the orange spinner to the end; `RtlQueryPerformanceCounter` left `[xp-api-top]` (the stub took the calls) |

- **The QPC stub binds, and RDR2 misbehaves with it.**
  - On 6aa8–6ab8 it bound nothing (`[x64-qpc]` absent): RDR2 and its launcher import
    `KERNEL32.QueryPerformanceCounter`, whose export is an x64 `jmp [rip+d]` (`ff 25`), not an ntdll thunk.
  - 7910e2a3 binds it by name (`[x64-qpc] KERNEL32.QueryPerformanceCounter resolved to … (L"kernel32.dll",
    code ff 25): bound by name`; RDR2 "3 of its KERNEL32.dll imports go to the x64 stubs").
  - In qp1 the game left the porch for a black screen. x5 (QPC with the others) died. QPC stays off and is
    not a default candidate.
- **The memory cost of the combination.** x6 (no QPC) was killed at the porch load at 8015 MB. x7 (without
  KK_BATCH2) peaked at 7014 MB, inside the defaults' 7.0–7.4 GB. MESA_KK_BATCH2 is the suspect (its `alloc`
  item keeps up to 8 command allocators per pool).
- **x7 against defaults.**
  - fps/E-GHz is +15 % (12.2 against 10.4–10.6), and x64→EC transitions fall from 544–630 k/s to 415 k/s.
  - Raw fps is lower (14.3 against 15.4–16.6), at the lowest E clock of the day (1.17 GHz).
  - GPU time per frame rose 28 % (35.4 against 27.6 ms; busy 50 % against 42 %). `MESA_KK_SAFE_MATH`'s
    precise math is the likely cost.
- **Arthur's hair (SAFE_MATH).** Crops of the porch view, d3 (defaults, 12:41:32) against x7 (13:07:04): the
  hair and beard look the same, dark brown with grey highlights, in both. The porch is in shade, and 0082
  targets a red flat artefact "in bright light only", so the porch does not decide it.

## Defaults: CS and FEX batch 2 (decision 0152)

- **What was compared.** Four defaults runs (d2–d5) against two runs with `env.MADEIRA_X64_CS_FASTPATH=1
  env.MADEIRA_FEX_BATCH2=1` (x10, x11), all on 7910e2a3, back to back.
- **Result.** The switched runs were 9–12 % higher in fps per E-core GHz (11.6 against 10.4–10.6; the
  defaults spread ±1 %), 2–6 % higher in fps, and drew 5–11 % less CPU power, at the same memory peak. Both
  signed in and held the porch with no fault.
- **The gain is modest.** It is mostly the same frame rate at a lower CPU clock under the clamp.
- **Decision.** [0152](../decisions/0152-rdr2-default-x64-critical-sections-and-fex-batch2.md) makes the two
  keys RDR2's compatibility default.
- **Left off:**
  - QPC (qp1, x5);
  - KK batch 2 (x6, x8);
  - SAFE_MATH (GPU +28 %, x7) and ECO_NATIVE (only measured with SAFE_MATH);
  - ONCE and CALLRET_POP (run only in x1, which the layer fight ended; the launcher started with both on and
    the InitOnce stub bound in five processes, but nothing was measured);
  - single-process Social Club (owner's decision; above).

**On the new default (nd1, `…T140959-rdr2-nd1`, ae8dbb17, no runtime-key row).**
- The log shows `config: environment MADEIRA_X64_CS_FASTPATH=1` and `MADEIRA_FEX_BATCH2=1` from the
  compatibility default, `FEX: batch2 bits=0xf`, and the `[x64-cs]` imports.
- The game signed in at +128.9 s.
- At the porch (60 s, `thermal: serious` from 14:11:15, after a 4 min build pause): 16.5 fps at E 1.50 GHz,
  11.0 fps/E-GHz, 376 mW, peak 7549 MB.
