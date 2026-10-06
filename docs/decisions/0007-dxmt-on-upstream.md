# 0007: DXMT from its own upstream, with Madeira's port as a series

**Status:** accepted, 2026-09-24. Supersedes, for DXMT only, the consequence
of [0001](0001-superproject-on-madeira.md) that Madeira's gitlink decides
which DXMT commit is built. Under [0054](0054-madeira-frozen.md) the Madeira pin is frozen, so the `dxmt-port` row is a frozen provenance record of the fork commit the port series came from.

## Decision

Playport tracks the latest upstream FEX, Wine and DXMT with Madeira's and its
own patches, taking the components one at a time: DXMT first, then FEX, and
Wine only after a separate go-ahead once the cost of the first two is known.

For DXMT this means:

- `pins.lock`'s `dxmt` row is a commit of
  [3Shain/dxmt](https://github.com/3Shain/dxmt) `main`, not Madeira's
  `research/dxmt` gitlink.
- Madeira's DXMT port (`willfaust/dxmt` `ios-port`, 44 commits at the time)
  is carried rebased onto that commit as `patches/dxmt-port`, one patch per
  Madeira commit with `Madeira-commit:` naming the original.
- Playport's own DXMT changes stay in `patches/dxmt`, applied after it.
- The `dxmt-port` row records the Madeira DXMT commit the port series was
  rebased from. The build refuses to run when Madeira's `research/dxmt`
  gitlink differs, so a Madeira DXMT update is re-ported deliberately rather
  than silently ignored.

The base is upstream `main`, not the latest release: v0.80 (2026-04-23) was
five months and 244 commits behind `main` when this was decided, and the ask
is to be on the latest DXMT. A later rebase may pick a release tag instead when
one is recent.

## Why

Playport wants the latest DXMT, FEX and Wine, accepting that this makes it a
standing integrator of a jailed-iOS port (Madeira had never rebased its DXMT
or Wine forks). DXMT goes first because it is the cheapest of the three: Madeira
keeps no whole-file replacements of DXMT sources outside the fork, upstream
moves 45-90 commits a month, and D3D11 fixes reach titles directly.

## What it costs

Measured on the first rebase ([record](../evidence/2026-09-24-dxmt-latest-rebase.md)):

- 11 of Madeira's 44 commits needed a real three-way resolution, one became
  empty (upstream had implemented the same thing) and one Playport patch was
  superseded; three semantic breaks showed no textual conflict at all.
- Both sides append winemetal unix calls with explicit slot numbers. Every
  rebase has to reconcile the two lists and regenerate the guard and census
  tables; a slot mismatch builds cleanly and calls the wrong function.
- Upstream DXMT relicensed from MIT to LGPL-2.1-or-later after v0.80, so the
  DXMT code Playport ships changed licence with this move
  ([LICENSING.md](../LICENSING.md)).
- Every later upstream DXMT change and every Madeira DXMT change is a
  hand-driven re-port followed by the full device gate, never automatic.
  Upstream-sync never moves the `dxmt` pin; it only holds on a Madeira DXMT
  change.
- Madeira's `madeira_d3d12.dll`, which Playport does not build or ship, no
  longer matches this winemetal ABI.
