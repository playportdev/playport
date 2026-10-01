# 0024: DXVK picks its own compiler thread count; the FEX band is no longer the limit

**Status:** accepted, 2026-09-28. Supersedes the compiler-thread limit in
[0015](0015-vulkan-backend-accepted.md) (the rest of 0015 stands). Settles
item 5 of the [runtime-risks plan](../plans/2026-09-27-runtime-risks.md)
(virtual address space is tight). The measurements are in the
[evidence record](../evidence/2026-09-28-fex-band.md).

## Decision

- **The Vulkan backend starts with no `DXVK_CONFIG`.** DXVK picks its own
  compiler thread count: six on the iPhone Air. `GraphicsBackend.runtimeEnvironment`
  is empty for both backends. A game's own variables can still set it.
- **The FEX host band's use is measured on every play.**
  - `title: band:` lines give the use, the largest free range, the free
    16 MB span slots, the threads and the refused requests. They come from
    madeira-unix 0038, and `pp ui` and `pp perf` report them as `band`.
  - `[band]` lines give each thread's start (fex 0009, rpmalloc 0001).
  - `[band-map]` lines give the map, at the first refusal and, in a dev
    build, every 16 threads.
- **rpmalloc names none of its mappings on iOS** (rpmalloc 0002). This ends a
  recursion that leaked 3.7 GB of the band before the first frame.
- **Call-return stacks come from the top of the band** (fex 0010). Stacks and
  spans then leave no holes between them.

## Why

0015 limited DXVK to two compiler threads because Hollow Knight's threads and
DXVK's pool together filled FEX's 16 GB host band, and DXVK's frame thread
then could not start. Two things were filling it, and both are gone:

- the game's own 512 MB arenas, up to 8.5 GB of them, steered into the band
  (madeira-unix 0032 moved them out, 2026-09-27);
- 3.7 GB that rpmalloc lost in a recursion through its name hook, on the
  game's second thread (rpmalloc 0002).

Each emulator thread now takes 50 MB of the band: its rpmalloc heap's two
16 MB spans, a 16 MB call-return stack and a 2 MB L1 cache. The L2 cache and
its 8 GB table are off on iOS. With DXVK's six compiler threads, Hollow Knight
runs 53 threads in 3.5 GB of the band. About 12.9 GB is free in one range, and
nothing is refused. That is room for about 250 more threads. So the thread
count stops limiting the band, and the limit no longer buys anything.

## What it costs

- **Hollow Knight on Vulkan freezes, with two compiler threads as with six.**
  It stops in the menu's fade-in or after Start Game, with every thread
  waiting and the band far from full. Dropping the limit neither causes this
  nor fixes it. Until the freeze is found, 0015's claim that gameplay runs on
  Vulkan does not hold on this build.
- **Six compiler threads are four more threads** doing work while shaders
  compile. That is the upstream default and what a desktop gets.
- **The band is still fixed at 16 GB.** A title that runs about 300 emulator
  threads would fill it again. `band:` shows how close a title comes, and
  `refused` shows when it gets there.
