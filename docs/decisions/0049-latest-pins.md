# 0049: Every dependency at the head of its development branch

**Status:** accepted, 2026-10-05; its `madeira` row is replaced by
[0054](0054-madeira-frozen.md): the pin is frozen at `8c050d0`. Supersedes the pin-source parts of
[0008](0008-fex-on-upstream.md) (FEX from a monthly release),
[0013](0013-wine-on-upstream.md) (Wine from a development release, never
`master`) and [0018](0018-valve-wine-as-a-series.md) (`wine-valve` picked
from `proton_11.0`); the rest of those records stands: each component is still
built from its own upstream with Madeira's port and Playport's changes as
patch series. The owner's direction of 2026-10-05, as written in the
[Proton ARM64 alignment plan](../plans/2026-10-05-proton-arm64-alignment.md#goal).

## Decision

- **Latest possible, not latest release.** Each `pins.lock` row moves to the
  head of its upstream's development branch:
  - `fex` (and with it `rpmalloc`, its `External/rpmalloc` gitlink): FEX-Emu
    `main`, which is what Proton bleeding-edge ships, not a monthly tag.
  - `wine`: the newest WineHQ development tag. WineHQ `master` moves daily
    and Madeira's ports are rebased per tag; `master` is taken only when a tag
    lacks something Valve's bleeding-edge Wine depends on, and the reason is
    recorded with that move.
  - `wine-valve`: picks from Valve Wine's bleeding-edge branch, sorted by
    0018's rules, not from `proton_11.0`.
  - `dxmt`, `mesa`, `dxvk`, `vkd3d-proton`: their `main`/`master` heads.
  - `madeira`: last, by `pp sync`, after the Madeira reconciliation of the
    [dependency strategy](../plans/2026-10-05-dependency-strategy.md).
- **Small and frequent moves.** Wine moves at every WineHQ tag (every two
  weeks), FEX every one to two weeks, the others when their heads move.
  One dependency per commit (`rpmalloc` goes with `fex`), each with its
  re-ported series, build records, an evidence record and the device gate on
  both cohort titles (Hollow Knight and Portal 2) with before/after `pp perf`.
  A move that fails the gate or regresses a title beyond run-to-run noise is
  held, and the hold is recorded.
- **How a series moves.** `pp rebase` (rerere per component, a conflict
  trial, `git range-diff` review of every auto-merged or replayed hunk, a
  re-export of the series), as
  [UPSTREAM-SYNC.md](../UPSTREAM-SYNC.md#moving-a-component-pin) describes.
- **Valve is the reference, not the base.** Proton bleeding-edge is the Valve
  branch each move is compared with; Valve's tree is never a pin's base.
- **Nothing is offered upstream.** Every patch stays carried
  (`Offered-upstream: no`).

## Why

A release pin is up to a month (FEX) or two weeks (Wine) behind, and each
release step then carries that whole distance at once. Moving at the heads in
small steps keeps each rebase small, keeps Playport on the code Valve's ARM64
Proton runs (bleeding-edge tracks FEX `main`, DXVK and vkd3d-proton `master`),
and brings fixes such as FEX's WoW64 CHPEv2 suspend work without waiting for a
tag. The rebase helper makes a small move cheap: its rerere cache replays
earlier resolutions, and its trial counts the conflicts before anything is
committed.

## What it costs

- A head has had less testing than a release. The gate on both titles and
  `pp perf` before and after each move are the guard; a regression holds the
  move rather than being forced through.
- More moves mean more device gates and more rebase work in total, though
  each is smaller.
- `master`-only fixes in WineHQ wait for the next tag unless a recorded reason
  takes `master`.
