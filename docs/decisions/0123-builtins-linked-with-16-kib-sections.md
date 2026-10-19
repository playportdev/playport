# 0123: ARM64 and ARM64EC builtins are linked with 16 KiB sections

**Status:** accepted, 2026-10-19, chosen by the owner (PLA-377: "A1 then A2, measured between");
the second step after [0122](0122-builtin-copies-without-rsrc-and-reloc.md).
[PLA-377](https://linear.app/playportdev/issue/PLA-377),
[evidence](../evidence/2026-10-19-smaller-image-copies.md#a2-builtins-linked-with-16-kib-sections).

## Context

winegcc links ARM64 and ARM64EC modules with 64 KiB section alignment, and the file alignment
follows it. Every pseudo-process copies each builtin it loads into the JIT pool's head, padding
and all: kernel32's copy took 960 KiB for 400 KiB of sections. In RDR2's play with the Rockstar
launcher that padding was 154.7 MiB of the 535 MiB live. The phone's page is 16 KiB, so Wine's
unix loader maps sections aligned to it as usual, and a writable section on its own page needs no
data-align shift.

## Decision

- winegcc's default section and file alignment for ARM64 and ARM64EC is `0x4000`
  (`patches/wine-pe` 0049).
  - Every ARM64 and ARM64EC builtin's layout changes, and so do the build records.
  - winebuild's data-only modules keep 64 KiB: they have no code and get no copy.
  - i386 and x86-64 are unchanged.

## Consequences

- With 0122, the RDR2 play reached its first frame (+92.85 s): head 328 MiB, tail 497 MiB, room
  72 MiB, no refusal. Before these steps the head had refused RDR2.exe's system DLLs.
- Hollow Knight's head fell from 62 to 48 MiB, with its first frame at 8.0 s.
- The tail still takes freed room under 0116's rule: two launcher processes hold 128 MiB code
  buffers each.
