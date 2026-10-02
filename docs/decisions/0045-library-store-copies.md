# 0045: Library filters and store copies

**Status:** accepted, 2026-10-02. Refines the Library in
[0034](0034-a-gamepad-first-ui.md); replaces the design's Installed,
All Steam games and Recently played filters, not its Recent sort.

## Decision

- Filters are **All** (default), **Installed**, then **Steam**. Future connected
  stores add their own filters after Installed. All includes local games and
  store games whether installed or not; Installed also includes queued downloads.
  A store filter describes origin, not whether the current account owns the copy.
- Only duplicated games in **All** and **Installed** carry a small, neutral,
  top-right store-name capsule. Steam and Home show no source badges. Determine
  duplicates from the full library, so the badge stays when another copy is
  filtered out or not installed. Every game details page always names its store
  in the facts card. Games without a known store say **Local**, not an inferred
  store name. The badge adds no button or focus target.
- Keep copies from different stores separate, even when their names match.
  Merge an installed copy with its matching store listing only. Installation,
  ownership, launch settings and saves must not transfer merely because names
  match. This keeps choosing a tile unambiguous without an extra store picker.
  For badge detection only, matching names (ignoring case, accents and surrounding
  whitespace) from different sources count as duplicates; copies within one
  source and blank names do not. This is a display heuristic, never a merge key.

## Costs and next stores

Steam is the only store adapter today. A known Steam app ID identifies Steam
origin even offline; other catalogued games are Local. Existing `app-<ID>` and
`dir-<folder>` identifiers remain unchanged, so saved settings are not migrated.
The new source labels and filters share model metadata; both chips and the
controller picker enumerate the filter list, and the chip row scrolls horizontally.

Before adding another store, extend catalogue and game references to carry an
explicit `(store, store game ID)` identity end to end, with store-qualified IDs
for new copies. Joins, artwork, download state and navigation must use that
identity, never a title name or a bare numeric ID shared across stores. This
change does not pretend the Steam-only download and launch paths support other
stores already. Same-name local/Steam separation is covered by host tests;
multiple real store adapters cannot yet be tested.

## Evidence

[Phone layout and filter-picker checks](../evidence/2026-10-02-library-store-filters.md).
