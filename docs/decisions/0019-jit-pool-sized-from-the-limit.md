# 0019: The JIT pool is sized from the memory limit; pseudo-processes keep private ntdll copies

**Status:** accepted, 2026-09-28. Settles item 2 of the
[runtime-risks plan](../plans/2026-09-27-runtime-risks.md) (the pool is fixed
and single-shot): its sizing, and whether pseudo-processes can share one
read-only ntdll copy. The measurements are in the
[evidence record](../evidence/2026-09-28-jit-pool.md).

**Its sizing is replaced by [0036](0036-one-512-mib-jit-pool.md)**: every Play gets 512 MiB.

**Changed by [0022](0022-stop-a-game-that-ran-the-pool-out.md)**: a game still
running 10 s after the pool ran out is stopped, not left running.

**Measured by a launcher** ([0026](0026-a-dev-test-title-for-the-jit-pool.md),
[evidence](../evidence/2026-09-28-launcher-stress.md)): a child takes 19.6 MiB
of head, of which its ntdll copy is 4 MiB, and FEX's 16 MiB code buffer. So
the private ntdll copy stands. Most of the head goes to the child's own copies of
the parent's system DLLs, and a dead child's images are not reused.

## Decision

- **Size.** A Play's pool is an eighth of the app's memory limit at the Play,
  in whole 16 MiB steps, at least 512 MiB and at most 896 MiB (PlayportKit
  `JitPool.sizeMB`). On the reference phone with Game Mode on (8 GB) that is
  896 MiB, as before; before Game Mode raises the limit (6 GB) it is 768 MiB;
  a copy signed without the Increased Memory Limit entitlement (about 3.3 GB)
  gets 512 MiB. Settings' Memory section shows it as *JIT memory*. A dev
  build's *Simulated JIT memory* (`jitPoolSimulatedMB`) sets it directly, so
  running out can be driven.
- **Running out.** A launch whose pool ran out ends as its own outcome, "ran
  out of JIT memory", whatever the game's exit code, and a game still running
  10 s after the pool ran out ends the launch there. What counts as running
  out: an image, guest JIT block or child ntdll copy the head had no room
  for, a code buffer of 1 MiB or less the tail refused (FEX then faults at
  `0xdead`), or a guest JIT region the anonymous-alias table had no slot for.
  A refused larger code buffer does not count: FEX asks again for half.
- **ntdll.** Each pseudo-process keeps its private ntdll copy in the pool.
  One shared read-only copy is not built.

## Why

**The pool is a fixed charge against the limit.** Blessing touches every page,
so from the bless on the whole pool is in the app's footprint: at the
runtime's start the footprint was the pool plus about 35 MB for every size
tried (931 MB with 896 MiB, 553 MB with 512, 289 MB with 256, 163 MB with 128).
Under a low limit, a large pool takes memory the game needs, and a jetsam
kill gives no message; a smaller pool that runs out gives a clear one. The
bless also takes longer for a larger pool (3.1 to 3.3 s at 896 MiB, 2.5 s at
512, 2.0 s at 256).

**What the cohort needs is far below 896 MiB.** The high-water marks with
896 MiB were: Hollow Knight, head 187 MiB and tail 145 MiB after about two
minutes of a new game; The Witcher 3, head 206 MiB and tail 145 MiB while
walking Kaer Morhen. The tail is what FEX is granted, not what it needs: it
takes a 128 MiB code buffer whenever the room allows one, and with a 256 MiB
pool Hollow Knight ran with a 49 MiB tail. With 512 MiB Hollow Knight still
got the 128 MiB buffer (head 164 MiB, tail 145 MiB, 204 MiB of room), and by
the allocator's rule The Witcher 3 would too, with 161 MiB of room. So 512 MiB
is the floor, and between the floor and the ceiling the pool follows the
limit.

**896 MiB is the ceiling** because it is what the executable's exec-time
reservation (`host_pool_reserve`, 960 MiB) is laid out for: it holds the
pool and 64 MiB of slack at its start at any slide. A larger pool is
placed first fit, which failed about one launch in four before the
reservation existed. More
would need a larger reservation in the low range below the shared cache, and
nothing measured needs it.

**A shared ntdll saves little, and one copy cannot serve every process.**

- The child cannot share the parent's ntdll `.data` (its module list, loader
  lock and hash table), which is why each child gets a copy. ntdll's code
  reaches its `.data` PC-relative (ADRP), so one read-only copy of the code at
  one pool address can only reach one `.data`. Sharing would mean remapping
  the code pages at each child's own slot, which saves physical pages but not
  pool: the pool's limit is its address range.
- A copy is ntdll's whole image: 4 MiB (0x400000) plus its x18 trampolines.
  2.5 MiB of that is DWARF sections that the image maps; `.text` is 0.5 MiB
  and `.data` 64 KiB.
- A child costs more elsewhere: its first FEX code buffer (16 MiB of tail,
  given back when it exits), its executable and every DLL the parent had not
  loaded.
- No cohort title starts a child process. Hollow Knight's
  `UnityCrashHandler64.exe` is refused by the runtime's spawn gate; The
  Witcher 3 and En Garde!'s shipping executable start none. With Hollow
  Knight's 565 MiB of room, the pool holds at most about 28 children alive at
  once at 20 MiB each (the ntdll copy and the first code buffer, before their
  own images), of which ntdll is a fifth.

## What it costs, and what is left

- A title that needs more head than its pool has now ends on the result
  screen instead of running on without a DLL: at 184 MiB Hollow Knight lost
  `steam_api64.dll` (8 MiB, tried 12 times) and some Mono JIT blocks, and
  kept presenting a black screen.
- Under a limit below 4 GB the pool is 512 MiB, not 896. A title whose head
  and tail need more than that (Steam's CEF reached 700 MiB of head in
  Madeira's runs) runs out there, with the outcome that says so.
- `titles.json`'s `memoryMB` was measured with an 896 MiB pool, so it
  overstates a title's need by up to 384 MB when the pool is smaller.
  `MemoryNeed` does not take the pool size into account yet.
- The Wine PE set is staged with its DWARF sections, which every image copy
  maps into the pool: 40 MiB of Hollow Knight's 160 MiB head at start. Stripping
  them at staging would give that back (and 2.5 MiB per child ntdll copy),
  once crash symbolisation reads unstripped copies from the build area.
- A launcher that starts children was not run: no installed title starts one,
  and a test program cannot be staged ([0012](0012-the-ui-is-the-only-entry-point.md)).
  The first title that does will show its `children` and `children_mb` in its
  `pool:` lines.
