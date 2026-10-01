# Portal 2: bounded automatic guest reservations

## Verdict

The separated-memory prototype now supports `g32_reserve_any`: deterministic
first-fit reservation within a caller-supplied guest-address window. Future
loader dependencies, heaps and stacks can obtain nonoverlapping addresses
without hard-coded placements. Selection and reservation are one externally
serialized call, with no native VM operation or backing commit.

**Portal 2 remains unplayable.** The Wine mapping failure, execution bridge and
32-bit graphics path are unchanged. This is a memory building block, not
VirtualAlloc, automatic PE dependency loading or game execution. No phone run
or IPA build/install was performed; the change is **not checked on the phone**
and has no device-run IPA SHA256. The dev memory target uses the same source
through its existing symlink, but its UI probe does not exercise the new API.

## Contract and observations

- Bounds are `[lower, upper)` with a 64-bit exclusive upper bound, allowing
  exactly 2^32. Base alignment is rounded upward in wide arithmetic; size
  remains a nonzero multiple of 4 KiB. The low 64 KiB remains unavailable.
- Selection scans reservation ownership, not read/write permissions or commit
  state. Decommit does not make a reservation available; release does.
- An occupied page anywhere in a candidate extent rejects that candidate.
  Skipping beyond that page cannot skip a valid earlier aligned placement.
- Invalid parameters and valid-but-exhausted windows have different results.
  Failure preserves the caller's output, ownership, bytes and protections.
- An occupied launcher-layout reservation at `0x400000`, size `0x5c000`, makes
  the next fitting base `0x460000`, not the unaligned image end `0x45c000`.
  Release restores the original preferred-base placement. This is a synthetic
  reservation test using the recorded layout, not loading or relocating a game.
- The PE mapper's existing preferred/explicit-base API is unchanged. Integrating
  automatic placement must avoid reserving twice and must honor relocation
  availability; that is outside this iteration.

## Validation

- `pp test --quick`: passed, including names/secrets, pins/patch series,
  480 tooling tests and all host C tests. Swift tests were not requested.
- Optimized and AddressSanitizer + UndefinedBehaviorSanitizer memory tests:
  passed at native, simulated 16 KiB and 64 KiB host granules. Each compares
  2048 deterministic mixed allocation/release attempts with an independent
  brute-force page oracle, with nonzero allocation, exhaustion and release
  coverage. Boundary, fragmentation, live-neighbor preservation, decommitted
  ownership, full metadata-only address-space exhaustion and reuse tests pass.
- Existing PE32 sanitizer suite also passes with the private launcher/engine
  files and all synthetic loader tests. Game-file hashes are unchanged from
  [the mapping evidence](2026-10-02-guest32-pe32.md). No new real API bindings
  or execution were tested.
- Clang static analysis: no diagnostics. `guest32.c` cross-compiles for
  `arm64-apple-ios26.5` with `-Wall -Wextra -Werror`; not executed on iOS.
- `git diff --check`: clean.

Private logs: `.work/guest32/allocation-optimized.log`,
`allocation-sanitized.log`, `allocation-pe32-sanitized.log` and
`iteration5-quick.log` (all under the same directory).
Reproduction and remaining execution gates: [build/guest32](../../build/guest32/README.md).
