# Watching Madeira, moving the component pins

The `madeira` pin is frozen at `8c050d0`, and Playport owns that layer
([decision 0054](decisions/0054-madeira-frozen.md)). Madeira is watched, not
followed: `pp sync` reports what Madeira did since the pin, a person picks the
fixes Playport wants, and each is ported by hand as a Playport patch. The
other pins (`wine`, `fex`, `dxmt`, `rpmalloc`, `wine-valve`, …) keep moving
on their own upstreams ([below](#moving-a-component-pin)). Options, output
files and exit statuses are in `pp sync --help`; this page is the policy.

## Watching Madeira

```sh
./pp sync                 # Madeira's branch head against the frozen pins
./pp sync <sha> --replay  # up to <sha>, with every series replayed there
```

It never moves a pin, commits or checks anything out in the repository. It
needs `pins.lock` and `patches/` committed, and writes `WATCH.md` and
`watch.tsv` (row, commit, date, subject, the files Playport patches, every
file) to `$PLAYPORT_BUILD/sync/watch-<sha8>/`. It lists, oldest first:

- **Madeira's own commits** past the pin that touch a path the build
  compiles or stages (`MADEIRA_BUILT` in `tools/sync.py`: `build/ntdll-unix`,
  `build/wineserver`, `build/win32u-unix`, `build/madsync`,
  `build/madeira_cfg.h`, the GnuTLS and FreeType builds, Winios) or a file
  `patches/madeira-unix` or `patches/madeira-winios` patches. The rest are
  counted, not listed.
- **The forks' commits** past the frozen `wine-port`, `fex-port`, `dxmt-port`
  and `rpmalloc-port` rows, up to the gitlinks of the watched commit. Every
  file of a fork is built, so each of these is listed.
- `*` marks a commit that touches a file one of Playport's series patches:
  a port of it will meet Playport's own change.
- Notes: a moved gitlink, a `.gitmodules` or licence change, a submodule the
  build does not use (`madeira-dock`), a fork branch past Madeira's gitlink.

`--replay` adds a "would it apply" table: every series replayed at the
watched commit, each patch `clean`, `merged-3way`, `already-upstream` or
`conflict`. A patch is `already-upstream` only on positive evidence: its
reverse applies, or its 3-way merge comes out empty. Any failed merge is a
`conflict`, also one with no preimage blob for its `index` lines. The replay
runs in the clone where the series first applied to its own pin, so every
patch's preimage is there.

Each run also checks Valve's branch, the `wine-valve` row's bleeding-edge.
When it has commits the row's pin lacks, the run lists them, oldest first, in
`$PLAYPORT_BUILD/sync/wine-valve-new.tsv` (commit, date, subject, files).
A person reacts as [0018](decisions/0018-valve-wine-as-a-series.md) says:
sort the commits by its rules, pick the wanted ones onto `patches/wine-valve`,
and move the row (a Hollow Knight play gates it). When Valve has rewritten the
branch, a commit is new if its subject is not among the pin's.

## Porting a Madeira fix

A wanted commit becomes a Playport patch on the frozen base, re-exported,
never hand-edited ([0053](decisions/0053-carrying-model.md)):

- In Madeira's own tree (`build/*-unix`, the `*_ios.c` replacements):
  `patches/madeira-unix`; Winios: `patches/madeira-winios`.
- In Madeira's Wine fork: `patches/wine-unix` for the unix side and the
  server, `patches/wine-pe` for the PE side. Check which files the frozen
  `*_ios.c` replacements stand in for: those changes land in `madeira-unix`.
- In its FEX, DXMT or rpmalloc forks: `patches/fex`, `patches/dxmt`,
  `patches/rpmalloc`.
- The message names the Madeira commit (a `Madeira-commit:` line) and carries
  `Class:`, `Evidence:` and `Offered-upstream:`. Keep the original author.
- Branch `madeira-main` holds Madeira `bbbf8d0` re-ported onto Playport's
  bases (2026-10-06); its patches are often the shortest route. Fastsync came
  that way: `patches/wine-unix` 0015–0017 and `patches/madeira-unix` 0081
  ([evidence](evidence/2026-10-06-fastsync-on-8c050d0.md)).
- Build, `pp test`, and the device gate on both cohort titles, as for any
  patch.

## Moving the Madeira pin

Only after a new decision record supersedes 0054. `pp sync <sha>
--move-pin-0054` then runs the move: it replays every series at the new
commit, builds a candidate in a throwaway clone, runs `verify`, `pp names`,
`swift test`, `pp install` and a Hollow Knight play, and fast-forwards `main`
only when every patch is `clean` or `already-upstream`, every gate passes and
no `.gitmodules` or licence file changed; otherwise it holds with
`$PLAYPORT_BUILD/sync/<sha8>/REPORT.md` (`--dry-run` stops after the replay).
A move of Madeira's Wine, DXMT, FEX or rpmalloc gitlink holds before the
build (`*-port-moved`): the port series is re-ported by hand and lands with
the pin in one commit, as on `madeira-main`.

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
