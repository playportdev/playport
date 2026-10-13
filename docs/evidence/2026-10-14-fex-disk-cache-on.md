# FEX's disk cache on by default: the warm-start crashes were rpmalloc's one-block pages

**Date:** 2026-10-14. **Branch:** `dev/pla-341-fex-disk-cache` (PLA-341). **Phone:**
iPhone18,4, iOS 27.0.1, on external power, unattended session. **IPA:** dev
`792375cda60ab4e085ef8fe5c2ba9701e2192e69f1b95ad7d72e17c6cbaa50d9` (the gate) and
`7cbccbf8…` (the reproduction, main's FEX). Closes the blocker of decision 0056 and
alignment item B1: `FEXProfile.defaultDiskCache` is now true.

## What failed before

- **Hollow Knight** (2026-10-06, [record](2026-10-06-fex-disk-cache.md)): every warm
  start ended in FEX's start-up, before any block ran: `[rpm-avail] ml607 CORRUPT
  op=to_free bad=0x100 class=0x74`, then a fault in rpmalloc.
- **The Witcher 3** (2026-10-07, [record](2026-10-07-pool-x64-images.md)): a warm start
  ended 239 ms in at `libarm64ecfex.dll+0x1dfb58`, a read of `0xc52ee078`. The
  instruction bytes there (`121d7529 321f0129 b9001a69 [b86a7a89] f86a790b`) occur once
  in today's `libarm64ecfex.dll`, inside rpmalloc's `page_available_to_free`: the same
  function as Hollow Knight's and as the September crash
  ([first-run stutter](2026-09-26-first-run-stutter.md)). The `host_pool_reserve+…`
  name in that log was the nearest app symbol, not the code.

## The cause: a page of one block (patches/rpmalloc 0004)

The iOS port shrank rpmalloc's large pages from 64 MB to 16 MB (rpmalloc-port 0005,
`LARGE_PAGE_SIZE_SHIFT` 24) but kept the 20 large size classes. The last one,
class 116 (`0x74`), holds blocks of 7–8 MB: 7 per page upstream, **1 per page here**.
rpmalloc's free path assumes a full page passes through the available list on an
earlier free before its last block goes (`page_put_local_free_block`:
`--block_used == 0` → `page_available_to_free`, which unlinks the page from that
list). A full one-block page is on no list, so freeing its block unlinked it through
whatever `prev`/`next` it kept from its last time on a list, writing into other pages'
headers. `bad=0x100` is exactly that shape: not the head, no `prev`.

The disk cache makes such allocations at start: `IndexedDB::PopulateIndex` reads the
whole index file into one vector and frees it, and the in-memory index
(`ankerl::unordered_dense`) keeps its entries, 120 bytes each, in one vector that
doubles: at 65,536 entries that vector is 7.5 MB, class 116, and it is freed when the
index grows past them. On 2026-10-06 Hollow Knight's database had 35,072 blocks; at
the 219–234 index bytes per block seen today its index file was 7.7–8.2 MB, class 116,
read and freed in FEX's start-up, before any block runs, as the crash was. Whether the
page's stale links pointed anywhere harmful decided between a crash and a logged,
leaked page.

**Reproduced on the workstation.** rpmalloc at its pin (`09142d7`) built for Linux with
`ENABLE_ASSERTS=1`, one `rpmalloc(7800 * 1024)` then `rpfree`: upstream's constants run
clean; with the port's two (`LARGE_PAGE_SIZE_SHIFT 24`, `SPAN_SIZE 16 MB`) the free
stops at `page_available_to_free: Assertion (page->is_full == 0) && "Page full flag
internal failure"`; with the fix below it runs clean. (Scratch in
`$PLAYPORT_BUILD/pla341/rpmtest/`.)

Fix: move such a page to the available list first, then free it. Also, every new
list head now gets a null `prev`: upstream never reads a head's `prev` and leaves
stale ones, which the port's list guard (rpmalloc-port 0008) logged as corruption
(`op=consume bad=0x20`, 16 lines in each run before the fix, Portal 2 included, with
the cache off) and, in `page_available_to_free`, answered by dropping the class's
whole available list.

## Two key fixes (patches/fex 0041, 0042)

- **0041, the build in the machine bucket.** FEX keys its cache on `FormatVersion`,
  which only upstream moves; Playport's patches change codegen without it, so a
  database filled by one IPA's FEX was used by the next. The machine bucket now mixes
  in `GIT_HASH` (the patched tree's HEAD), and FEX's own pruning removes older builds'
  directories. On the phone after the update one bucket was left
  (`d9dd8f65c54f8336`).
- **0042, one database for every TEB slot.** 0021 gave each TEB slot offset its own
  database, so a launch on another slot ran cold (the reproduction: Hollow Knight on
  slot keys 296 then 292, the second start 32 hits and 2,032 misses after its first
  2 k blocks). A block taken from the cache now has its TEB reads
  (`mrs xN, tpidrro_el0; and xN, xN, #~7; ldr xN, [xN, #off]`) pointed at this
  launch's offset. Checked on the database the gate left (243 MB, 133,451 blocks of
  three games): 135 `mrs tpidrro_el0`, all 135 in that exact shape, all at `0x948`
  (slot 297). Every launch today had slot 297, so a warm start on another slot was
  **not seen on the phone** (PLA-343).

## The gate (IPA `792375cd…`, one locked session, cache on by default)

Runs in `$PLAYPORT_BUILD/pla341/g/`. `[diskcache]` is the process's last count.

| Run | Title | First frame | Disk cache |
|---|---|---|---|
| hk-1 | Hollow Knight, cold | +10.40 s | hits 70,037, misses 36,703, stored 36,620 |
| hk-2, hk-3 | warm | +9.44, +9.37 s | hits 106,484 / 106,488, misses 6 / 4 |
| hk-off | cache off (its page) | +9.04 s | — |
| hkx-1..4 | warm | +9.61, +8.43, +8.72, +8.50 s | misses 0–6 |
| dr-1 | #DRIVE Rally (Vulkan, 16:9), cold | +14.37 s | hits 160,261, misses 55,083 |
| dr-2 | warm | +12.34 s | hits 217,058, misses 15 |
| dp-1 | Duck Paradox, cold | +5.70 s | hits 49,306, misses 40,916 |
| dp-2, dpx-1..4 | warm | +4.83–4.95 s | misses 2–38 |
| p2 | Portal 2 (i386: WoW64 keeps it off, 0022) | +5.80 s | — |

Every run reached its `--until` with no unhandled exception and **no `[rpm-avail]`
line**. #DRIVE Rally's first start grew the shared index past 65,536 entries while it
played, and every start after it (90–133 k blocks in the database) did so in FEX's
start-up; each time the in-memory index freed its 7.5 MB class-116 vector: the path
that crashed before the fix. A warm start reuses all but a few dozen blocks; the first frame comes about
2 s sooner for #DRIVE Rally and 0.8 s for Duck Paradox. For Hollow Knight it is
within noise of the cache off (most of its code is Mono's JIT output, translated
again in each process), as in September.

## Hollow Knight alone (cache cleared through Settings)

Settings › Storage › Emulator cache › Clear (the driver's pad route), then Hollow
Knight four times (`$PLAYPORT_BUILD/pla341/g3/`). The clear removed the whole
`DiskCache` directory.

| Run | First frame | Disk cache |
|---|---|---|
| hk-1, cold | +10.14 s | hits 70,031, misses 36,707, stored 36,622 |
| hk-2, hk-3 | +9.24, +9.25 s | misses 4 / 13 |
| hk-4 | — | ended at the JIT step: the helper blessed the pages and never answered (`no JIT within 180 s`), before any FEX code; not the cache (PLA-342) |
| hk-5 (rerun) | +9.25 s | misses 2 |

The database was 74.8 MB with an 8,586,800-byte index: just past rpmalloc's 8 MB
large limit, so this index read took the huge path, not class 116.

## Not checked

- A warm start on a different TEB slot (above, PLA-343).
- The Witcher 3: not installed; the driver installs Steam's default branch (4.x,
  which needs AVX; PLA-43), not `classic`. Its crash is attributed by the instruction
  match above, not by a run.
- Play past first-frame+15, a full 5 GB cache, the release app (owner's sign-off,
  0068).
- The cache is one database for every game with the same FEX settings (as upstream):
  three games gave a 29 MB index, which every x86-64 process reads whole at start.
