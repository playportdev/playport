# RDR2's end during loading: the memory limit, at the game's Social Club start

[PLA-413](https://linear.app/playportdev/issue/PLA-413). Follows
[the longer play](2026-10-19-rockstar-launcher-after-sign-in.md#a-longer-play) of
[PLA-409](https://linear.app/playportdev/issue/PLA-409).

IPA `4c074ecdd4669aa8ca0ae193b0037f6104ea9d8b63b9de3e2050d1cf978a6637` (dev), iPhone18,4,
iOS 27.0.1, 11,734 MiB of RAM, memory limit 8,192 MB, on the charger. Nothing was pressed in
either run. The analysis scripts, the phone session script and its device log are in the
build area (`$PLAYPORT_BUILD/agent-notes/pla413/`).

| | A: run `20261019T140029` | B: run `20261019T142048` |
| --- | --- | --- |
| Donor pool | off (`pool_mb=0`) | `set:donorPoolMB=auto` for the session: 4,096 MiB granted, one donor |
| Device log kept | no | yes, memory and termination lines (`pymobiledevice3 syslog live`) |
| First frame | +81.43 s | +84.63 s |
| RDR2.exe loads `socialclub.dll`, then `libcef.dll` | about 240 s after the first frame | about 19 s after the first frame |
| Log ends after that | 7.5 s | 12 s |
| Last footprint | 7,311 MB | **8,178 MB** |
| Crash report, `JetsamEvent` for the day | none, none | none, none |

## Why the app ends

**B ended at the memory limit.** Its last footprint line read 8,178 MB, 14 MB under the limit,
climbing at about 100 MB/s, and the log ends 0.3 s later. There is no crash report and no
`JetsamEvent-2026-10-19-*` on the phone, as for a kill that is not a crash. The kernel's own
kill line is not in the kept device log: the device-log connection dropped at 14:22:57, 4 s
before the end, while the kernel was ending about 20 idle daemons and logging `System will
begin enforcing soft memory limits`.

**A most likely ended the same way, but it is not proven.** Its last footprint line read
7,311 MB, and its log ends 0.5 s later, 881 MB under the limit. The fast footprint sampler logs
only a rise of more than 16 MB, every 250 ms, so a single large allocation in that last half
second would not show. Both runs ended at the same step, though (below), and neither left a
crash report.

## The step it ends at

In both runs, the end follows RDR2.exe's own Social Club start by 7–12 s:
- RDR2.exe maps `socialclub.dll`, `SocialClubHelper.exe` (as an image), **`libcef.dll`** (a
  246 MiB image), `SocialClubVulkanLayer.dll` and `SocialClubD3D12Renderer.dll`.
- RDR2.exe adds threads quickly: 12 in A's last 7 s.
- The graphics ledger rises: in A from 696 to 1,168 MB, in B from 700 to 1,371 MB.
- In B the compressed part of the footprint rises from 1,810 to 3,158 MB in 12 s.
- The game starts no process of its own before the end.

On desktop, with the launcher present, the game loads `socialclub.dll` but not libcef
([desktop evidence](2026-10-15-rdr2-launcher-in-game.md)). Here it maps libcef while the
launcher still runs. Whether that means the game is falling back to its own CEF (as on
desktop once the launcher is gone) is not shown.

The step came about 240 s after the first frame in A and 19 s after it in B. Why A's loading took
that much longer is not known.

## Where the footprint is (A, 14:05:56, footprint 7,064 MB)

The runtime's address-space walk (`[phys-map]`, every 150 cycles) charges dirty pages
(resident plus compressed) to address bands. With the graphics ledger it adds up to the
footprint:

| Part | MB | What |
| --- | ---: | --- |
| Guest band (`0x7000000000`–`0x7400000000`) | 3,413 | all processes' guest memory; 647 MB of it in shared objects |
| of which: launcher-side `libcef.dll` copies | about 1,175 | 5 private copies of about 235 MB (Launcher.exe, the CEF browser, 3 renderers); 4 measured, 60–90 % compressed |
| FEX host band | 1,517 | rpmalloc heaps, 4 MiB call-return stacks, lookup caches of 262 threads (807 resident) |
| JIT pool | 896 | the whole pool, dirty (RX and RW are one object) |
| Graphics ledger | 696 | Metal (KosmicKrisp, Vulkan backend) |
| Host low | 517 | the host's own memory and images below 64 GB, including RDR2.exe's 115 MB copy |
| PA band | 15 | |
| **Sum** | **7,054** | against a footprint of 7,064 |

Of the footprint, 1,891 MB was compressed.

### Launcher tree against RDR2.exe

No log splits memory by process. The parts that can be attributed:
- **Launcher side:**
  - libcef copies, about 1,175 MB (4 copies measured per region, Launcher.exe's taken as the same);
  - most of the JIT pool's 851 MiB in use: RDR2.exe held 54 MiB of the head copies in the
    [earlier run](2026-10-19-smaller-image-copies.md). The pool is a fixed 896 MiB, so this
    is not footprint a launcher end would free.
- **RDR2.exe:**
  - its image, 115 MB;
  - the graphics rise at the end.
- **FEX band:**
  - by thread count, about 190 of the 262 threads are the launcher side's, which would put
    about 1 GB of the band there (inferred);
  - RDR2.exe's own last line showed 62 threads, 459 MB of rpmalloc address space and 248 MB
    of call-return stacks.

On desktop the launcher side took 3.5 GiB PSS and RDR2.exe 3.2 GiB.

**Splitting by process would need a new line:** Wine's view tree walked per owning process
(each view's committed and resident bytes, by the process that mapped it), with the FEX band's
rpmalloc and call-return memory by process. The guest census (madeira-unix 0149) runs only
with the donor pool on, and it sorts by kind, not by process.

## The donor pool (B)

- **What it took.** It backs fresh RW guest commits inside `[0x7000000000, 0x7c00000000)`
  (madeira-unix 0148/0150). It does not back:
  - image copies (libcef, RDR2.exe);
  - the FEX band (`0x7c…`);
  - host memory;
  - the graphics ledger. Its Metal side is DXMT's `gpu-pool-buffers` (dxmt 0012), and RDR2
    runs on Vulkan.
- **What it saved.** At first frame + 8 s:
  - it held 1,414 MiB live, 543 MiB of it resident;
  - the app's footprint was 6,322 MB, against 6,916 MB in A at the same point: about 600 MB
    less;
  - the guest census at that moment put 1,325 MB of the guest's footprint in images and 589
    in the pool.
- **Its growth stopped at the first frame.** It logged `pressure: growth stopped (level 12% <
  15%)` with 3,851 MB spare. After that it took nothing new.
- **It did not get past the step.** The game's Social Club start still took the app from about
  6.5 GB to 8,178 MB in 12 s, mostly as compressed memory (up 1.35 GB) and graphics (up 671 MB).
- **Its cost here.** The phone ran short of memory system-wide: the kernel ended about 20 idle
  daemons and began enforcing soft limits, and the device-log connection dropped. The pool did
  little work of its own: 18 ms of zeroing and 68 ms of backing by the first frame.
- **It is dev-only.** A release build answers 0148's hooks with stubs (`WineHostRuntime.swift`)
  and has no `Dev/DonorPool.swift`. Shipping it would need:
  - a decision;
  - the pool and its Settings row moved out of `Dev/`;
  - its pressure rules checked on the release app.

## Not shown

- the kernel's kill reason for either run (the device log dropped first in B; A kept none);
- where the last 881 MB went in A;
- the split by process;
- whether the game's libcef load is a fallback from the launcher;
- any gameplay: no run got past the loading.

## Memory by process (PLA-414)

[PLA-414](https://linear.app/playportdev/issue/PLA-414). madeira-unix 0166 logs `[proc-mem]`
lines: every Wine view's committed pages, charged to the pseudo-process that made it, as image,
private memory, or FEX's host band, with what of them `mincore` reports resident and compressed
(MiB committed/resident/compressed), and FEX's views counted by shape. A dev build walks it
every other 2 s wait slice and prints it when a process came, went or moved by 32 MiB, and once
at the launch's end. `tools/tests/test_proc_mem.py` compiles the shipped table header.

IPA `250354775122c23379126e443cf952d7855220683d8ba473284e10deb52f7c32` (dev), session script
`$PLAYPORT_BUILD/agent-notes/pla414/session1.sh`, which plays through the reusable
`$PLAYPORT_BUILD/agent-notes/pla413/phone-play.sh` (device log kept, the day's `JetsamEvent`
pulled). Nothing was pressed.

- **Hollow Knight** (run `20261019T144812`): first frame at +7.99 s.
- **RDR2** (run `20261019T144905`, `set:donorPoolMB=auto`): first frame at +91.78 s; the run
  reached its bound, first frame +600 s.
  - **The app was not in front after the first frame.** The device log shows it `NotVisible`
    and suspended at 14:51:29, about the first frame; the screenshots at 240 s and at the end
    show other apps. The phone was in use. What follows the first frame is a background app's
    and says nothing of the game's loading.
  - RDR2.exe loaded `socialclub.dll` only in the last seconds before the bound, and no libcef
    after it. The last footprint line read 8,169 MB, 23 MB under the limit.

### The split at the first frame (in front)

The last `[proc-mem]` before the first frame; footprint 5,040 MB (1,088 compressed), graphics
151 MB. Resident plus compressed, in MB:

| Process | Image | Private | FEX band | Sum | Committed |
| --- | ---: | ---: | ---: | ---: | ---: |
| Launcher.exe (78 threads) | 54 | 50 | 119 | 223 | 1,017 |
| RockstarErrorHandler.exe | 13 | 0 | 31 | 44 | 249 |
| SocialClubHelper.exe 0x284 | 269 | 127 | 229 | 625 | 950 |
| SocialClubHelper.exe 0x1b4 | 301 | 61 | 365 | 727 | 1,419 |
| SocialClubHelper.exe 0x334 (1 thread left) | 271 | 72 | 153 | 496 | 1,029 |
| an exited process (no live thread) | 270 | 167 | 232 | 669 | 1,104 |
| **Launcher side** | | | | **2,784** | |
| RDR2.exe (13 threads) | 49 | 66 | 142 | 257 | 1,280 |
| RockstarService, services, winedevice, crashpad, session root, PlayRDR2 | | | | 265 | |
| The runtime's own views | 161 | 28 | 9 | 198 | 2,676 |

- **The launcher side holds about 2.8 GB of the 5.0 GB footprint**, RDR2.exe about 0.26 GB at
  that point. Each CEF process holds its own libcef image: 284–316 MiB committed, 270–301 MB of
  it resident or compressed.
- **An exited process still holds 669 MB.** Its views (a 284 MiB image, the libcef size) have
  no live thread, but madeira-unix 0154 has not released them. Which process it was, and why
  its views stay, is not shown.
- **FEX's band by process:** Launcher.exe's 462 spans and 77 call-return stacks are 825 MiB
  committed but 119 MB resident or compressed; the band's committed size is mostly address
  space, not footprint.
- **At the bound (background):** RDR2.exe had grown to 2,239 MiB private committed (1,163 MB
  resident, 382 compressed) and 1,356 MiB in FEX's band; the launcher side's processes were
  mostly compressed.

**Cost.** The walk under `virtual_mutex` took 0–5 ms. `mincore` after it took 44 ms early and
0.4–1.8 s near the memory limit, on the launch's own thread; the 2 s slices stretched by that.

### A crash in the walk, fixed

- **The crash.** In RDR2 run `20261019T153520` (IPA `58c3d690…`), the app ended at +162 s in
  `ios_process_memory_log` itself: SIGSEGV at `0x3f3f3f3f3f3f3f3f` on the launch's thread. A
  Social Club helper was just starting. The walk read that process's PEB parameters before
  they were written.
- **The fix in 0166.**
  - The image name is read only through pointers that lie in one view: a VPROT_SYSTEM view,
    or one committed on every page. Otherwise the row has no name (`pid=0414 ?`). A first
    version also required the guest READ protection, and in run `20261019T161557` most rows
    then had no name.
  - An unforced walk within ten times the last walk's cost after it does nothing. Near the
    memory limit `mincore` took up to 4.8 s.
- **After the fix** (IPA `246f188a76a9f6d9db125db9b8be5856e81a5b8c927e72954c16aff36a74a439`, which
  also carried uncommitted launcher changes):
  - Hollow Knight (run `20261019T154957`) reached its first frame at +9.22 s.
  - The RDR2 run `20261019T155050` walked to its end without a fault. It reached no first
    frame, for a reason outside this walk: RDR2.exe's 8,960 MB reservation found no gap in
    0x74–0x7c.
