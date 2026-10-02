# Portal 2: bounded automatic PE32 placement

## Verdict

The separated-memory prototype now connects bounded reservations to PE32
mapping through `g32_pe_map_auto` and `g32_pe_map_bound_auto`. A future loader
can place colliding relocatable dependencies without supplying each base.
Both forms acquire exactly one reservation and use the existing relocation,
protection and rollback transaction; the bound form still needs a resolver
and already-mapped dependencies.

**Portal 2 remains unplayable.** No execution bridge, Wine mapping behavior,
Windows API or graphics path changed. This code is not linked into the app.
No IPA build/install or phone run was performed: **not checked on the phone**,
with no device-run IPA SHA256. The UI memory probe is unchanged.

## Contract and observations

- Bounds are half-open `[lower, upper)` with upper allowed to equal 2^32.
  The whole image must fit. A valid available preferred ImageBase wins even
  when an earlier address is free; otherwise first-fit uses 64 KiB alignment.
- An unavailable, invalid or out-of-window preferred base requires relocation
  records that are not stripped. A fixed-base image can still load at its
  available preferred base without records. Malformed fixups fail without
  retrying another address; the selected reservation is released.
- Invalid bounds return `ADDRESS`, valid exhausted relocatable windows
  `NO_SPACE`, and fixed-base fallback `RELOCATION`. Existing preferred/explicit
  APIs retain their behavior. Low 64 KiB remains inaccessible.
- Occupied later pages and decommitted reservations prevent overlap. Failed
  mapping/binding preserves output, live dependencies, blocker bytes and
  protections. Successful map-and-bind restores read-only IAT sections.
- With each real preferred image extent reserved, automatic placement chooses
  `0x00460000` for the launcher (`0x5c000` bytes at preferred `0x00400000`), and
  `0x10750000` for the engine (`0x74b000` bytes at preferred `0x10000000`).
  Relocation counts are 919 and 146206. All bytes match explicit same-base
  mapping in a separate space. This comparison checks allocation integration,
  not an independent relocation implementation or game execution.
- The real-image bound tests deliberately reject unresolved imports, verify
  rollback and reuse, then bind 70/444 IAT slots to inert readable test data
  only. Whole-image IAT-only overlays still match and final IATs are read-only.
  Blocker bytes survive both failures and successful unmaps. No test target
  implements a Windows API or is called. Source game-file hashes are unchanged
  from [the mapping evidence](2026-10-02-guest32-pe32.md).

## Validation

- `pp test --quick`: passed names/secrets, pins/patch series, 480 tooling tests
  and all host C tests. Swift tests were not requested.
- Optimized and AddressSanitizer + UndefinedBehaviorSanitizer PE32 suites:
  passed synthetic tests at native, simulated 16 KiB and 64 KiB host granules
  and private launcher/engine tests at 16 KiB. Cases include preferred-base
  priority, collisions, relocation availability/format, tight/unaligned bounds,
  exact top-of-space fits, exhaustion, output preservation, input immutability,
  finalization/binding rollback and live-neighbor preservation.
- Clang static analysis: no diagnostics. `pe32.c` cross-compiles for
  `arm64-apple-ios26.5` with `-Wall -Wextra -Werror`; not executed on iOS.
- `git diff --check`: clean.

Private logs: `.work/guest32/auto-optimized.log`, `auto-sanitized.log` and
`iteration6-quick.log` (all in that directory). Reproduction commands and remaining
execution gates: [build/guest32](../../build/guest32/README.md).
