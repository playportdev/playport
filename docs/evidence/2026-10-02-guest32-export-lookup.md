# PE32: checked guest-address export lookup

## Result and scope

`build/guest32/pe32.{h,c}` now supports checked named/ordinal export lookup,
returning guest function/data addresses or bounded forwarder strings. Synthetic
imports bind through actual lookups in a synthetic dependency, rather than
hard-coded resolver addresses. This is the missing lookup primitive for the
[transactional import binder](2026-10-02-guest32-import-binding.md), not an
integrated Windows loader.

**Portal 2 remains unplayable. No guest instructions executed, no game imports
resolved, and no phone validation performed.** The PE32 prototype is host-only;
no app/runtime, upstream patch, pin or build record changed. Dependency loading,
forwarder following/cycle handling, TLS, Windows process state, checked FEX/Wine
execution and 32-bit graphics/audio/input bridges remain absent. The real IATs
remain read-only, and this lookup does not change their permissions.

## Contract

- Exact case-sensitive name lookup or full export ordinal, not EAT index.
- Holes and missing names/ordinals return `G32_PE_NOT_FOUND`; output remains
  unchanged for every failure. Guest bytes and permissions are never modified.
- Validate full readable table spans and every name/ordinal pair, including
  malformed later names after a match. Aliases and unsorted names work;
  duplicate matching names fail. Unselected EAT targets are not validated.
- Direct targets must be readable or fetchable within the owning image in the
  same space. Return only 32-bit guest addresses, never native backing pointers.
- RVAs inside the export-directory range produce a nonempty copied forwarder
  string, bounded by that range and 260 bytes including NUL. No address is
  returned for a forwarder, and no dependency is followed automatically.
- Bound functions/names independently to 65536 entries and names to 260 bytes
  including NUL. Live metadata and external serialization are required.

## Installed files

Private files retain the hashes from the
[original inspection](2026-10-01-portal2-32-bit.md). `portal2.exe` has no export
directory. `engine.dll` has exactly two export entries, both named direct code
exports with ordinal base 1:

| Name | Ordinal | RVA | Preferred guest address | Relocated guest address |
| --- | --- | --- | --- | --- |
| `?F@@YAXPAPAVIEngineAPI@@@Z` | 1 | `0x001f6d70` | `0x101f6d70` | `0x201f6d70` |
| `CreateInterface` | 2 | `0x0027b9b0` | `0x1027b9b0` | `0x2027b9b0` |

The optional private-file test compares all named and ordinal lookups against
independent raw-file section/RVA conversion at both preferred and relocated
bases. `llvm-readobj --coff-exports .work/portal2-files/engine.dll` independently
reports the same names, ordinals and RVAs. Entire mapped-image before/after
comparisons remain identical after lookup and deliberate unresolved-import
refusal for both files at both addresses. None of these addresses was called.

## Validation

- `./pp test --quick`: passed, including 480 tooling tests and all host C tests.
- Synthetic export lookup and lookup-backed binding: passed with native,
  simulated 16 KiB and 64 KiB host granules.
- AddressSanitizer + UndefinedBehaviorSanitizer: passed, including all four
  real-image mappings and independent export comparisons.
- 4096 deterministic malformed-file mutations now exercise export lookup too.
- `git diff --check`: clean.

Tests cover named/ordinal/data/execute-only exports, aliases, missing entries,
zero EAT holes, full-width ordinals, ordinal overflow, resource limits, empty
exports, malformed/unreadable tables and later names, cross-guest-page tables
and strings sharing native backing, duplicate matching names, invalid targets,
wrong-space calls, forwarders by name/ordinal and unterminated/empty/oversized
forwarder strings. Failed lookup preserves output.

Commands are in [build/guest32/README.md](../../build/guest32/README.md). Private
logs are `.work/guest32/exports-host-checks.log` and
`.work/guest32/exports-sanitized.log`; no game files or private identifiers are
committed. This change does not fix the shipped image-map failure or establish
playability.
