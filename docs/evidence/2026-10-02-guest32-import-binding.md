# PE32: transactional guest-address import binding

## Result and limits

`build/guest32/pe32.{h,c}` can now bind named and ordinal IAT entries to
caller-resolved **guest** addresses, without embedding high native pointers or
partially writing an image when a later import fails. Synthetic function and
data imports bind into a separately mapped dependency image in the same guest
space. All backing remains native non-executable memory above 4 GiB.

**Portal 2 remains unplayable. No guest instructions executed, no game import
resolved, no phone run performed.** This host-only primitive is not linked into
the app, does not change Wine/FEX, and supplies neither dependency loading nor
export lookup, Windows process state, syscall marshalling or D3D9 bridges. Pins,
patch series and app/build artifact records are unchanged.

## Contract

- Snapshot all import names and guest IAT addresses before invoking a resolver
  or writing slots; bounded at 65536 imports per binding.
- Reject malformed later metadata and overlapping slots before callbacks.
- Accept wide resolver output only if it fits a guest address and points to
  readable data or fetchable code in the same guest space. Never truncate a
  native pointer. Null, guarded, uncommitted and inaccessible targets fail.
- Validate all writable IAT loans after resolution, then write in a serialized,
  non-fallible commit phase. No guest permissions are widened by binding.
- Failed binding preserves guest bytes and protections, not external resolver
  side effects. Callbacks must not mutate the space or reenter this API.
- FirstThunk fallback works via the snapshot; rebinding requires preserved
  lookup data. A separate OriginalFirstThunk permits rebinding.

## Real installed files

The private files and hashes are unchanged from the
[PE32 mapping evidence](2026-10-02-guest32-pe32.md). Both real images still map
and inspect at preferred and relocated addresses. For each of those four
variants, an intentionally unresolved resolver fails binding and an independent
before/after copy of the **entire mapped image** compares equal. This proves
refusal without mutation, not working dependency resolution.

Independent PE section inspection found:

| Image | Imports | Guest pages holding IAT slots | Read-only IAT slots |
| --- | --- | --- | --- |
| `portal2.exe` | 70 | 1 | 70 |
| `engine.dll` | 444 | 1 | 444 |

A future loader must bind these imports before final section protections, or
explicitly manage and restore temporary guest page permissions. Automatically
changing a coarse native page's protections would not enforce the 4 KiB guest
contract on iOS. This binder intentionally refuses read-only IAT slots.

## Validation

- `pp test --quick`: passed, including 480 tooling tests and all host C tests.
- Binding tests pass with native, simulated 16 KiB and 64 KiB host granules.
- AddressSanitizer + UndefinedBehaviorSanitizer: passed, including real-image
  unresolved-import refusal at both addresses.
- Existing real-image mapping results remain 70 launcher and 444 engine imports,
  with 919 and 146206 HIGHLOW fixups respectively when relocated.

Tests also cover late resolution failure, function/data and execute-only targets,
wrong-space and high native-pointer rejection, read-only and cross-page IAT
slots sharing native backing, malformed later records, overlapping writes,
resource exhaustion refusal, rebinding and empty import directories. Commands
are in [build/guest32/README.md](../../build/guest32/README.md); private validation
logs are `.work/guest32/import-binding-checks.log` and
`.work/guest32/import-binding-sanitized.log`. No game data is committed.

Next work still needs actual export/dependency resolution and a checked 32-bit
CPU/Wine bridge; this change alone does not fix the shipped image-map failure.
