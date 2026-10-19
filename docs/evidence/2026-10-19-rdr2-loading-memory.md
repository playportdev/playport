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
