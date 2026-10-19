# 0122: A builtin's JIT-pool copy leaves out its .rsrc and .reloc

**Status:** accepted, 2026-10-19, chosen by the owner (PLA-377: "A1 then A2, measured between").
Keeps 0019's copy per process and its private ntdll copies.
[PLA-377](https://linear.app/playportdev/issue/PLA-377),
[evidence](../evidence/2026-10-19-smaller-image-copies.md).

## Context

Every pseudo-process maps its own view of each DLL in the one Mach address space. Each copy holds
that process's writable data, which its code reaches PC-relative. Sharing one copy across
processes would mean sharing `.data`, and 0019 turned that down for ntdll. The pool's limit is its
address range, so mapping the same code at a second address would save nothing.

What can be cut is the size of each copy. A copy took the image's whole SizeOfImage. In RDR2's play
with the Rockstar launcher, 155.6 MiB of the head's 535 MiB live were the builtins' trailing
`.rsrc` and `.reloc`. Shell32's copy was 9.9 MiB, of which 8.6 MiB was resources.

## Decision

- **A copy ends after the last section that code may reach** (`patches/madeira-unix` 0165,
  `ios_copy_extent.h`). The trailing sections it leaves out are neither executable nor writable,
  and either hold the resource directory or are discardable, and hold no other data directory.
  The copy runs to the next 16 KiB boundary, but never past SizeOfImage.
- **ntdll keeps its whole image:** its child copies relocate from their own bytes.
- **Relocations come from the PE view.** This holds for the copy path and for the IAT sync.
  - A fixup in a section the copy left out is skipped.
  - A pointer into such a section gets the PE view's address.
- **Two sizes per mapping.**
  - The copy's bytes serve translation, the FEX alias push, the IAT sync and the scans. An
    address past them keeps its PE address.
  - SizeOfImage names the image: the already-copied check, ml352's stale check, the purge on add
    and the module name.
- **Resources through a copy** (`patches/wine-pe` 0048):
  - winecrt0's `&__ImageBase` is the copy's base. `LdrFindResourceDirectory_U`,
    `LdrFindResource_U` and `LdrAccessResource` turn it into the PE view's.
  - The first 16 such lookups per image are logged.
- **The counts** are `head_trimmed` (the 17th `ios_jit_pool_stats` field) and `trimmed_mb` on the
  `pool:` line.

## Consequences

- Hollow Knight's head fell from 84 to 62 MiB, with its first frame at 9.9 s.
- In RDR2's play, RDR2.exe now loads its system DLLs. It then ran the pool out at `rsaenh.dll`:
  the tail had taken the room the copies freed (0116's rule lets a launcher process take a
  128 MiB code buffer while the room allows).
- 16 KiB section alignment for the builtins is the second step of PLA-377, measured separately.
