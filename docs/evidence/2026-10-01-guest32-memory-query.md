# Portal 2: checked guest memory queries

## Verdict

The separated-memory prototype now provides `g32_query`, a read-only snapshot
of guest reservation ownership, commit state and per-4-KiB-page permissions.
This supplies query groundwork for a future Win32 memory bridge without
mistaking coarse native protections for guest access rights.

**Portal 2 remains unplayable.** No Wine syscall, execution bridge, game binding
or graphics path changed. The dev memory target shares this C source but its
probe does not call the new API. No IPA build/install or phone run was performed:
**not checked on the phone**, with no device-run IPA SHA256.

## Contract and observations

- Any 32-bit byte address is queryable. The returned region starts at its
  rounded-down guest page and scans forward only, stopping on a change in
  ownership, commit state or permissions. It does not search backward.
- The low 64 KiB is `BLOCKED`; unowned pages are `FREE`. Neither reports an
  allocation base or permissions. `RESERVED` reports the original allocation
  base with no access; `COMMITTED` reports its current guest permissions.
- A committed no-access page and a decommitted reserved page both reject
  translation, but their query states differ. Commit state cannot be inferred
  from whether a checked read succeeds.
- Adjacent reservations with identical permissions remain separate query runs,
  although ordinary checked accesses can span them. Querying inside a run
  reports its forward suffix, not the allocation's full extent.
- An initially free query at `0x10000` reports size `0xffff0000`; a query at
  `0xffffffff` reports one page starting at `0xfffff000`. Wide size/end
  arithmetic avoids wrapping the exclusive end at 2^32.
- Querying does not touch native backing, broaden permissions, change guest
  bytes or produce a host pointer. Invalid calls preserve output. A poisoned
  space is rejected as for other VM operations; no failure injection was added.
- Snapshots require external serialization and expire on any VM change. The
  worst-case scan covers all guest pages. This is not an access-check fast path
  or Windows `MEMORY_BASIC_INFORMATION`: allocation protection, mapping type,
  guard/write-copy semantics and a Wine ABI adapter remain absent.

## Validation

- `pp test --quick`: passed names/secrets, pins/patch series, 480 tooling tests
  and all host C tests. Swift tests were not requested.
- Optimized and AddressSanitizer + UndefinedBehaviorSanitizer memory suites:
  passed at native, simulated 16 KiB and 64 KiB host granules. New cases include
  every permission combination, no-access vs decommit, adjacent ownership,
  interior byte addresses, release/reuse, separate spaces, unchanged live data,
  full metadata-only reservation and exact top-of-space bounds.
- At each granule an independent 256-page oracle checks every page after 1024
  deterministic mixed reserve/release/commit/decommit/protect attempts. Failed
  protection changes leave query results consistent with the oracle. Coverage
  assertions ensure every operation and free/reserved/committed state occurs.
- Existing PE32 sanitizer suite passes with the private launcher/engine files
  and synthetic loader tests. Input hashes remain those in
  [mapping evidence](2026-10-02-guest32-pe32.md); no game instruction executes.
- Clang static analysis: no diagnostics. `guest32.c` cross-compiles for
  `arm64-apple-ios26.5` with `-Wall -Wextra -Werror`; not executed on iOS.
- `git diff --check`: clean.

Private logs in `.work/guest32/`: `query-optimized.log`, `query-sanitized.log`,
`query-pe32-sanitized.log` and `iteration7-quick.log`. Reproduction commands
and remaining execution gates: [build/guest32](../../build/guest32/README.md).
