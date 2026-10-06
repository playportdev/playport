# 0013: Wine from its own upstream, with Madeira's fork as a series

**Status:** accepted, 2026-09-26. Applies [0007](0007-dxmt-on-upstream.md)'s
and [0008](0008-fex-on-upstream.md)'s approach to Wine, the third and last of
the three components, and so ends, for every component, the consequence of
[0001](0001-superproject-on-madeira.md) that Madeira's gitlinks decide which
commits are built. Madeira's own code (`madeira`) is still its pin. Its
pin source is restated by [0049](0049-latest-pins.md): the newest WineHQ
development tag, `master` only with a recorded reason, moved at every tag. Under [0054](0054-madeira-frozen.md) the Madeira pin is frozen, so the `wine-port` row is a frozen provenance record of the fork commit the port series came from. The build's check that the row equals Madeira's `wine` gitlink still holds and never fires.

## Decision

- `pins.lock`'s `wine` row is a [WineHQ](https://gitlab.winehq.org/wine/wine)
  release commit (wine-11.18), not Madeira's `wine` gitlink. The build takes
  it from a mirror in `$PLAYPORT_BUILD/cache`, not from the
  `upstream/madeira/wine` submodule.
- Madeira's Wine fork (`willfaust/wine` `madeira-lgpl`, 56 commits on
  wine-11.4) is carried rebased onto that commit as `patches/wine-port`, one
  patch per Madeira commit with `Madeira-commit:` naming the original, plus
  Playport's follow-up to the new base. `patches/wine-unix` and
  `patches/wine-pe` are applied after it, unchanged.
- Madeira's whole-file replacements of Wine sources (the `*_ios.c` files in
  `build/ntdll-unix`, `build/win32u-unix` and `build/wineserver`, about 92k
  lines forked from wine-11.4) live in Madeira's own tree, so their port to
  the new base is the last patches of `patches/madeira-unix`, class
  `madeira-port`.
- The `wine-port` row records the Madeira commit the series was rebased from.
  The build refuses to run when Madeira's `wine` gitlink differs, and
  `pp sync` holds on such a move (`wine-port-moved`), so a Madeira Wine
  update is re-ported deliberately.

The base is the latest development release, not `master`: WineHQ tags one
every two weeks, wine-11.18 was a week old and 218 commits behind `master`.

## Why

Playport follows the latest DXMT, FEX and Wine with Madeira's and its own
patches ([0007](0007-dxmt-on-upstream.md)). DXMT and FEX went first; Wine
waited because most of its port is whole-file replacements git cannot merge.

## What it costs

Measured on the first rebase ([record](../evidence/2026-09-26-wine-latest-rebase.md)):

- 7 of the fork's 56 commits needed a three-way resolution. The
  replacements needed far more: upstream moved per-thread state from the TEB
  into `struct thread_data`, the main image into `main_module`, image mapping
  onto `pe_mapping_info`, and the arm64 server context into split register
  blocks, so each replacement was ported by reading it against upstream's
  rework, not by resolving conflict markers.
- Madeira's build scripts hide stale calls
  (`-Wno-implicit-function-declaration`, `-Wno-int-conversion`), and
  hand-mirrored unix-call tables compile against a changed enum. Each port is
  checked with those warnings on and by the undefined-symbol set of the
  archives against the previous build.
- Every later Wine release and every Madeira Wine or replacement change is
  a hand-driven re-port followed by the full device gate; `pp sync` never
  moves `wine` or the port series.
