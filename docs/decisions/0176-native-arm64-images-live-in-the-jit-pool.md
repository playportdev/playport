# 0176: A native ARM64 child's images live in the JIT pool

**Status:** accepted, 2026-11-01, by the supervisor under the owner's delegation of all
decisions for the World of Warcraft work ([PLA-514](https://linear.app/playportdev/issue/PLA-514)).
Amends [0170](0170-native-arm64-guests.md) and [0175](0175-anti-cheat-refusal-scope.md)
("never patched" now covers the game's files, not its memory).

**Amended 2026-11-01 by [0177](0177-wow-plays-its-x64-client-through-fex.md):** World of Warcraft no longer runs as a native ARM64 child; what follows applies to other native ARM64 programs, and its amendment of 0175 is replaced by 0177's.

## Decision

- **The pool copy is the image.** For every PE image mapped into a native ARM64 child (0170): the
  executable and its DLLs, except the child's private ntdll. NtMapViewOfSection, and the main
  module's mapping, return the image's JIT-pool copy as the module's base. So the PEB's
  `ImageBaseAddress`, the loader's `DllBase` and entry points, `GetModuleHandle`,
  `RtlPcToFileHeader` and the unwinder's function-table lookups all hold the address the code
  runs at. The copy holds the whole image, headers, `.rsrc` and `.reloc` included, and its
  header's `ImageBase` is the copy's address.
- **The PE view stays as a hidden backing store.** It is Wine's view and the server's, and is never
  reported to the guest. NtQueryVirtualMemory (basic and image information), NtProtectVirtualMemory
  and NtUnmapViewOfSection take the copy's addresses and answer in them. The pool copy is the
  truth, so the IAT sync never copies the view over it.
- **Exceptions in a presented copy keep their pool pc** as `ExceptionAddress`, with no translation
  to the view.
- **Every instruction that reads x18 is patched** (madeira-unix 0263). Code bytes and data reads
  of code stay as patched: a validation build that served the original bytes to WoW's own
  .text hash loops made it fail sooner (evidence 2026-10-31-wow-arm64-start).
- **x86-64 and ARM64EC processes are unchanged.** Their images keep the PE address as the image,
  and the pool copy as an alias their code runs from.
- **Amends 0175.** 0175 said Playport modifies neither an allowed game's files nor its memory.
  The image a native ARM64 child runs is rewritten in memory: every x18 reader patched, the
  header's `ImageBase` set to the copy, the relocations applied, and, by the amendment below, its
  section views remapped and its decrypted code patched at `FlushInstructionCache`. The game's
  files are never changed, and nothing is spoofed beyond Wine. Warden may see the rewritten image,
  so the ban-risk notice says the runtime rewrites some of the game's instructions in memory and
  Blizzard may detect it (0175's amendment).

## Why

World of Warcraft's ARM64 client computes RVAs from its own code addresses (ADRP, so pool
addresses) against its module base. With the PE view reported as the base, every such RVA was off
by the distance between the copy and the view, and the client failed in its start-up checks
("Game Initialization Failed", run 20261031T234647). On Windows the code runs at the module's base,
so one address space for both is the only consistent model. The x64 path never met this, because
FEX executes guest code at PE addresses.

## Costs

- Writes to a presented image's read-only or code pages through the copy's RX alias go through the
  Mach handler's store emulation, one fault per store, as anonymous JIT memory does.
- The child's ntdll stays on its view: the unix side writes its dispatcher slots there and syncs
  them into the copy.
- The full copy costs the trimmed `.rsrc`/`.reloc` bytes again in the pool.

## Amendment, 2026-11-01: an image that remaps itself (madeira-unix 0264)

World of Warcraft's ARM64 client replaces its image with a section of its own: a
`SEC_COMMIT | SEC_NO_CHANGE` section of SizeOfImage, mapped read-write, the image copied into it,
the image unmapped, then three views of the section at the image's base (code RX, `.data` RW, the
rest RO). It then decrypts its code a function at a time through the read-write view, with
`FlushInstructionCache` on each, and runs it at the base. The base is the pool copy, which takes
code only through the pool's RW alias, so no section view can sit there.

- **A plain section view mapped at a presented copy's address** is mapped where the image's PE
  view was (the hidden backing store again). Its bytes are copied into the copy through the RW
  alias, x18-patched and flushed, and the caller gets the copy's address.
- **The section's other views become the copy.** Every view a native child maps of a plain
  section is recorded with the section's file and offset; the views of a section that is mapped
  at a copy are `vm_remap`ped onto the copy's RW alias, so a write through them is a write to the
  code that runs, as on Windows. The backing stores keep the section's bytes as of the remap.
  That needs the copy and the view host-page aligned alike: since madeira-unix 0271 a native
  child's copy starts on a 16 KB page unless code shares its first writable section's page (other
  processes still shift the copy so that section starts a page, which left retail's copy 0x3000
  past one and none of its read-write view one with the copy).
- **`FlushInstructionCache` on such a view, or on a presented copy,** x18-patches the code
  reachable from the flushed address (fall-through and branches, not calls, up to a RET, BR,
  their authenticated forms RETAA/RETAB/BRAA/BRAB(Z), a UDF or an unallocated word) from the rest
  of the image's trampoline reservation. Since madeira-unix 0265 it also patches what the image's
  `.pdata` function starts reach (with BL calls too) inside the 1 KB windows of .text that differ
  in a quarter of their words from the backing store: the client decrypts its whole .text in
  place with no flush, then flushes each view of the image once, and the flushed address alone
  reaches nothing (evidence 2026-10-31-wow-arm64-start, "decrypts all of its .text at once").
  Since 0270 every word of those functions is code (their length from the unwind data), so a
  switch case entered only through a jump table and a `br` is patched, except the data among
  them: jump tables and constants an ADR/ADRP addresses for a load, and LDR (literal) targets,
  where a data run never starts at a word code falls through to (the client loads its own code
  as literals) nor at a function start.
- **The load's x18 patcher leaves encrypted bytes alone, in a native ARM64 child only.** A 1 KB
  window of .text with more than 8 of its 256 words in the unallocated encoding groups (op0
  `0b0001`, `0b0011`) is data. No compiler emits those words; encrypted bytes put an eighth of
  theirs there, and a patched encrypted word decrypts to garbage. The trampoline reservation
  still counts those windows. Images in x86-64 and ARM64EC processes, and every child's private
  ntdll copy, are patched whole, as before (their literal pools and x64 tails can look like such
  windows).
- **A native child's copy gets every relocation,** whatever the value, as Windows' loader applies
  them (the client has 95 on encrypted .text words).

Costs: a view mapped before the remap stays one with the copy until it is unmapped; its last
partial host page is not aliased. Code reached only through an indirect branch and outside every
`.pdata` function is not patched and leaves its x18 reads to the fault path. Junk words inside a
`.pdata` function (after its branches) are patched with it; a constant whose run starts after
fall-through code, or a table whose address no ADR/ADRP-and-load pattern gives, would be taken
for code.
