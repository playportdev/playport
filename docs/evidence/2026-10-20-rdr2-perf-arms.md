# RDR2 performance arms on one IPA (PLA-364)

**IPA:** dev `ee38ddeb084146c69a30591e04c84ad5db995b9a97360aa8b43111b240c48ddd` for every run.
**Linear:** PLA-364. Follows [the self-exit record](2026-10-20-rdr2-self-exit-band.md): its run n2
(arm A there) was CPU-bound at 15.9 frames/s.

## Method

- One change per arm: a dev runtime-key row merged over RDR2's compatibility default. Session settings
  as in n2 (`donorPoolMB=auto`, `endGameSocialClubAfterSignIn`, `refuseGameSocialClubRestart`, aspect
  16:9). The landing page script pressed A on Story.
- **The spot.** n2's stick cycles moved Arthur out of the cabin, and the game saved there. From then
  on Story loads on the cabin porch. With no stick input the game holds one fixed view of the porch,
  Arthur standing by the wall and the HUD hidden. pA, pB2 and pF all reach that view about 110–130 s
  after the press. pA and pF had no stick input. pB, pB2 and n2 moved Arthur, so their later
  gameplay is not comparable.
- **Windows.** Every arm is measured from 10 s after the porch view appears, all after
  `thermal: serious` (which came within 77 s of first frame):
  - 60 s windows for all three;
  - 300 s windows for pA and pF.

  Values: `[kk-gpu]` medians; `[xp]` totals over the window (cores, P share, GHz, mW of the process);
  the median `[xp-api]` x64→EC per second; `[srv]` requests/s and round-trip ms/s; the wineserver
  thread's CPU from `[xp-t]`. The script is `arm.py`, beside the runs in `.work/agent-notes/pla413e/`.
- **Noise.** Each arm is one run. The phone cooled about 7–9 min on its black screen between runs, but
  the clocks still moved between runs (P 1.5–2.0 GHz, E 1.45–1.7 GHz), so differences under about
  10 % are not shown.

## Runs

| Run | Arm | Directory (`.work/ui-runs/…`) | Result |
| --- | --- | --- | --- |
| pB | B | `20261020T215255-rdr2-pB` | jetsam `per-process-limit` 22:02:38 during the opening cutscene (press +391 s); no gameplay |
| pB2 | B (rerun) | `20261020T221324-rdr2-pB2` | 65 s of the porch view, then stick cycles outdoors; RDR2.exe `0xc0000005` at 22:22:00, `AV READ of 20` in thread 04e0 (press +349 s) |
| pA | A (defaults) | `20261020T223218-rdr2-pA` | porch view held to first frame+660 |
| pF | F `env.MADEIRA_FASTSYNC_SEM=0` | `20261020T225416-rdr2-pF` | porch view held to first frame+660; `[fastsync] … sem=off` |
| pG | G `env.FEX_HOSTFEATURES=enableafp` | `20261020T231649-rdr2-pG` | ran to first frame+660, but its host log could not be read: `pp phone pull` of `Documents/s1-host.log` (19 MB) wrote 0 bytes three times, and so did the 18.9 MB `s1-host.prev.log`; small files pulled. Not measured |

Arms C (`env.MADEIRA_ECO_NATIVE=1`), E (`env.MADEIRA_POWER_GOV_MW=2300`) and H (`cpu-count=4`) were
not run. Large pulls were failing, and the battery was at 25 % on battery power after five runs.

## Results, ranked by fps on the porch view

| Arm | Window | fps | GPU busy | gpu/frame | cores | P share | P / E GHz | mW | x64→EC/s | srv req/s | srv rt ms/s | wineserver thread |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **A** defaults | 60 s | **16.2** | 43 % | 26.5 ms | 2.50 | 6 % | 2.01 / 1.60 | 469 | 476 k | 1,617 | 649 | 6 % |
| **B** EC_RET, EC_BITMAP_CACHE, EC_EXIT_LEAN = 0 | 60 s | **14.8** (−9 %) | 38 % | 24.4 ms | 2.15 | 16 % | 1.93 / 1.70 | 596 | 285 k | 1,908 | 547 | 5 % |
| **F** FASTSYNC_SEM = 0 | 60 s | **13.0** (−20 %) | 38 % | 27.0 ms | 2.38 | 9 % | 1.74 / 1.54 | 458 | 447 k | 2,815 | 891 | 10 % |
| A defaults | 300 s | 15.7 | 42 % | 26.7 ms | 2.77 | 3 % | 1.63 / 1.54 | 412 | 570 k | 1,673 | 637 | 5 % |
| F FASTSYNC_SEM = 0 | 300 s | 13.9 (−11 %) | 39 % | 27.7 ms | 2.62 | 3 % | 1.53 / 1.45 | 363 | 482 k | 2,886 | 1,087 | 10 % |

In every arm the GPU is busy under half the time and nothing waits on present (present-wait 0.0 ms).

- **F: keep `MADEIRA_FASTSYNC_SEM=1`.** With it off, 1,200 more requests/s reach the wineserver,
  semaphore releases among them. The round trips rise from 640 to 1,090 ms/s and the server thread
  doubles to 10 % of a core. The game runs 11–20 % slower. Neither pA nor pF hung. r2's hang (sem on)
  did not recur in pA, n2 or pB2.
- **B: Madeira's lean ARM64EC transitions are worth about 9 %.** With them off, x64→EC transitions
  drop from 476 k to 285 k per second: each transition costs more, so fewer happen in the same time.
  That is a single 60 s window. One B run was killed in the cutscene and the other crashed later, so B
  is not proven stable; the crash (`AV READ of 20`) differs from n1's.
- **G** is unmeasured. AFP's effect was not settled.

## Where the CPU goes (host-only, n2's gameplay 21:22:20–21:27:20, and pA)

- **No thread is saturated.** RDR2's main thread (`-041c`) uses 23 % of a core. Twelve workers use
  9–21 % each (`-0450`, `-0454`, `-04f8`, `-04f4`, `-04fc`, `-0504`, `-0458`, `-0500`, `-04a0`, `-04e4`,
  `-0494`, `-045c`), and the wineserver thread 5 %. In all, 2.5–2.85 cores.
- **The work runs on E cores.** 90–98 % of the process's CPU time is on E cores, at 1.4–1.7 GHz. The P
  cores, 2–16 % of the time, run at 1.3–2.0 GHz at `thermal: serious`.
- **About 520,000 x64→EC transitions per second** (`[xp-api-top]`, 102 samples, symbols from the
  staged arm64ec DLLs), about 27,000 per frame:

  | Target | calls/s |
  | --- | --- |
  | ntdll `RtlEnterCriticalSection` + `RtlLeaveCriticalSection` | 145 k |
  | winevulkan `vkAllocateDescriptorSets` + `vkUpdateDescriptorSets` | 113 k |
  | winevulkan `vkCmdBindDescriptorSets`, `vkCmdBindVertexBuffers`, `vkCmdBindIndexBuffer`, `vkCmdBindPipeline`, `vkCmdDrawIndexed`, `vkCmdSetDeviceMask`, `vkCmdDrawIndexedIndirect`, `vkCmdPipelineBarrier`, `vkCmdDispatch`, `vkCmdDraw` | about 175 k |
  | ntdll `RtlQueryPerformanceCounter` | 43 k |
  | kernelbase `InitOnceExecuteOnce` | 17 k |
  | kernelbase `WaitForSingleObject`, `SetEvent`; kernel32 `timeGetTime` | 4–6 k each |

- **Wineserver requests, about 1,900/s:** `select` 812, `event_op` 402, `release_semaphore` 122,
  `lock_file` 99 and `unlock_file` 99 (the request enum of `include/wine/server_protocol.h`), `read` 62,
  `release_mutex` 37, `remove_completion` 32, `get_mapping_info`/`map_view`/`unmap_view` 16–24 each.
  The main thread makes 362/s of them, 98 ms/s of round trips.
- **What this suggests for the next port, not tested:**
  - transitions are the cost, not single-thread speed or the GPU. Next targets: critical sections
    entered and left without an x64→EC transition; descriptor-set allocation and update thunks in
    winevulkan, batched or made cheaper;
  - `lock_file`/`unlock_file` handled without the server (200 requests/s);
  - why the threads land on E cores.
