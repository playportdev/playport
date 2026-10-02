# Main sections switch with LB/RB, not B

Main-section selection starts a new navigation root rather than Back history.
Library and Downloads no longer offer B Back; B still clears Library search
and returns from nested game, Settings, setup and sign-in screens.

## Checks

- `./pp test`: passed (124 PlayportKit tests, including main-section no-op
  Back, nested return to Library and discarded history on section selection).
- `./pp check`: dev app compiled.
- `./pp install`: upgraded in place; 71 IPA checks passed.
- Installed IPA SHA256:
  `6a36ad7c50937c74888335c495e889d3d9a78b2aee2084c449c8288371a1ce3f`.

## Phone

`./pp ui --shot-each-action`, run `.work/ui-runs/main-section-navigation`,
ended `ok actions=11`. From Home, RB selected Library; B kept the same Library
and focus. RB selected Downloads; B kept Downloads. RB wrapped to Home;
LB selected Downloads then Library. Opening Hollow Knight and pressing B
returned to Library; another B kept Library. Screenshots confirm Library and
Downloads have no B Back footer entry. No game was launched or installed.

This supersedes the main-section Back-history behavior recorded in
`2026-10-02-routing-return-origin.md`; nested origin restoration is unchanged.
