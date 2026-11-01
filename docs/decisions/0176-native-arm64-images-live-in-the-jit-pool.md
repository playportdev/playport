# 0176: A native ARM64 child's images live in the JIT pool

**Status:** accepted, 2026-11-01, by the supervisor under the owner's delegation of all
decisions for the World of Warcraft work ([PLA-514](https://linear.app/playportdev/issue/PLA-514)).
Amends [0170](0170-native-arm64-guests.md).

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
