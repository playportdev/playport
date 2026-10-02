# Library store filters and duplicate badges — 2026-10-02

## Build and checks

- Final dev IPA: `.work/out/20261002-151336-15de0db3/Playport-26.5-15de0db3.ipa`.
- SHA256: `15de0db3d1b2c083e6b155949899ca0c941f620b3cf58693f7c57ab7d8618f24`.
- `pp test`: all host checks passed, including 131 PlayportKit tests. Coverage:
  filter order/counts; source labels; installed Steam copies without current
  ownership; same-name local/Steam copies staying separate; duplicate badge
  eligibility only in All/Installed; full-library detection when the other copy
  is not installed; case/accent/edge-whitespace matching; no badges for same-source
  copies, blank names or an installed/owned Steam merge.
- `pp check`: dev app compiles. `pp install`: 71 IPA checks passed; upgraded in
  place, keeping the container. No runtime trees or artifact records changed.

## Phone runs

Screenshots remain in the run directories under `.work/ui-runs/`.

```sh
./pp ui --action open:library --action pad:view+down+a \
  --action pad:view+down+a --action pad:view+up+up+a \
  --shot-each-action --out .work/ui-runs/library-store-filters-final
./pp ui --action open:app-367520 --action open:home --action open:library \
  --shot-each-action --out .work/ui-runs/library-store-details-final
./pp ui --action open:library --action pad:right+right+right+a \
  --shot-each-action --out .work/ui-runs/library-store-details-uninstalled
```

Results: `ok actions=4`, `ok actions=3`, `ok actions=2`, all exit 0, all on
that final IPA. Screenshots inspected:

- Filters: All selected by default, followed by Installed and Steam, counts
  81, 3, 81. Controller picker advances to Installed (three games), then Steam,
  then back to All. None of these games is duplicated across sources, and no
  tile badge appears. Recent remains the default sort, not a filter.
- Installed Hollow Knight details: the facts card starts with **Store · Steam**,
  followed by Last played, Play time, Cloud saves and On this phone.
- Uninstalled #DRIVE Rally details: **Store · Steam** appears above Download and
  Version. The page was opened with the controller; no Install was pressed.
- Home: neither the hero nor recent game tiles carries a source badge.

The longer preceding run in `.work/ui-runs/library-duplicate-badges/` completed
all filter transitions but lost the app when the phone locked before the details
check. A subsequent launch confirmed the phone was locked. After the person
unlocked it, the three shorter runs above passed; the failure was not an app
crash verdict or a successful details check.

The phone has only Steam games, with no cross-source duplicates. The positive
badge condition and Local labels were checked in host tests, not visually on
this device. The small badge artwork layout had been inspected in the earlier
all-badges draft (`.work/ui-runs/library-store-filters/`), but that draft's display
policy is superseded: badges are now duplicate-only, in All/Installed only.
No other store adapter exists yet. No game launch was needed for this UI change.
