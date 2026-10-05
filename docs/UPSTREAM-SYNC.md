# Updating from Madeira

`pp sync <madeira-sha>` moves Playport's pins to a new Madeira commit: it
replays every patch series, builds, runs the gates, and then fast-forwards
`main` or holds with a report (`$PLAYPORT_BUILD/sync/<sha8>/REPORT.md`).
Stages, options, output files and exit statuses are in `pp sync --help`; this
page is the policy.

## What moves

Only Madeira is tracked. Its own code moves with it; the components do not
([decisions 0007](decisions/0007-dxmt-on-upstream.md),
[0008](decisions/0008-fex-on-upstream.md),
[0013](decisions/0013-wine-on-upstream.md)): the `wine`, `dxmt`, `fex` and
`rpmalloc` pins are upstream commits a sync never moves, and neither is the
`wine-valve` row, the Valve commit `patches/wine-valve` was picked from
([0018](decisions/0018-valve-wine-as-a-series.md)). A sync replays
`patches/wine-valve` on `patches/wine-port`, and `patches/wine-unix` and
`patches/wine-pe` on both. When a Madeira commit
moves its `wine`, `dxmt`, `FEX` or FEX's `External/rpmalloc`, the run
holds before the build (`wine-port-moved`, `dxmt-port-moved`,
`fex-port-moved`, `rpmalloc-port-moved`): the matching `patches/*-port` series
is re-ported by hand ([Wine](evidence/2026-09-26-wine-latest-rebase.md),
[DXMT](evidence/2026-09-24-dxmt-latest-rebase.md),
[FEX](evidence/2026-09-24-fex-latest-rebase.md) records; AGENTS.md, "Pins").
A move of Madeira's Wine usually also needs its replacements re-ported, the
`madeira-port` patches at the end of `patches/madeira-unix`. A sync cannot land
such a move itself (the port rows must match the old pin's gitlinks): the
re-ported series, the moved port row and the Madeira pin land together in one
hand-made commit, built and played like any other
([example](evidence/2026-09-25-dxmt-port-ca8a251.md)).

Madeira's 79e28f0 moved its DXMT submodule from `research/dxmt` to `dxmt`:
the run and the `sources` stage read the dxmt-port gitlink at `dxmt`, or at
`research/dxmt` in an older commit. Madeira's other submodules, such as
`madeira-dock` (its Steam client host, which Playport does not build), are
named in the report and never checked out. The `mesa`, `vkd3d-proton`, `gbe`
and `idevice` series are on pins no Madeira commit moves and are not replayed.

Each run also checks Valve's branch, the `wine-valve` row's `proton_11.0`.
When it has commits the row's pin lacks, the run lists them, oldest first,
in `$PLAYPORT_BUILD/sync/wine-valve-new.tsv` (commit, date, subject, files),
and says so in the report and its last line. This is reported only: it never
holds a sync. A person reacts as [0018](decisions/0018-valve-wine-as-a-series.md)
says: sort the commits by its rules, pick the wanted ones onto
`patches/wine-valve`, add their verdicts to the evidence record's
`valve-commits.tsv`, and move the row (a Hollow Knight play gates it).
The file disappears on the first run after the row catches up. When Valve
has rewritten the branch, a commit is new if its subject is not among the
pin's. A rebase onto a newer WineHQ 11.0.x therefore also lists that base's
commits, which `classify.py` sorts as `upstream`.

## Running it

From a clean checkout of `main`: it reads `pins.lock`, `patches/` and the
gitlink from `HEAD` and refuses uncommitted changes to them. A second run for
the same commit and inputs reprints the recorded result, except a run paused
at the device gates, which resumes there (`--rerun` starts over). Nothing
starts it automatically: a person or a poller (comparing
`sync/madeira-pin.git`'s `main` with Madeira's) runs it with the new SHA.

## Merge or hold

Each patch replays as `clean`, `merged-3way`, `already-upstream` or
`conflict`. A patch is `already-upstream` only on positive evidence: its
reverse applies to the new commit, or its 3-way merge comes out empty. Any
merge that fails is a `conflict`, also one that found no preimage blob for
the patch's `index` lines and so left no conflict markers. The replay runs in
the clone where the series first applied to its own pin, so every patch's
preimage is there. (Before 2026-10-05 the replay ran in a fresh clone without
those blobs and called such a failed merge `already-upstream`: the dry run of
Madeira `bbbf8d0` listed 52 madeira-unix patches so, none of them in
Madeira. With the fix and re-exported series it lists 24 `clean`, 6
`merged-3way`, 50 `conflict` and none `already-upstream`.) The run merges
only when every patch is `clean` or `already-upstream`, every gate passes (the build's `verify`, `pp names`,
`swift test`, then on the phone `pp install` and a Hollow Knight play to 10 s
after its first frame), and no `.gitmodules` or licence file changed.
Anything else holds for a person. A build that fails with none of those
causes is `upstream-broken`: stay on the current pin and retry on the next
Madeira push. So `main` only ever points at a pin set that built from clean
and played on the phone.

A merge commits the pin move (with each `already-upstream` patch deleted), the
build records, and a generated `docs/evidence/<date>-madeira-<sha8>.md`,
secret-scanned and with the team ID and home path redacted.

What stays with a person: re-porting a conflicting or `merged-3way` patch,
judging whether an `already-upstream` `upstream-bug` patch is really
equivalent, the licence review after a branch switch, and offering patches
upstream.

## Moving a component pin

The `wine`, `fex`, `dxmt` and `rpmalloc` pins move by a rebase, played on the
phone (AGENTS.md, "Pins"). `pp rebase`
does the mechanical part in a scratch clone under `$PLAYPORT_BUILD/rebase/`:

```sh
./pp rebase fex main --fetch --trial   # per patch: clean, 3-way, upstream or conflict (each cause counted once)
./pp rebase fex main                   # replay; stops at each conflict (exit 10)
#   resolve in $PLAYPORT_BUILD/rebase/fex/tree, git add, then:
./pp rebase fex --continue
./pp rebase fex --write [--pins]       # the re-exported series into patches/ (and the pins.lock row)
```

A target takes the series under it (`fex` is `fex-port` then `fex`; Wine's
two trees are two runs, `wine-pe` and `wine-unix`, both over `wine-port` and
`wine-valve`). Every resolution is recorded with `rerere` per component and
replayed in the next run, so the second Wine run reuses the first one's. When the replay ends, `range-diff.txt` compares the old and new series,
and `flags.txt` lists each patch whose range-diff changed with no person
resolving it (a 3-way merge or a recorded resolution): check those hunks
against both sides, since git can misplace an auto-merged hunk. A clean
patch is kept as it is; the others are written again with their `Rebased:` or
`Picked:` trailer set to `resolved` when the move needed a resolution. The
run never commits: review `git diff`, then build and play as for any pin move.
A pin that is a gitlink of the moved one (FEX's `External/rpmalloc` is the
`rpmalloc` row) is named when the new commit moves it; it is a run of its own
(`pp rebase rpmalloc <commit>`). `pp rebase --help` has the files and exit
statuses.
