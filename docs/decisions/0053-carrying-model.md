# 0053: Patch series stay the canonical form of every change to upstream code

**Status:** accepted, 2026-10-05, by the owner. Madeira no longer moves with
`pp sync`: [0054](0054-madeira-frozen.md) froze it; `pp sync` is a watch report. The "carrying model" record of
the [dependency strategy](../plans/2026-10-05-dependency-strategy.md#decision-records-needed).
Keeps [0001](0001-superproject-on-madeira.md); restates the rebase and
upstreaming parts of [0049](0049-latest-pins.md).

## Decision

- **Series, not fork repositories.** Every change to an upstream tree stays a
  `git format-patch` series under `patches/<target>/` on a pinned commit, as
  0001 set out. Playport hosts no fork branches of its dependencies.
- **Moves use the rebase helper.** A component series moves with `pp rebase`
  (rerere per component, a conflict trial, a `range-diff` review, a
  re-export); Madeira moves with `pp sync`
  ([UPSTREAM-SYNC.md](../UPSTREAM-SYNC.md)).
- **Nothing is offered upstream.** Every patch is carried for good
  (`Offered-upstream: no`). A patch leaves a series only when its upstream
  makes the same change itself.
- **0001 holds, with one reason obsolete.** Its privacy reason no longer
  applies: Playport is public ([0043](0043-published-as-the-playport-authors.md)).
  Its other reasons still hold. A Madeira fork would carry the proprietary
  `libmetalirconverter.dylib`. One mechanism (pin plus series) serves every
  tree.

## Why

The dependency strategy measured the alternatives. Fork branches would rebase
the same conflicts, because the conflicts come from upstream and not from how
the patches are stored. They would also need public repositories with a tag
per pinned commit (0042), and a rewrite of the build's fetch, `pp sync`, the
trailer checks and the source bundle. The run trees in the build area already
are local branches of each series, and `pp rebase` adds the rerere and
`range-diff` a fork would give.

## Cost

Patches are reviewed as diffs of diffs. Each series' `index` lines must match
the blobs that applying the series in order produces. Otherwise a 3-way
fallback has no preimage, so a patch file is re-exported, never edited by hand.
