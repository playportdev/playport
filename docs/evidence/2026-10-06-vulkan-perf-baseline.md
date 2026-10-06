# Vulkan performance, step 1 (partial): first A/B on one IPA, stability counts, and the battery

**Date:** 2026-10-06. **Plan:** [Vulkan performance](../plans/2026-10-06-vulkan-performance.md),
steps 1 and 3 (one screening run). **IPA:** dev `18805415…` (`1880541585…951a`), the
step-0 build, for every run below. Run directories: `$PLAYPORT_BUILD/perf-runs/vk-*`.
Settings per the plan's protocol (`graphics` dxmt / vulkan / vulkan with
`-force-d3d12`), Metal HUD on unless said, counters on.

**What limited this session.** The phone started the session at 71 % with no charger
and nobody at it. The protocol wants every run of a comparison to start above 50 %; only
the first two burst runs did. Decision (unattended): measure one ABCCBA burst set at
720/free anyway, recording the charge of each run, then spend the rest on stability, and
stop phone work at about 15 % (`pp phone status` warns from 20 %). The capped (720/60),
sustained and native/free cells of the matrix, the third repeat of every cell, and the
attribution GPU captures in play were **not run**. Every figure below is one or two runs
and is a screening result, not the plan's baseline.

## Burst window, 720 rows, free-running (ABCCBA)

Route `pp perf --secs 120 --cool 15 --cool-max 20 --pad first-frame+25:hk-new-game
--pad first-frame+45:hk-walk`; every run started at thermal `nominal`. Window t = 60–100 s
(`pp perf --compare … --window 60:100`); Mi/f is all threads from `threads.txt`.

| run | charge | HUD | FPS | p99 ms | ≥25/50/100 | GPU ms | til% | Mi/f | CPU mW | srv/f | MiB | first frame |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-b1-dxmt-free1` | 57→55 | on | 118.3 | 8.34 | 2/1/1 | 5.62 | 58 | 52.3 | 1645 | 11.6 | 2503 | 8.65 s |
| `vk-b1-dxvk-free1` | 53→50 | on | 115.4 | 16.67 | 17/2/1 | 5.81 | 76 | 61.8 | 1989 | 18.0 | 3211 | 8.38 s |
| `vk-b1-vkd3d-free1` | 49→46 | on | 114.5 | 16.67 | 15/3/2 | 5.91 | 76 | 65.7 | 2052 | 22.4 | 3043 | 13.06 s |
| `vk-b1-vkd3d-free2` | 45→42 | on | 116.4 | 16.67 | 11/1/1 | 5.94 | 77 | 68.3 | 2180 | 23.1 | 3023 | 8.59 s |
| `vk-b1-dxvk-free2` | 41→38 | **off** | 115.8 | – | – | – | 76 | 58.4 | 1833 | 18.3 | – | 9.18 s |
| `vk-b1-dxmt-free2` | 37→36 | **off** | 117.7 | – | – | – | 49 | 51.3 | 1606 | 12.0 | – | 8.99 s |

- The last two ran without the Metal HUD by accident: an unattended run rests the phone
  on the black screen while it cools, and that launch named no session, so the app undid
  the HUD switch and the settings' session record (fixed in `tools/phonelib.py` and
  `tools/perf.py` in this branch). They serve as the plan's HUD-off control: DXVK's
  work a frame is 14 % over DXMT's with the HUD off (58.4 / 51.3) and 18 % with it on
  (61.8 / 52.3), so the HUD does not make the gap.
- The phone's mW column (`sysmW`, the battery gauge every ~20 s) jumps between runs by
  more than the backends differ; it is left out.

**Against the plan's burst criterion** (FPS ≥ DXMT − 1, p99 ≤ DXMT's, Mi/f ≤ +5 %,
GPU ms ≤ +5 %), from these single runs:

| | FPS | p99 | Mi/f | GPU ms |
|---|---|---|---|---|
| DXVK | −2.9 (HUD on), −1.9 (off): **behind** | 16.67 vs 8.34: **behind** | +18 % on / +14 % off: **behind** | +3.4 %: within |
| vkd3d | −3.8, −1.9: **behind** | 16.67: **behind** | +26 %, +31 %: **behind** | +5.2 %, +5.7 %: at the line |

## The gap, by thread (burst window, Mi/f at t = 75 and 90 s)

| thread | DXMT | DXVK | vkd3d |
|---|---|---|---|
| main (`002c`, guest) | 17.7 / 16.6 | 18.1 / 16.7 | 18.8 / 17.1 |
| UnityGfxDeviceWorker | 9.5 / 9.0 | 12.2 / 11.5 | **20.1 / 18.8** |
| backend's submit thread | `dxmt-encode-thr` 4.3 / 4.1 | `dxvk-cs` 5.2 / 4.9 | (vkd3d's own threads under 2) |
| wineserver (`m…`) | 3.2 / 3.0 | 4.3 / 4.1 | 5.4 / 5.2 |
| other native threads (Metal completion, dxvk-submit) | ~1 each | ~2 each, three or four of them | ~2 each |

- **wineserver requests a frame: 11.9 (DXMT) → 18.2 (DXVK) → 22.9 (vkd3d).** The six
  extra on both Vulkan routes are `get_window_parents`, `get_window_rectangles` and
  `get_windows_offset`, two of each a frame: `win32u_vkQueuePresentKHR` calls
  `client_surface_update` before the present and `client_surface_present` after it, and
  each runs `client_surface_update_locked` (`NtUserGetAncestor` and
  `get_client_surface_rects`). A Wine lever (step 8); vkd3d adds `set_queue_mask`,
  `get_message` and more `event_op`.
- **vkd3d's UnityGfxDeviceWorker does twice DXMT's work** (+10 Mi/f): Unity's D3D12
  renderer and vkd3d-proton's command recording on the same thread. The largest single
  gap on the D3D12 route.
- **DXVK's CS thread** (`perf-runs/vk-prof-dxvk3`, the step-0 profile): more of it is
  in Apple's driver (AGX, IOGPU, Metal, objc: 3.6 % of all samples) than in
  KosmicKrisp (1.2 %) or DXVK's own d3d11 (1.1 %); memset and memmove 1.0 %.
- **GPU:** the burst GPU ms is within 3–6 %, but the tiler is busier (76 % against
  49–58 %) and the frame has one more full-screen pass and a compute dispatch at present
  ([step 0's capture](2026-10-06-vulkan-perf-tooling.md#03-gpu-capture-on-kosmickrisp)).
- **Memory:** Metal plus app memory is about 700 MiB higher on Vulkan (3.0–3.2 GiB
  against 2.5 GiB).
- **KosmicKrisp's record-twice cost (plan step 4.1) is not there for DXVK's primaries:**
  KosmicKrisp's command trampolines (`kk_dispatch_cmd_gen.py`) already skip the
  `vk_cmd_queue` copy when the buffer began with `ONE_TIME_SUBMIT`, which DXVK sets
  (`dxvk_cmdlist.cpp` 157). Secondaries (DXVK's tiler mode) are still queued and
  replayed. vkd3d-proton begins its command buffers with `ONE_TIME_SUBMIT` only under
  `VKD3D_CONFIG=one_time_submit`, so on the D3D12 route every command is recorded twice:
  a step-3 lever (`graphicsOptions` `VKD3D_CONFIG=one_time_submit`), to be screened with
  an image check, since a D3D12 list submitted twice would then replay nothing.

## Stability

Plays through New Game and the walk to `first-frame+60`, no cooling between them
(`perf-runs/vk-st-*`), 720/free unless said:

| route | plays | reached ff+60 | failures |
|---|---|---|---|
| DXVK 720 | 5 | 4 | `vk-st-dxvk-720-3`: hung after the JIT pool was blessed, before the runtime started (no Vulkan code had run): a launch failure, not a graphics one |
| DXVK native | 5 | 5 | none (the phone was hot: these ran back to back, power budget 769 mW, so their frame rates are not figures) |
| vkd3d 720 | 5 | 0 | `-2`: `0xc0000005` 1 s in (main thread, ntdll ARM64EC `RtlRunOnceComplete` area, from kernelbase's thunk, a wild INIT_ONCE pointer `0x1280000836002500`): the known D3D12 start fault. `-1`, `-3`, `-4`, `-5`: `0xc0000005` at 54 s (below) |
| DXVK, `dxvk.tilerMode=False` | 1 | 0 | `0xc0000005` at 54 s (below) |

The six burst runs (120 s, charge 36–57 %) all ran to the end, and none of them,
nor the ten DXVK plays at the default options (charge 36 → 22 %), ended early.

**The failure at 54 s**, in all five where it happened: a `wine_threadpool_worker` reads
through a NULL pointer at ntdll `arm64x_check_call` (an indirect call to a NULL target),
in a frame whose handler is DXVK's `d3d11.dll` C++ personality; before it, the main
thread takes first-chance write faults in mono's GC pages, which mono handles. It came
in four of five D3D12 plays (charge 22 → 17 %) and the one play of DXVK without tiler
mode (12 %), and in none of the ten DXVK plays with DXVK's defaults just before them
(the last at 23 → 22 %), so the route and the option separate it better than the charge
does. The two D3D12 burst runs at 49–42 % did not end early, but they did not stop at the
same point either. Open: it needs the plays repeated on a charged phone (step 2).

**A tooling gap it showed:** `pp ui` reported `ok` for these plays (`until
first-frame+N`) because the app restarts itself after a title fails and the watch
reached `--until` in the new process. `tools/ui.py` now fails such a run with
`the title ended before the stop condition: exit=0xc0000005 after_s=54`, from the
launch's `title: done` line.

The plan's 10/10 bar is not met on either route, and the D3D12 route reached
`first-frame+60` 0 of 5 times in this session.

## Step 3, first screening: `dxvk.tilerMode=False`

One run (`vk-s3-dxvk-notiler1`, charge 12 → 10 %): the option reached DXVK
(`Found config env: dxvk.tilerMode = False`), the menu and King's Pass ran at 117–120 FPS
with GPU 4.5–6.2 ms, and the game ended at 54 s with the failure above. Not screened;
repeat on a charged phone.

## Cause of the failure at 54 s, and a fix not yet run on the phone

The faulting thread's return address is in DXVK's `d3d11.dll`
`DxvkResourceAllocation::initKmtHandles` (`+0x17f9f4`), just after a `blr x8` through a
function pointer loaded as NULL: `vkGetMemoryWin32HandleKHR`. KosmicKrisp offers no
`VK_KHR_external_memory_win32`, so `DxvkImage::canShareImage` refuses to share the
texture and `m_shared` is false, but `allocateStorageWithUsage` still hands the sharing's
handle type to the allocator, which then asks for the handle. The texture is Media
Foundation's (the failing plays load `mfplat`, `mfreadwrite` and `winegstreamer`; the
DXVK plays with DXVK's defaults that ran on did not load them in their 60 s), so the
video Hollow Knight plays after New Game is the trigger, and the route and tiler mode
change only whether the video starts within the window. DXVK `master` has the same code.

`patches/dxvk` 0001 (decision 0061) passes the handle type only for a shared image, and
calls `DxvkFence::initKmtHandles` only for an exportable semaphore. It builds (IPA
`296886d4…`, `pp test` passed) and **was not run on the phone**: the battery was at 10 %
with nobody to charge it.

## 2026-10-06 22:27 – 2026-10-07 01:55: on a charged phone

IPA `eb825d16…` (HEAD `4fa21de`, with `patches/dxvk` 0001) for the plays below until
said otherwise. The gate (Hollow Knight and Portal 2 to `first-frame+10`, one locked
session, `ui-runs/20261006T222756`, `…T222851`) passed.

### Correction: the 60 s stability plays ended in the opening cinematic

Profile 1 on the phone no longer holds a save: from 19:53 on, every run's log loads the
video path (`mfplat`, `winegstreamer`; none before), and a probe with screenshots
(`perf-runs/vk-route-probe`, DXMT) shows the profile screen with slot 1 empty, so
`hk-new-game` starts a new game: the calibration screens and the prologue cinematic, with
the Knight in control at about `first-frame+75`. The plan's route pushes `hk-walk` at
`first-frame+45`, which replaces `hk-new-game` (53.5 s long) before its presses skip the
cinematic. So the plays `vk-s2-vkd3d-*` and `vk-s2-dxvk-*` (and `vk-st-vkd3d-*`,
`vk-s3-dxvk-notiler1` before them) ended inside the cinematic (25–37 FPS from t = 45 s),
not in play. What they show is that the start and the video run; they are not gameplay
stability.

- With `patches/dxvk` 0001 the video no longer ends the game: 10 of 10 DXVK and 8 of 8
  started D3D12 plays ran through it to `first-frame+60` (`vk-s2-*`), where 5 of 6 such
  plays had ended with `0xc0000005` at 54 s before it.
- 2 of the 10 D3D12 plays (`vk-s2-vkd3d-2`, `-7`) ended 1 s in, as `vk-st-vkd3d-720-2`
  had (below).

**Route v2** (owner, 2026-10-07: cut the testing to the minimum; the gaps are clear):
`--pad first-frame+25:hk-new-game --pad first-frame+80:hk-walk`, a screenshot at the end
(`.work/agent-notes/vulkan-perf/route.sh`). Every run is a new game, as the plan wanted.

### Stability on route v2 (to `first-frame+140`, no cooling between plays)

| play | result | last screenshot |
|---|---|---|
| `vk-s2b-vkd3d-1` | `0xc0000005` 1 s in | – |
| `vk-s2b-dxvk-2` | ran to the end | (play) |
| `vk-s2b-vkd3d-3` | ran to the end | (play) |
| `vk-s2b-dxvk-4` | ran to the end | (play) |
| `vk-s2b-vkd3d-5` | ran to the end | the Knight in King's Pass past the first crawlid, HUD 69.5 FPS |
| `vk-s2b-dxvk-6` | ran to the end | (play) |

DXVK 3 of 3 in play; D3D12 2 of 3, the third the start fault. These ran back to back from
`serious` thermal, so their frame rates (70–90 FPS by the end) are not figures.

### The D3D12 start fault (3 of 13 starts with `patches/dxvk`)

The main thread faults in ntdll's `RtlRunOnceComplete` (`ntdll.dll+0x677b8`, `ldr x19,
[x1]`) on a wild pointer (`0x1280000836002500`; `0x850fc08548e08b4c`, which is x86 code
bytes `4c 8b e0 48 85 c0 0f 85`), called through kernelbase's `InitOnceComplete` from
UnityPlayer `+0x2616dd`: `InitOnceBeginInitialize(&once, …)` on a static once
(UnityPlayer `+0x1f0b5f8`), two init calls, then `InitOnceComplete`. Wine's run-once queues
a waiter by pointing the once at a variable on the waiter's stack, and the completer
reads that variable before releasing the waiter. A pointer into garbage there means the
waiter's frame was gone before its release: its `NtWaitForKeyedEvent` returned without
one.

A first fix (`patches/wine-pe` 0029, first form, IPA `befd6896…`) made the waiter wait
again until the wait returned success. The gate passed on it (`ui-runs/20261006T235*`),
but then **7 of 7 D3D12 starts hung**: the game started (`+3.45 s`), logged its pool and
band once at about `+5 s`, and never drew a frame; `pp ui` was ended by its 15-minute
timeout each time, so no log was pulled. An eighth ended with the app gone, and then the
phone dropped off the network (`pp phone status`: no phone); it needs a person. Reading:
the wait does return without a release here, at once and every time, so the waiter
spun. 0029 is now a diagnostic only (Wine's behaviour, plus the first 16 such statuses
logged as `once %p: keyed wait returned %#lx without a release`), built (IPA from
`pp build` at 01:54) and **not run on the phone**. The next run of D3D12 starts on it
names the status; the fix follows from that (the keyed event in the one-process runtime,
`keyed_event` and the in-process server's keyed-event wait, are where to look).
