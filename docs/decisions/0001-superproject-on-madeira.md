# 0001: Superproject on Madeira, not a fork

**Status:** accepted, 2026-09-24. Since [0054](0054-madeira-frozen.md) the pin
is frozen at `8c050d0` and Playport owns that layer; the submodule and the
series stay, and an update is a hand port, not a replay.

## Decision

Playport is a superproject based on
[willfaust/Madeira](https://github.com/willfaust/Madeira). It pins one
Madeira commit as the git submodule `upstream/madeira` (with Madeira's own
submodules FEX, wine and `research/dxmt`), records that pin and the derived
component commits in `pins.lock`, and carries every change to the upstream
trees as `git format-patch` series under `patches/<target>/series`. Nothing is
committed into a copy of Madeira's history.

## Why

- **Privacy.** A GitHub fork of a public repository cannot be made private.
  Playport is private.
- **What a fork would carry.** A fork with Madeira's history would contain
  Madeira's 30 MB proprietary `libmetalirconverter.dylib` and its title
  scaffolding, neither of which Playport may redistribute or wants in its
  history. A pin references them without copying them.
- **One mechanism.** Madeira's host layer, its Winios driver and the wine,
  FEX and DXMT forks are all handled the same way: check out the pin, apply
  the series with `git am -3`, build. Each patch carries its class and
  evidence as trailers, which is what lets an update tool replay and classify
  the series automatically
  ([UPSTREAM-SYNC.md](../UPSTREAM-SYNC.md)).

## Consequences

- Every Madeira update is a replay of the series. A conflict is Playport's to
  re-port; a patch that upstream absorbs is deleted.
- Madeira's gitlinks, not the forks' branch heads, decide which FEX, wine and
  DXMT commits are built. A fork branch moving ahead of Madeira changes
  nothing until Madeira moves its gitlink.
- The build must check out and patch trees itself; `build/build-from-pins`
  does this from clean on every run.
