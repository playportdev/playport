# Portal 2: bounded mapped-dependency resolution

## Verdict

The host PE32 prototype can now resolve imports through an explicit set of
already-mapped dependencies, including named and ordinal export forwarders.
It returns checked guest addresses, not native pointers or callable forwarder
strings. This replaces the synthetic caller-specific resolver with a reusable
loader building block.

**Portal 2 remains unplayable.** No game instructions, Windows API implementation,
DLL attachment or dependency loading were added. This code is not linked into
the app. No phone run, install or runtime modification was performed, so there
is no device-run IPA SHA256. The shipped Wine mapping failure is not fixed.

## Contract

`g32_pe_modules_create` snapshots normalized ASCII basenames and live image
metadata in one guest space. Names compare case-insensitively and gain `.dll`
only when no dot exists. Paths, duplicate canonical names, wrong-space and
unmapped inputs are rejected. Aliases of one image are allowed. Caller-owned
name/image metadata may change after creation; the snapshot is independent.
Guest images must remain live and externally serialized: the table does not
own their lifetime. Table destruction never unmaps them.

`g32_pe_resolve_export` follows forwarders using the last dot as separator,
including explicit module extensions. `#ordinal` accepts only decimal digits
and checks full `uint32_t` overflow, rather than truncating to an import thunk's
16-bit ordinal. Zero and `UINT32_MAX` are supported when the export table permits
them. Names remain case-sensitive. Cycle detection uses image base plus selected
export ordinal, so module aliases and name/ordinal aliases cannot hide a cycle.

Missing modules/exports, malformed syntax, cycles and exhausted depth have
separate results. At most 256 modules and 32 selected exports are permitted.
Failed creation/resolution preserves caller output; no guest bytes or permissions
are changed. `g32_pe_resolve_import` adapts the table to transactional binding,
turning any failure into an unresolved import. There is no filesystem search,
API-set mapping, automatic module allocation/loading, TLS, PEB/TEB or execution.

## Checks

- `pp test --quick`: passed, including names, secrets, pin/patch checks,
  480 tooling tests and all host C tests. Swift tests were not requested.
- Synthetic resolution tests pass at native, 16 KiB and 64 KiB host granules:
  direct/forwarded function and data targets, multi-hop name/ordinal lookup,
  last-dot parsing, case rules, canonical duplicates, metadata snapshots,
  missing/inaccessible targets, strict ordinal syntax/overflow, alias cycles,
  output preservation, exact depth and module-count limits.
- Forwarded imports bind through `g32_pe_map_bound` while final IAT pages remain
  read-only. Cyclic resolution rolls back the importer without changing dependency
  bytes or leaking its reservation. No placeholders are used in these synthetic
  resolution tests.
- Optimized and AddressSanitizer + UndefinedBehaviorSanitizer tests passed,
  including 4096 malformed-file mutations and the two private game files at both
  preferred and relocated guest addresses.
- Real `engine.dll` named/ordinal targets match independent raw-file tables
  through the module snapshot. `portal2.exe` still has no exports. Real binding
  with missing dependencies fails and preserves every mapped image byte.
  Inputs/hashes are unchanged from [mapping evidence](2026-10-02-guest32-pe32.md).
  Real-file IAT placeholder tests remain inert layout tests, not API resolution.
- Clang static analysis: no diagnostics. `pe32.c` cross-compiles for
  `arm64-apple-ios26.5` with `-Wall -Wextra -Werror`; not executed on iOS.
- `git diff --check`: clean.

Commands and remaining runtime gates: [build/guest32](../../build/guest32/README.md).
Private logs are `.work/guest32/forwarder-optimized.log`,
`forwarder-sanitized.log` and `forwarder-host-checks.log`. The next execution gate
still requires translated x86 instructions and the Wine/WoW64 ABI bridge, not
more inert IAT targets.
