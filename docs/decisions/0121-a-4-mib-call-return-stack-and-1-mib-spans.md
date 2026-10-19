# 0121: FEX's call-return stack is 4 MiB and rpmalloc's spans are 1 MiB

**Status:** accepted, 2026-10-19, chosen by the owner (PLA-408: both levers together). Adopts
[0113](0113-a-4-mib-call-return-stack.md), which the owner had not adopted on 2026-10-17, and
changes the per-thread numbers in [ARCHITECTURE](../ARCHITECTURE.md#the-fex-host-band).
[PLA-408](https://linear.app/playportdev/issue/PLA-408),
[evidence](../evidence/2026-10-19-fex-band-per-thread.md).

## Context

Every emulator thread keeps its host state in the 16 GiB FEX host band: its rpmalloc heap's spans,
its call-return stack and its L1 lookup cache. FEX's pooled buffers are there too. In RDR2's
Steam play (run `20261019T105650`, IPA `4232943d…`) the signed-in Rockstar launcher's processes
filled the band at 197 threads, about 83 MB a thread:
- 718 rpmalloc spans of 16 MiB (11.2 GB);
- 197 call-return stacks of 16 MiB and two guard pages (3.1 GB);
- 197 L1 caches of 2 MiB, and 1,238 MB of other views.

After 0120, that launch ends as *ran out of emulator memory* (run `20261019T112934`). Red Dead
Redemption 2 runs about 120 threads on desktop, on top of the launcher's 197
([evidence](../evidence/2026-10-15-rdr2-launcher-in-game.md)). About 317 threads must fit, under
about 52 MB each.

Most of the spans were medium. A heap maps a span per page type it uses. Each size class it uses
takes a page of its type: 4 MiB for a medium class, 16 MiB for a large one. A thread that touched
a few medium classes held 16 MiB spans that it barely used.

## Decision

- **Call-return stack: 4 MiB** (`patches/fex` 0055, 0113's patch ported onto the current tree).
  It applies to every title and both FEX modules. The pointer starts and resets at the middle,
  and ARM64EC's inline guard keeps it in `[1 MiB, 3 MiB)`. One set of named constants in
  `InternalThreadState.h` drives every site, including the `[bogus-state]` log line.
- **rpmalloc span: 1 MiB** (`patches/rpmalloc` 0006, on `FEX_IOS_HOST` only):
  - the medium and large pages are the span: `MEDIUM_PAGE_SIZE_SHIFT` 22 → 20,
    `LARGE_PAGE_SIZE_SHIFT` 24 → 20;
  - a small span holds sixteen 64 KiB pages;
  - the large classes above 896 KiB are cut from the table (`LARGE_SIZE_CLASS_COUNT` 20 → 7,
    `LARGE_BLOCK_SIZE_LIMIT` 896 KiB), so those sizes take the huge path, which maps a block at
    its own size on a span boundary;
  - static asserts hold the invariants below.
- **Band census** (`patches/madeira-unix` 0164, which replaces 0113's 0157). It knows a span by its
  1 MiB shape on a 1 MiB boundary and a call-return stack by 4 MiB plus at most 64 KiB.
  `span_slots` counts free 1 MiB-aligned 1 MiB blocks. The `[band-map]` copy holds 16,384 views.
  The app's `band:` line keeps its fields.

## Why 1 MiB

The line numbers below are in `rpmalloc/rpmalloc.c` with the series applied.
- **A span holds whole pages of one type.** `heap_get_span` (2657) maps `SPAN_SIZE` on a
  `SPAN_SIZE` boundary (2665), and the page count is `SPAN_SIZE / page size`. So a span cannot be
  smaller than the largest page.
- **A page holds at least one block of its largest class plus the 128-byte header.** The class
  table (664) gives each class `(page size − PAGE_HEADER_SIZE) / block size` blocks.
  `get_size_class` (868) computes the index from the size by formula. So a class can only be cut
  from the top of the table, and the medium classes (up to 256 KiB, `MEDIUM_BLOCK_SIZE_LIMIT`)
  stay. The smallest medium page is therefore 512 KiB.
- **At 512 KiB, a 256 KiB block takes a page alone**, and every block above 448 KiB is huge: a
  `VirtualAlloc2` and a `VirtualFree` per allocation (2901, 2909). At 1 MiB:
  - the largest medium block fits three times a page;
  - only the four largest large classes (512–896 KiB) hold one block a page. The one-block-page
    path (`page_put_local_free_block`, 2121, `patches/rpmalloc` 0004) already serves the 8 MiB
    class at 16 MiB.

  Going from 1 MiB to 512 KiB would save at most about 1 MiB a thread and double the views.
- **A block's span is still `block & SPAN_MASK`** (`block_get_span`, 2477):
  - a page block lies inside its page;
  - an aligned block is at most `RPMALLOC_MAX_ALIGNMENT` (256 KiB, `rpmalloc.h` 55) past the
    block it came from (2980, 2994);
  - a huge block starts `SPAN_HEADER_SIZE` past its span-aligned mapping.

  All of these stay within the first 1 MiB.
- **A thread still starts with a small and a medium span.** In the band lines, every ThreadInit
  maps both (`spans mapped small=1 medium=1`). The thread's heap allocates in both page types,
  and a span belongs to one heap and one page type (`span->heap`, 2657). Sharing them would mean
  a different allocator design, so it stays. Both spans are now 1 MiB, not 16.

## Expected cost

At start, a thread takes about 8 MiB: the two spans, the 4 MiB stack and its guard pages, the 2 MiB L1 and the
heap's 64 KiB. Before, it took about 50 MiB. A thread holds one medium page for each medium
class it uses, now 1 MiB instead of 4. It holds one large page for each large class it uses,
now 1 MiB instead of 16. The [evidence](../evidence/2026-10-19-fex-band-per-thread.md) has the
measured numbers.

## Risks

- **0113's risks stand.** WOW64 has no inline guard, so a leaking 32-bit thread walks 2 MiB to its
  base before CompileBlock's `[CALLRET_OOB]` check resets it. Leaking ARM64EC threads reset twice
  as often.
- **More views and maps.** Each span is a Wine view. A heap that held one 16 MiB medium span
  now holds up to sixteen 1 MiB spans, and `VirtualAlloc2` searches the band once for each.
  Hollow Knight's first frame is the check.
- **More huge allocations.** A block above 896 KiB, which was large before, is now mapped and
  unmapped per allocation. FEX's big buffers are its own pooled ones, not rpmalloc's.
- **Census shape.** An rpmalloc huge block of exactly 1 MiB counts as a span. A block of 4 MiB plus
  at most 64 KiB counts as a call-return stack.
