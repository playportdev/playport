# Donor pool: Metal buffers over pool memory (step 5)

**Date:** 2026-10-15 (02:20–03:20). **Branch:** `research/extended-memory`.
**Linear:** [PLA-354](https://linear.app/playportdev/issue/PLA-354) (child of
[PLA-216](https://linear.app/playportdev/issue/PLA-216)); the titles are PLA-42 (Hollow Knight)
and PLA-49 (Kingdom Come).
**Plan:** [donor memory](../plans/2026-10-12-donor-memory.md), step 5 ("Graphics memory"), queue
item 4. The owner was asleep and the phone was in unattended mode. Where there was a choice, the
conservative option was taken (listed under "Choices").

**Setup:**

- iPhone18,4, iOS 27.0.1, on the charger (100 % throughout).
- Probe: dev IPA SHA256 `ce422ebbf66ae2dcb730fee8b0f7f20bcc836e62959d5ffa40fd41a4815c0e5b`
  (commit `adc7adb`). Gate: dev IPA SHA256
  `82e1039e6230e83c606f087aa736dae69a831da4c40593be5eaf54062ae0648a` (commit `821c0dd`, dxmt
  0012). Both installed with `pp install --no-build`.
- Three locked sessions, `gpu-probe-session.sh`, `gpu-gate-session.sh` and
  `gpu-hk-dxmt-session.sh`, with their logs and runs under
  `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/gpu/`.

## 1. The probe: does a no-copy Metal buffer over pool memory count?

`probe:memory-pool-gpu` (Settings › Developer › Probes › Donor pool: Metal buffers;
`SharedMemoryProbe.runPoolGPU`): one donor gives 1 GiB (four purgeable objects of 256 MiB),
untouched, and ends. The app makes four shared-storage `newBufferWithBytesNoCopy` buffers over
the objects' own views. The CPU fills object 1. On the GPU, one blit pass copies buffer 1 to
buffer 2 and fills buffers 3 and 4 with a byte each. The CPU then reads all of them back. A
64 MiB buffer over a range of object 4, mapped at a fixed address as the guest hooks map, is
filled the same way. The control is four ordinary `newBufferWithLength` buffers of 256 MiB,
filled on the GPU. A reading is taken 1 s after each step: `phys_footprint`, the graphics
ledger (`ledger_tag_graphics_footprint` plus its compressed part, now in `pp_memory_snapshot`),
and Metal's `currentAllocatedSize`. Run `gpu/probe`, `pool-gpu` lines:

| Point | Footprint (MiB) | Graphics ledger (MiB) | Metal allocated (MiB) | Objects resident (MiB) |
| --- | --- | --- | --- | --- |
| untouched | 55 | 1 | 1 | 0 |
| 4 no-copy buffers made | 66 | 1 | 1,025 | 0 |
| object 1 filled by the CPU | 71 | 1 | 1,025 | 256 |
| GPU copy and fills done | 74 | 16 | 1,025 | 1,024 |
| no-copy buffers released | 66 | 16 | 1,025 | 1,024 |
| 4 ordinary buffers made | 60 | 14 | 2,049 | 1,024 |
| ordinary buffers GPU-filled | 1,086 | 1,040 | 2,049 | 1,024 |

- **Metal takes memory-entry mappings.** All four buffers were made, with `contents` equal to
  the view (16 KiB pages). So was the 64 MiB buffer over a fixed-address range mapping. Neither
  needed anything beyond page alignment.
- **The GPU reads and writes them correctly.** The copy read back as object 1's pattern, and
  the fills read back as their bytes. The range buffer's fill landed at its offset in the object
  and nowhere else. `RESULT PASS`.
- **They stay off the app's footprint.** 1 GiB of GPU-written no-copy buffers, all resident,
  added 19 MiB of footprint (15 MiB of graphics ledger: the blit's own work). The control added
  1,020 MiB of footprint and 1,024 MiB of graphics ledger.
- **Metal's `currentAllocatedSize` counts both kinds**, so DXMT's census and any budget read
  from it do not show the difference. Its count did not fall when the probe dropped the no-copy
  buffers: the probe ran in one GCD work item, so an autoreleased reference may have held them.
  This was not settled.

## 2. DXMT 0012: `gpu-pool-buffers`

`patches/dxmt/0012`, off by default. With madeira.cfg `gpu-pool-buffers = 1` (read once through
`MadeiraCtl`'s config lookup, as 0011's key is), each shared-storage buffer allocation of 1 MiB
or more that is not write-combined gets:

- fresh `VirtualAlloc` pages of its own, rounded to 64 KiB;
- a no-copy Metal buffer over those pages, instead of `newBufferWithLength`.

How it behaves:

- **Backing.** The pages are a fresh RW guest commit, so with the pool installed madeira-unix
  0148/0150 back them from it. Without a pool they are the app's own memory, as the buffer's
  were.
- **Release.** When the allocation's last reference ends, the patch releases the Metal buffer
  and its texture views first, then the pages. Command chunks hold their allocations until they
  complete, so the GPU has finished with the buffer by then. The pool zeroes released pages
  before it reuses them.
- **Fallback.** If either allocation is refused, the buffer is an ordinary one.
- **Logging.** `[gpu-pool]` lines give the first 16 placements and every 256th, with live and
  total MiB and the refusals.

Hollow Knight on DXMT never takes this path: it has no buffer over 1 MiB (mem-census
`<=16M=0MB/0`). Kingdom Come does: about 690 MB live in 260 buffers of 1–16 MiB.

## 3. Phone gate

**Hollow Knight, DXMT, first frame +10 s, Auto pool** (`hk-dxmt-key0`, `hk-dxmt-key1`):

- Both reached the first frame: 12.43 s with the key off, 11.87 s with it on.
- Both were still drawing at the stop: the last present lines were #1088 (off) and #1120 (on), each 624 draws after the line before.
- Their stop screenshots are identical (the black intro screen with the touch controls).
- The footprint at the census was 2,333 MB off and 2,260 MB on. The graphics ledger was 700 MB
  in both.

Before these, `gpu-gate-session.sh`'s two Hollow Knight runs (`hk-key0`, `hk-key1`) passed too,
but on Vulkan: this build's default backend for Hollow Knight. The `--settings` JSON lacked
`"graphics":"dxmt"`, so after that fix the DXMT pair above was run once.

**Kingdom Come A/B, 240 s from the first frame, Auto pool (4,096 MiB)**
(`kcd-key0`, `kcd-key1`):

- Both runs used autozero-session.sh's Continue flow, with the walk loaded in Rattay.
- Both had screen 720 and a 60 FPS limit in their launch settings, and differed only in
  `runtime=gpu-pool-buffers=0/1`.

| | Key off | Key on |
| --- | --- | --- |
| `[gpu-pool]` | off | 16 placements logged (4 MiB each), none refused |
| Graphics ledger, last 20 censuses (MB) | 1,591 | 1,219 (−372) |
| Graphics ledger, maximum (MB) | 1,669 | 1,285 |
| `internal` / `compressed`, last 20 (MB) | 5,103 / 1,215 | 4,991 / 1,643 |
| `phys`, last 20 / maximum (MB) | 3,930 / 3,986 | 3,971 / 4,020 |
| Peak `fpMB` | 4,018 | 4,073 |
| Pool live at +270 s (MiB) | 4,011 of 4,096 | 4,095 of 4,096 |
| Pool refused (growth stop / full) | 12,805 / 0 | 13,276 / 2,704 |
| FPS mean / p10 / median | 34.7 / 14.9 / 22.4 | 35.2 / 16.8 / 23.1 |
| Metal `currentAllocatedSize` (MB) | 1,535 | 1,577 |

The screenshots at first frame +150 and +230 render Rattay normally in both runs, with no
corruption.

**The count of placed buffers is a lower bound:** the log has the first 16 placements only,
with none refused, because no 256th came. mem-census put 688 MB live in 264 buffers of
1–16 MiB at the end. The graphics ledger fell by 372 MB on average and by 384 MB at its
maximum.

## Result

- **Step 5's question is answered positively.** A no-copy Metal buffer over donor pool memory:
  - is accepted by Metal;
  - is read and written correctly by the GPU;
  - is not charged to the app: 19 MiB of footprint per 1 GiB, against 1,020 MiB for ordinary
    buffers.
- **Kingdom Come gains nothing from it at Auto.** The key moved about 370–380 MB of buffers out
  of the graphics ledger, but the 4 GiB pool was already full: growth had stopped at jetsam
  level 14 % in both runs, and with the key on it ran out (2,704 refusals). The pool's size is
  fixed, so each buffer page it backs is a page of guest data it cannot back. That data became
  the app's own memory (`compressed` +428 MB), and peak `fpMB` was 4,073 against 4,018, within
  run-to-run noise. FPS matched.
- **0012 can only help when the pool has room** that guest data does not fill: a larger pool,
  or a title with less guest RAM than the pool. The memory then still has to come from
  somewhere, since the phone's free RAM is the wall
  ([step 2](2026-10-14-donor-memory-scale.md)).
- Hollow Knight on DXMT, key on and off, reached the first frame and drew.

## KosmicKrisp (host survey only)

The mesa pin (`b39d173`, Mesa main) already exposes `VK_EXT_external_memory_host`, from
upstream code, not a Playport patch:

- `kk_physical_device.c` enables it, with `minImportedHostPointerAlignment` = the page size
  (16 KiB).
- `kk_GetMemoryHostPointerPropertiesEXT` accepts host-allocation and foreign-mapped pointers
  for every memory type.
- `kk_AllocateMemory` imports with `newBufferWithBytesNoCopy` (`mtl_new_buffer_with_bytes_no_copy`)
  and adds the buffer to the residency set.
- Imported memory serves buffers only, since a heap cannot be made from a pointer. Images must
  be linear.

What is missing is a user. DXVK and vkd3d-proton allocate device memory without importing
host pointers, so their buffers sit in KosmicKrisp's `MTLHeap`s, which are charged as graphics.
Getting Vulkan buffers into the pool would take one of two changes:

- **In DXVK:** a buffer-only chunk path that imports guest pages (a patch to the
  `dxvk`/Vulkan PE tree).
- **In KosmicKrisp:** a host-visible memory type, or dedicated buffer allocations, backed by
  imported fresh pages instead of a heap. The allocation does not know whether a buffer or an
  image will use it, unless the allocation is dedicated.

Either change meets the same limit as section 3: the pool's size is the bound. That is not
worth doing while the pool is already full of guest data.

## Choices

- **0012 stays in the series, off by default.** It changes nothing when the key is off (the
  check runs only for buffers of 1 MiB or more, and the key is read once). It was correct on the
  phone with the key on. It is the lever for a later, larger or emptier pool. Dropping it was
  the alternative.
- **The gate's settings were fixed for both arms.** The A/B passed `--settings` with screen 720
  and a 60 FPS limit in both arms, so the only difference was the key. The title's own launch
  settings return at the app's next launch outside the session.
- **Hollow Knight was run once more on DXMT** after the first pair ran on Vulkan. That was the
  one retry, after a fix to the script.
- **The KosmicKrisp change was not made**, per the task: survey only.
