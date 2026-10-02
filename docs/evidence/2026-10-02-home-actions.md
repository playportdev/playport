# Home has no Options or Search shortcuts

Removed Home's X Options and Y Search footer actions and their controller
bindings. A still opens cards; Settings remains available. Search stays in
Library, and X Game options stays on game details. Removed the unused Home
item-to-title helper and updated Home comments.

## Checks

- `./pp test`: passed.
- `./pp check`: dev app compiled.
- `./pp install`: upgraded in place; 71 IPA checks passed.
- Installed IPA SHA256:
  `6f44394ec3ff5c2db0e19be2b77858a15903f493c949fd88f79788b9fe2b3ff6`.

## Phone

Run `.work/ui-runs/home-without-options-search` with `--shot-each-action`
ended `ok actions=10`. X and Y left Home and its hero focus unchanged; after
moving to a recent tile, X+Y also left Home and focus unchanged. Screenshots
show only A Open and Settings in Home's footer. On Hollow Knight details,
X still opened Game options; B twice restored Home's recent tile. Library's
Y still opened the search keyboard. No game was launched or installed.
