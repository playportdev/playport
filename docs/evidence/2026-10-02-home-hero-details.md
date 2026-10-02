# Home hero opens details without a duplicate Recent tile

The Home hero opens its game details page instead of starting the game. The
in-card action capsule is removed; the card remains actionable by touch or A,
with Open in the footer. Recent excludes the hero before taking four games,
so the next eligible game fills the freed tile.

## Checks

- `./pp test`: passed, including Recent exclusion tests for Steam and local
  titles, filling four tiles, no hero, and a zero count.
- `./pp install`: upgraded in place; IPA verification passed all 71 checks.
- Installed dev IPA SHA256:
  `b8df003daedde1fe05cb35cb208e9e034598f9ee6d258028dff84be84b6fb5f7`.
- `./pp ui --action open:home --action pad:a --shot-each-action --wait 60`:
  result ok, both actions completed. Run:
  `.work/ui-runs/20261002T131055/`.

`action-01-open_home.png` shows The Witcher 3 as the hero, with title and play
history but no action capsule. Recent shows Hollow Knight, Portal 2, #DRIVE
Rally and Among Us; the hero is absent and four tiles remain.
`action-02-pad_a.png` shows the hero's game details page, with its separate Play
control focused. The driver reports `page library (game page)`; no game starts.
Screenshots remain in the run directory, not in this evidence record.
