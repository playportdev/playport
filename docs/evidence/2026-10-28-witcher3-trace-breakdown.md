# The Witcher 3 4.x in a Metal System Trace: E cores saturated, Wine's network and path lookups on the main thread, KosmicKrisp's command-buffer heaps and residency commits (PLA-455)

**Linear:** [PLA-455](https://linear.app/playportdev/issue/PLA-455) (the frame rate; the tasks below are its
sub-issues); [PLA-459](https://linear.app/playportdev/issue/PLA-459) (the lighting dispatch);
[PLA-457](https://linear.app/playportdev/issue/PLA-457) (the Mac session).
**Question:** what does the 15 s Metal System Trace of
[2026-10-28-mac-gpu-tools-scripted](2026-10-28-mac-gpu-tools-scripted.md) (run `mst1`) show about The
Witcher 3's (app-292030) CPU threads, its graphics memory and the GPU, beyond the per-encoder profile? Which
of those can Playport change?
**Result:**
- **CPU-bound under the trace.** All four E cores ran 100 % of the window, and the S cores took 0.1 % of
  the samples (62). The GPU was busy 39 % of the time (21.6 ms of GPU work per 53.7 ms frame, 18.7 fps).
  The tools themselves took about 13 % of the CPU (`DTServiceHub`, `remotepairingdeviced`), so the CPU has
  little headroom. Without them, `pp perf` shows the GPU 77–84 % busy ([witcher3-perf](2026-10-28-witcher3-perf.md)).
- **The game's main thread spends 38 % of its samples in Wine host code it does not need.** 27 % goes to
  `nsi_enumerate_all_ex` → `ifinfo_enumerate_all` → `getifaddrs` (an adapter-table query, served by
  `patches/wine-unix` 0019 with one `getifaddrs` per interface). 11 % goes to `stat` in `get_dos_device`
  (path resolution).
- **KosmicKrisp creates and destroys 74 Metal heaps a second (176 MB/s).** These are command-buffer
  allocations larger than its 128 KiB upload BO. One of them is a 5.95 MiB buffer per frame for a
  `vkCmdCopyImage2` that goes through a buffer.
- **The two worst frames are residency-set commits.** KosmicKrisp commits its residency set (about 510
  allocations, 2.31 GiB) 295 times a second. Two commits took 212 and 229 ms, and they made the two 258 ms
  frames.
- **Register spills are everywhere.** The lighting dispatch (asc60) spills 192 bytes, and so does nearly
  every render encoder (16–320 bytes). Encoders that report a spill take 36 % of the GPU time.

Results from Apple's tools cannot be rerun on the workstation (decision
[0031](../decisions/0031-a-mac-for-analysis-only.md)). The tasks they lead to are filed for the workstation
in [§ 6](#6-tasks).

## Setup

- **Trace:** `$PLAYPORT_BUILD/mac/auto/mst1/metal-system-trace.trace`, recorded by
  `pp gpu live --any-build --title app-292030 --secs 100 --pad first-frame+10:witcher3-continue --pad
  first-frame+60:witcher3-walk --trace 'Metal System Trace' --trace-at first-frame+70 --trace-secs 15`.
- **Phone:** iPhone Air (iPhone18,4), iOS 27.0.1, cabled. The trace's thermal state is *Serious*
  throughout. Instruments induced the GPU's *Medium* performance state (9.35 s of the window).
- **IPA:** the installed dev build (0.4.0). Its sha256 is not recorded (`--any-build`, no install record on
  the Mac).
- **Game:** the Kaer Morhen save, walking. It renders at 1302x600 (`[kk-wsi] create chain`) under the
  compatibility default:
  - `FEX: pause mode=0 (yield)`;
  - `PLAYPORT_VK_HEAP_MB=3072`;
  - `MESA_KK_BATCH2` unset.
- **Method:** each table was exported with `xcrun xctrace export --xpath …/table[@schema="…"]` into
  `mst1/x/`. Scripts in `$PLAYPORT_BUILD/agent-notes/w3-mac/` resolve the id/ref references
  (`xtr.py`, `an1.py`–`an13.py`).

Symbols: the profile names KosmicKrisp, Wine's unix side, Playport's host and Apple's frameworks. It
attributes JIT code (the game, FEX's output, ARM64EC PE code) to the nearest S1Probe symbol
(`host_pool_reserve`) or to nothing. "JIT" below means those samples.

## 1. Where the CPU goes

62,477 samples at 1 ms, all `Running`, spread evenly over CPU 0–3 (E cores, 15.6k each). Shares are of all samples:

| Process | % |
| --- | ---: |
| S1Probe | 68.1 |
| kernel | 9.7 |
| DTServiceHub (Instruments) | 7.6 |
| remotepairingdeviced | 5.1 |
| audiomxd, MTLCompilerService, backboardd, others | 9.5 |

| S1Probe thread | % of all | JIT | Named native code worth noting |
| --- | ---: | ---: | --- |
| RenderThread `90ee` | 17.7 | 77 % | `kk_UpdateDescriptorSets_impl`, AGX encoding, `kk_draw` (≤ 1 % each) |
| MainThread `9001` | 10.9 | 46 % | **`ifinfo_fill_entry`/`getifaddrs` 27 %, `stat` 11 %** |
| RenderDispatcher1 / 2 | 5.5 / 5.0 | 78 / 75 % | `0x43010000` frame 3 / 17 % (unresolved) |
| redTask1–3, `903d` | 2.5–3.5 each | 98–99 % | |
| `9263`, `900d`, `94c5`, `910e` | 1.3–2.6 each | 55–60 % | `IOGPUCommandQueueSubmitCommandBuffers` 17–20 % |
| `8fe1` | 1.4 | 41 % | `fstatat`/`getattrlistat` in `find_file_in_dir` 58 % |
| vkd3d_queue `90ff` | 0.6 | 27 % | `iokit_user_client_trap` 62 % (residency-set commit) |

**The main thread's network query.** It has 948 samples in `ifinfo_fill_entry` and 885 in `getifaddrs`
(plus 49 in `socket`), 13.9 % + 13.0 % + 0.7 %. The stack is
`nsi_enumerate_all_ex` → `ifinfo_enumerate_all` → `ifinfo_fill_entry` → `getifaddrs`, and also
`update_if_table` → `if_nameindex` → `sysctl`. So the game, or a library it loads, asks for the adapter
table (`GetAdaptersAddresses`, `GetIfTable2` or similar) often enough to keep 0.43 cores' main thread a quarter
busy. With `patches/wine-unix` 0019, `ifinfo_fill_dynamic` calls `getifaddrs` once **per interface**
(iOS lists 20–30: `utun*`, `ipsec*`, `awdl0`, `llw0`, `pdp_ip*`, `en*`, …), so one enumeration costs N
full `getifaddrs` calls. Which guest caller does it, and how often, is not known.

**Path lookups.** The main thread has 745 samples in `stat` from `get_dos_device` ←
`nt_to_unix_file_name_no_root`: every NT path it opens or queries stats `dosdevices/<drive>:` again.
`server_open_file_object` → `NtCreateFile` → `NtClose` adds 91 more. Thread `8fe1` has 422 samples in
`fstatat` from `find_file_in_dir` ← `lookup_unix_name` ← `NtCreateFile`, and 64 in `getattrlistat`
(`get_dir_case_sensitivity`). That is the scan for a name whose case differs from the file's: the
container's file system is case-sensitive.

**Later correction (PLA-461):** those stacks did not identify the paths, and the
interpretation above was wrong. Ordinary drive paths already skip the prefix
`stat`. A [60 s gameplay file trace](2026-10-28-nsi-device-probes.md) instead finds
25,533 probes of the absent `\\.\Nsi` device on MainThread and 1,066 opens of
Playport's missing session `control` file. Missing files also trigger the
case-insensitive search; the trace did not establish a wrong-case game asset.

**Spinning.** RenderThread is the busiest thread (0.71 cores) while every core is busy. The Linux
`--cpu-prof` run attributes its time to the command-ring wait loop at `witcher3.exe+0x1c69ae0`, which
calls QPC and `pause` ([witcher3-perf § 1](2026-10-28-witcher3-perf.md#1-what-limits-it)). This trace
cannot see guest frames. Its share fits that account: a spin that never gives up its core takes it from
the runnable threads.

**Playport's own host code** (small):
- `mincore` in `ios_process_memory_log` (thread `8f50`, 203 samples, 0.5 % of S1Probe);
- `open` in `session_reply` ← `wine_host_session_wait` ← `LaunchCoordinator.run` (131 samples), one
  file open per wait.

## 2. GPU occupancy and frames

- **Displayed intervals:** 288 in 15.4 s, 18.7 fps. Mean 53.7 ms, median 50.0 ms, p90 83.4 ms; 14 over
  100 ms, the longest 283 ms.
- **GPU work:** the union of S1Probe's vertex, fragment and compute intervals is 6.22 s of the 15.77 s,
  39.4 %, or 21.6 ms a frame. It is idle in 539 gaps over 1 ms, 7.07 s in total; the largest gaps are 263,
  247, 227 and 222 ms.
- **Per channel:** compute 2.63 s, fragment 2.08 s, vertex 1.52 s.

## 3. KosmicKrisp's command-buffer heaps

`metal-resource-allocations`: in 15.8 s, 1,169 heap allocations (2.78 GB) and 1,148 deallocations. Every
heap lived 136–225 ms (p10–p90), about three frames. By allocation backtrace:

| Backtrace | Size | Count | MB |
| --- | --- | ---: | ---: |
| `kk_alloc_bo` ← `kk_pool_alloc` ← `kk_CmdCopyImage2` | 5.95 MiB | 290 | 1,726 |
| `kk_draw` ← `kk_CmdDrawIndexed` | 1.3–2.1 MiB (pairs) | ~550 | 985 |
| `kk_CmdDraw` | 208–288 KiB | ~290 | 69 |
| `kk_cmd_pool_alloc_bo` ← `kk_dispatch_precomp` ← `kk_CmdResetQueryPool` | 128 KiB | 8 | 1 |

**The cause.** In `kk_cmd_buffer.c`, `kk_pool_alloc` handles anything over `KK_CMD_BO_SIZE` (128 KiB) as a
fresh `kk_alloc_bo` appended to `cmd->large_bos`, and destroys it at reset. Only 128 KiB BOs are recycled
(`pool->free_bos`).

**The callers.**
- `kk_CmdCopyImage2` takes the copy-through-buffer path when `can_do_image_to_image_copy` fails (source and
  destination formats differ, or the sample counts differ). Its buffer is one 1300x600 surface at 8 bytes a
  texel (6,240,000 B = 5.95 MiB), allocated once a frame. **Later (PLA-463):** the copy is the depth of
  the `D32FS8` depth/stencil target into an `R32F` image, which no texture view can do; the buffer is sized
  from the 8-byte format but filled at 4 bytes a texel
  ([kk-depth-copy-staging-size](2026-10-28-kk-depth-copy-staging-size.md)).
- In `kk_draw`, the allocations that size with draws are the tessellation/geometry emulation's output
  buffers (`poly_tcs_in_size`, the tessellation `alloc`).

**The cost.**
- Each heap is a kernel allocation, page zeroing and wiring.
- Each heap is also an add and a remove in the residency set, so the set changes every frame (§ 4).

## 4. Residency-set commits

`metal-residency-set-interval`: one residency set (`ResidencySet … commit (503–518 allocations, committed
2.30–2.32 GiB)`) committed 4,666 times in 15.8 s, about 16 times a frame:
- the median commit takes 1.8 µs;
- 236 commits take over 1 ms, 812 ms in total;
- two take **212 ms** (t = 0.90 s) and **229 ms** (t = 6.04 s).

The vkd3d_queue thread's `iokit_user_client_trap` samples are these commits:
`kk_queue_submit` → `kk_device_make_resources_resident` → `mtl_residency_set_commit` → `IOGPUResourceGroupUpdateResources`.

**Hitches.** Of the 14 displayed intervals over 100 ms, the two 258 ms ones overlap those two commits
(209 and 213 ms of commit inside each). The other twelve (100–283 ms) have 1–4 ms of commit and 28–43 ms
of GPU work, so something else stalls them. No large allocation lies near either long commit: no heap over
8 MiB within −400/+250 ms. Why those two commits took 200 ms (memory pressure on 2.3 GiB of wired memory,
the Serious thermal state) is not known.

**Batching does not help as it stands.** `MESA_KK_BATCH2`'s `residency` item (`patches/mesa` 0091) commits
only when the set changed. But § 3's churn changes it every frame, which may be why `MESA_KK_BATCH2=1`
measured no gain ([witcher3-perf § 3](2026-10-28-witcher3-perf.md#3-runs)).

## 5. Graphics memory and spills

**Memory.**
- `metal-current-allocated-size`: S1Probe held 2,378–2,404 MB of Metal allocations throughout, against
  `PLAYPORT_VK_HEAP_MB=3072`.
- `metal-wired-sysmem-level-interval`: up to 2,811 MB wired.
- The owner's earlier walk ended in vkd3d-proton's `Committed resource failed` (E_OUTOFMEMORY) at +128 s
  ([witcher3-perf § 8](2026-10-28-witcher3-perf.md#8-what-this-does-not-show)). A standing scene has about
  0.6 GiB of headroom.

**Spills.** `graphics-compiler-spill-events`: 10,417 events from 3,195 encoder executions. Grouped by each
encoder's largest spill, with that encoder's GPU time:

| Spill | Encoders (per frame) | GPU time | Which |
| --- | --- | ---: | --- |
| 192 B | 287 compute + 287 render (1 + 1) | 26.9 % | the lighting dispatch asc60 (6.3–7.0 ms each) and one render encoder |
| 128 B | 439 render | 2.7 % | |
| 144, 160, 80, 64, 112, 224, 176, 320, 16, 48 B | 13–287 render each | 0.1–1.5 % each | |
| 96 B | 287 compute (1) | 0.4 % | |

Encoders that report a spill take 2.21 s of 6.22 s of GPU time (35.6 %).

**What the lighting shader looks like** (`$PLAYPORT_BUILD/mac/item3/cs-pass55.metal`, 3,874 statements):
- 2,752 float statements, 160 ulong;
- 237 bounds-checked constant-buffer loads (`off < size ? *(constant float*)… : 0`);
- 28 texture descriptors read from the heap, each behind a null check;
- 34 `coherent device` loads (KK_WORKAROUND_6, which `patches/mesa` 0030 keeps for compute shaders on iOS 27);
- 4 64-bit `no_crash` loop guards;
- 2,064 bytes of threadgroup memory.

**On the Mac's own GPU** (M1 Pro, `pso.swift`), its compute pipeline allows 384 threads per threadgroup
(the dispatch uses 256), a sign of heavy register use. Removing the loop guards, `coherent` or the
`math_mode(safe)` pragmas did not change that number. It is too coarse to rank them, so their effect on
spills needs a timing on the phone.

## 6. Tasks

Filed in Linear as sub-issues of PLA-455, each with its fix and how to check it from the workstation:

| Area | Issue | What |
| --- | --- | --- |
| CPU, Wine | PLA-460 | nsiproxy: one `getifaddrs` snapshot per enumeration (and a short cache); find the guest caller |
| CPU, Wine | PLA-461 | ntdll: stop re-`stat`ing `dosdevices` per path; cache directory case-sensitivity; find the paths |
| CPU, FEX | PLA-462 | spin waits: give the core to the OS after a run of PAUSEs, not WFE |
| KK, GPU | PLA-463 | `vkCmdCopyImage2` between different formats through a texture view, not a 6 MiB buffer a frame |
| KK, memory | PLA-464 | recycle command-buffer BOs over 128 KiB by size class |
| KK, memory | PLA-465 | residency commits: 16 a frame and two 200 ms stalls; commit only deltas once PLA-463 makes the set stable |
| KK, tooling | PLA-466 | GPU time per pass and pipeline register pressure from KosmicKrisp on the workstation |
| KK, GPU | PLA-459 (comment) | the spill finding and the per-title experiments (workaround 6 and 2, robust constant buffers) |
| Memory | PLA-467 | 2.33 of 3 GiB in a standing scene: what fills it before E_OUTOFMEMORY |
| Host | PLA-468 | Playport's own polling during play: `mincore` memory log, `open` per session wait |

## What this does not show

- **One trace.** This is one 15 s trace, under the tools' own CPU load, the GPU's induced Medium state and a
  Serious thermal state, in one scene.
- **No ranking against the trace's own frame time.** The CPU-bound frame is partly the tools' doing.
- **Not measured:** what each task would gain. The guest code behind the network and path queries, and
  why two commits took 200 ms, are not known.
- **Not run:** no change was made or run on the phone in this session.
