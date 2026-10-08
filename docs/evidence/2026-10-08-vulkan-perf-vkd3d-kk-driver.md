# Vulkan performance: vkd3d-proton's submission barrier buffer on KosmicKrisp (not kept)

**Date:** 2026-10-08. **Plan:** [Vulkan performance](../plans/2026-10-06-vulkan-performance.md)
(PLA-72), vkd3d-proton's CPU power at 720/60. **Decision:**
[0067](../decisions/0067-vkd3d-kk-no-barrier-buffer.md) (not accepted). **Result:**
`patches/vkd3d-proton` 0005 took effect: KosmicKrisp committed fewer empty Metal command
buffers. It did not move CPU power, work a frame or any thread's work, and was **not kept**.

## The change

`patches/vkd3d-proton` 0005 (commit `d911430`) added `VK_DRIVER_ID_MESA_KOSMICKRISP` to
`vkd3d_driver_implicitly_syncs_host_readback()` (`libs/vkd3d/command.c`). Without it,
vkd3d-proton appends a reusable `SIMULTANEOUS_USE` full-barrier command buffer to every
`ExecuteCommandLists` submission. A Metal command buffer can be committed only once, so
KosmicKrisp re-records that buffer into a new, empty Metal command buffer on every later
submission (`kk_queue.c`, `rerecord_and_commit_cmd_buffer`). With the patch, vkd3d-proton
serializes each queue's submissions with a binary semaphore instead, as it does on RADV, AMD
and NVIDIA. The decision record has the code reading, and why the order and the host's view
of GPU writes are kept.

IPAs (dev):

- control: `b024e1f756b9520af7253bd5eed3e7d476908c60c555bd39e56d698722e57b1a` (commit
  `80d48bf`) for `vk-60w-vkd3d-ctl-1`. The builds below pruned it from the build area, so
  the rerun control used `4554db58bcbbed77651dee72238c0ee72bc014586f83d3281af2ea5566a5eec5`,
  built from `f6b726c`. Its build records equal `b024e1f7…`'s (same `d3d12core.dll`, sha256
  `be5c48fb…`), and only the provenance differs.
- change: `18d0ea5415f7066917d02b7f40b003fea06e51d1b69b93cee32d0caaad8805b6` (commit
  `544450d`, 0005 and its build record). `pp test` passed, and `pp build` verified the IPA
  (80 checks).

## Runs

Phone: iPhone18,4, iOS 27.0, on the charger at 100 %, unattended. The protocol is the
owner's warm pair: route v2 (a new game, `hk-walk` at `first-frame+80`, 130 s,
`--shot first-frame+128`), Hollow Knight on the Direct3D 12 route,
`{"screen":"720","frameLimit":60,"graphics":"vulkan","arguments":"-force-d3d12"}`, no
`--cool`, and window t = 85–125 s. Run directories are `$PLAYPORT_BUILD/perf-runs/<name>`.

Session 1 (one lock): `vk-60w-vkd3d-ctl-1` on `b024e1f7…`, `pp install --no-build`, the gate,
then `vk-60w-vkd3d-0005-1`.

- **`vk-60w-vkd3d-ctl-1` is void.** Its log has `hostio: Metal HUD off` (PLA-82), so it has no
  frame-time or GPU figures. It also started at thermal `nominal`, and its change run at `fair`.
- The rerun was allowed once. Session 2 meant to reinstall `b024e1f7…` first, but that IPA
  had been pruned (`pp build` keeps three outputs). The install failed, and the run went
  ahead on the installed change IPA. It is kept as a second change run, renamed
  `vk-60w-vkd3d-0005-2`.

Session 3 (one lock) is the pair this record reads: `pp install` of `4554db58…`,
`vk-60w-vkd3d-ctl-3`, `pp install` of `18d0ea54…`, then `vk-60w-vkd3d-0005-3`. Both runs
started at thermal `fair` and stayed there, with no thermal pressure, so the pair compares.
No run except `ctl-1` has a `Metal HUD off` or `ui: undo session … metalHUD` line.

## Results (`pp perf --compare … --window 85:125`)

| run | IPA | thermal | FPS | p99 | ≥25/50 | GPU ms | gpu% | Mi/f | CPU mW | CPU mJ/f | sys mW | sys mJ/f | srv/f |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-60w-vkd3d-ctl-3` | `4554db58…` | fair | 59.9 | 25.01 | 94/0 | 9.52 | 71.1 | 79.9 | 793 | 13.2 | 3794 | 63.3 | 23.7 |
| `vk-60w-vkd3d-0005-3` | `18d0ea54…` | fair | 59.9 | 25.01 | 166/0 | 8.46 | 66.1 | 81.9 | 792 | 13.2 | 3328 | 55.6 | 24.7 |
| `vk-60w-vkd3d-ctl-1` (void, HUD off) | `b024e1f7…` | nominal | 59.9 | – | – | – | 67.4 | 75.7 | 694 | 11.6 | 3768 | 62.9 | 23.3 |
| `vk-60w-vkd3d-0005-1` | `18d0ea54…` | fair | 59.9 | 25.01 | 76/0 | 9.45 | 71.4 | 80.2 | 751 | 12.5 | 3880 | 64.8 | 23.6 |
| `vk-60w-vkd3d-0005-2` | `18d0ea54…` | fair | 60.0 | 25.01 | 160/0 | 9.51 | 71.3 | 80.1 | 785 | 13.1 | 4655 | 77.6 | 23.9 |

Per-thread Mi/f in t = 85–125 s, summed over the window from the run's raw thread counters
(`perf.py`'s thread sampling over one 40-s window, not the 15-s buckets of `threads.txt`, so
the totals differ slightly from the Mi/f column above):

| run | all | main (`002c`) | UnityGfxDeviceWorker | `00ec` | wineserver | vkd3d_queue |
|---|---|---|---|---|---|---|
| `vk-60w-vkd3d-ctl-3` | 77.4 | 21.32 | 18.62 | 11.34 | 7.03 | 0.82 |
| `vk-60w-vkd3d-0005-3` | 79.0 | 21.68 | 18.95 | 11.59 | 7.22 | 0.83 |
| `vk-60w-vkd3d-ctl-1` (void) | 75.8 | 21.75 | 18.09 | 11.14 | 6.92 | 0.68 |
| `vk-60w-vkd3d-0005-1` | 77.6 | 21.14 | 18.49 | 11.38 | 7.04 | 0.81 |
| `vk-60w-vkd3d-0005-2` | 77.1 | 21.35 | 18.35 | 11.29 | 7.02 | 0.81 |

- **The change took effect.** KosmicKrisp logs its first 40 Metal commits
  (`[kk-queue] commit done … gpu=`). Of those 40, 20 had no GPU time on the control IPA
  (`ctl-1`, `ctl-3`), alternating with the game's work. On the change IPA 13 did, in all three
  runs. The barrier buffers are gone, and what is left is the game's own empty work. No run
  logged a command-queue error or device loss.
- **CPU did not move.** In the warm pair, CPU power is 793 against 792 mW (13.2 mJ/f
  each). Work a frame is 79.9 against 81.9, and every thread is within ±0.4 Mi/f. The
  vkd3d_queue thread is 0.82 against 0.83 Mi/f: vkd3d-proton submits there, and the re-record
  cost there was below what one run resolves. The three change runs span 751–792 mW and
  80.1–81.9 Mi/f, which covers the control.
- **GPU ms** fell 9.52 → 8.46 in the pair, but `0005-1` and `0005-2` read 9.45 and 9.51, so
  that is noise. Phone mW (3794 → 3328) comes from the battery gauge, one sample every 5 s,
  and `0005-2` read 4655 on the same IPA. It is not read as a gain.
- ≥ 25 ms frames: 94 on the control, 76–166 on the change runs (176 on the cooled reference
  `vk-60-vkd3d-1`). None reached 50 ms.
- **Rendering.** The end screenshots of `ctl-3` and `0005-3` show the same frame: King's Pass
  at 1564×720 with the HUD, the Knight in play, the HUD at 59.7 and 59.2 FPS.

**Not kept** (rule 4): the change took effect, removing about one empty Metal commit per
submission, but CPU power, work a frame and the submitting thread are unchanged. vkd3d's
+45 % CPU power at 720/60 is not in vkd3d-proton's submission path, which the profile already
showed: the worker's FEX and guest time, 13.5 % of samples
([profile](2026-10-08-vulkan-perf-profile.md)). The patch file and its series line are
removed together, and its build record is restored.

## Gate (on `18d0ea54…`, session 1)

| play | run | first frame | result |
|---|---|---|---|
| Hollow Knight, default (`{}`: Vulkan, DXVK) | `ui-runs/20261008T094755` | +9.28 s (JIT 2.67 s) | `first-frame+10` |
| Hollow Knight, `{"graphics":"dxmt"}` | `ui-runs/20261008T094847` | +8.84 s (JIT 2.48 s) | `first-frame+10` |
| Hollow Knight, `{"graphics":"vulkan","arguments":"-force-d3d12"}` | `ui-runs/20261008T094939` | +9.42 s (JIT 2.70 s) | `first-frame+10`, title menu drawn |
| Portal 2, default (DXVK, i386) | `ui-runs/20261008T095032` | +5.92 s (JIT 2.57 s) | `first-frame+10`, Source intro drawn |

## Games observed

- Hollow Knight (367520): the gate on `18d0ea54…` (Vulkan, DXMT and Direct3D 12), and 720/60
  Direct3D 12 runs: `vk-60w-vkd3d-ctl-1` (`b024e1f7…`, void, HUD off), `vk-60w-vkd3d-ctl-3`
  (`4554db58…`), and `vk-60w-vkd3d-0005-1`, `-2` and `-3` (`18d0ea54…`). Every one ended in
  play.
- Portal 2 (620): the gate on `18d0ea54…`, `first-frame+10`.
