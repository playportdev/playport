# Mewgenics: a gigabyte of address space per pool, and an audio timer that drifted

**Date:** 2026-10-26. **Phone:** iPhone Duo (`iPhone19,4`, A20 Pro), iOS 27.1. **Title:**
Mewgenics (Steam `686060`), x86-64, Vulkan (its executable names Direct3D 9, 11 and 12).
**Build:** dev, trees from `main` plus `patches/madeira-unix` 0144 and 0145, app linked and signed
by Xcode with a free Personal Team. Built-in JIT.

## Before

First frame at +3.5 to +3.8 s; then, every launch, an access violation 13 to 18 s in, at the
same place in the game:

    [jumbo#42] … size=0x40000000 (1024 MB) hint=0x0 -> 0x7bb18e0000 st=0x0 | granted=43008 MB ok=42 fail=0
    [jumbo#43] … size=0x40000000 (1024 MB) hint=0x0 -> 0x0 st=0xc0000017 | granted=43008 MB ok=42 fail=1
    [alloc-fail] ml814 #1 status=c0000017 hint=0x0 size=0x40000000 type=0x2000 protect=0x4
    wine: Unhandled page fault on write access to 0000000000000008 at address … (thread 002c)

The faulting instruction is in `Mewgenics.exe` (+0x969604). The game's pool allocator
(+0x9694c0) keeps a cursor and an end per pool; when a pool is full it reserves a new range
(+0x9da1d0: `VirtualAlloc(NULL, pool size, MEM_RESERVE, PAGE_READWRITE)`, the pool size being
1 GB for every pool) and commits from the cursor as the pool grows (`VirtualAlloc(cursor, n
pages, MEM_COMMIT, PAGE_READWRITE)`). Neither call's result is checked: after the 43rd reserve
failed, the game built its free list at NULL.

    [bigres-use] ranges=42 reserved=43008 MB committed=6 MB (0%) touched=42/42

Each pool commits 0 to 6 MB of its gigabyte. New pools come with each part of the game (start,
menu, loading), so the count only grows. The app's address space is 512 GB, of which iOS's GPU
range and its own allocations take all but the top 64 GB: the guest window and PA pool below
`0x7c00000000`, and FEX's 16 GB arena above it, with FEX using under 2 GB of it.
`arena-mb = 4096` (FEX's arena in 4 GB lower down) moved the failure from the 43rd reserve to the
54th: the game reached its menu and stopped there. Extended Virtual Addressing would give the app
more address space, but a Personal Team cannot have it.

The sound had gaps several times a second. The game is an event-driven WASAPI client that writes
one period (480 frames at 48 kHz) per event, and it delivered about 43,600 frames a second for
the 48,000 the device played (`[ios_audio] ml1065`, which counts both channels, about 870,000 per
10 s window). The driver's timer thread slept `usleep(10000)` between events, about 11 ms a
period on the phone.

## The fixes

- `patches/madeira-unix` 0144: `madeira.cfg lean-reserve-mb = N` (`lean-guard-mb = M`, 32 when
  unset). A reserve-only ask of 512 MB or more with no address and no `zero_bits` gets N + M MB.
  The first N commit as usual; a commit past them is refused and logged
  (`[lean-reserve] OVERFLOW`). The last M MB stay reserved and inaccessible, so a pool that
  outgrows N faults at its own guard rather than writing into the next pool, which a game that
  does not check its commit would otherwise do. Without the key nothing changes.
- `app/PlayportKit/Titles/compat-defaults.json`: `app-686060` gets `lean-reserve-mb=128`,
  20 times what its pools were seen to commit.
- `patches/madeira-unix` 0145: the timer thread looks every 2 ms, to deadlines
  (`mach_wait_until`), and signals while the ring holds less than four periods, and at least every
  period as before. Exact 10 ms deadlines alone brought Mewgenics to about 45,000 frames a second:
  when its audio thread runs late, two wakes fall on one wait.

## After

- Mewgenics with `lean-reserve-mb=128`: past its menu into play, more than 64 pools
  (`[lean-reserve] #64` is the last one logged), no `OVERFLOW`, no fault; it played on folding and
  unfolding the phone, and quit cleanly (`exit code 0`). The gaps in the sound are not heard.
  `ml1065` still reads about 45,000 frames a second (6% short) for it.
- Hollow Knight (`app-367520`) on the same runtime: first frame at +7.89 s, sound at 47,000 to
  49,000 frames a second (a polled client), no `[lean-reserve]` line.

## Not checked

The release variant; `pp ui` and `pp perf` (the workstation's netmuxd was not available); a long
session of Mewgenics, where a pool might outgrow 128 MB (it would stop with `[lean-reserve]
OVERFLOW` in the log). Why Mewgenics still delivers 6% fewer frames than the device plays is not
known.
