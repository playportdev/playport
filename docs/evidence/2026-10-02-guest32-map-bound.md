# Portal 2: PE32 map, bind and finalize transaction

## Verdict

`build/guest32/pe32.{h,c}` now provides `g32_pe_map_bound`: materialize and
relocate a new image, bind its imports, then apply final PE page permissions.
This removes the read-only IAT construction-order blocker in the **host
prototype**, without leaving those pages writable or changing existing-image
binding semantics.

**Portal 2 is still unplayable.** No Windows APIs were implemented or game
instructions executed. The PE mapper remains outside the app. No phone run,
installation or runtime modification was performed; there is no device-run IPA
SHA256. This is not a fix to the shipped Wine image loader.

## Contract and safety

Dependencies must already be mapped. The required external resolver uses the
existing guest-address binding contract, including named/ordinal/data targets,
host-pointer rejection, import snapshots and resource limits. During callbacks
the unpublished image is guest RW, not executable. Callbacks must not access
that image, change guest memory/mappings, retain its loans or reenter the API;
checked export lookups in existing dependencies remain supported.

Final protections are applied before publishing image metadata. Every import
target is revalidated afterward: a self-target readable only under temporary
construction permissions must not escape into a successful result. An
execute-only self-target remains valid. No write loan is used after finalizing.

Any failure, including unresolved imports or a post-write entry/target check,
leaves caller output unchanged and releases only the newly acquired image
reservation. Existing dependencies survive. Resolver-side effects are not
rolled back. Native VM failure may poison the space, requiring its destruction,
as for the original mapper. Binding an **existing** image still refuses
read-only IAT slots and never broadens permissions.

## Private installed-image layout checks

Inputs retain the hashes recorded in [mapping evidence](2026-10-02-guest32-pe32.md):

| Input | SHA256 |
| --- | --- |
| `portal2.exe` | `18b57b16d8cf8de731d91bff236bf84fbfe1e08c67169f582086dec0e100a8c8` |
| `engine.dll` | `49ac3268cf27b7e8c7c5f00dea7a45d8e2fa113c913012f5144ef81db754f6df` |

With simulated 16 KiB host granules, both preferred and relocated image layouts
passed the new construction path:

| Input | Guest bases, tested separately | IAT words patched per mapping |
| --- | --- | --- |
| launcher | `0x00400000`, `0x20000000` | 70 |
| engine | `0x10000000`, `0x20000000` | 444 |

**Every entry was patched to inert readable test data at `0x30000000`, not a
function or Windows API implementation.** These are layout-only fixtures, not
callable game imports. The full mapped images matched their previously mapped
bytes with only the expected four-byte IAT overlays; every IAT slot rejected
writes after finalization. Separate unresolved map-and-bind attempts preserved
output and released the reservation, verified by reserving the same range again.
No game data was modified on disk or on the phone.

## Validation

- `pp test --quick`: passed, including names, secrets, patch checks, 480 tooling
  tests and all host C tests. Swift tests were not requested.
- Synthetic cases at native, 16 KiB and 64 KiB host granules cover read-only IAT
  pages, unaligned cross-guest-page slots, preferred/relocated images,
  FirstThunk-only snapshots, function/data imports resolved through dependency
  exports, execute-only self-targets and rejection after final permission loss.
- Late unresolved imports, high/native/null/gap targets, malformed import
  metadata, parser/relocation failures, failed entry finalization, no-import
  images, missing resolver and reservation conflicts pass rollback checks.
  Dependency bytes and source fixture bytes remain unchanged.
- AddressSanitizer + UndefinedBehaviorSanitizer: passed, including both private
  files at both guest bases and the existing 4096 malformed-file mutations.
- Clang static analysis: no diagnostics.
- `pe32.c` cross-compiles for `arm64-apple-ios26.5` with `-Wall -Wextra -Werror`
  against the recorded SDK. Not executed on iOS.
- `git diff --check`: clean.

Repeatable host commands and remaining runtime gates are in
[build/guest32/README.md](../../build/guest32/README.md). Private logs are
`.work/guest32/map-bound-checks.log`, `map-bound-host-tests.log` and
`map-bound-sanitized.log`; game files remain under `.work/portal2-files/`.
The next execution gate still requires translated x86 instruction execution and
an actual WoW64/Wine ABI bridge, not placeholder IAT targets.
