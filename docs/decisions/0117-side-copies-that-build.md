# 0117: Side copies that build

**Status:** accepted, 2026-10-19, by the owner ("New decision record"). Amends
[0069](0069-host-only-worktrees.md): an owner-authorized side worktree may build and test with
its own copy of the build area, not only run host checks. [0028](0028-one-checkout.md)'s main
checkout stays the phone's, and [0016](0016-agents-share-the-phone.md)'s device rules stand.
[PLA-405](https://linear.app/playportdev/issue/PLA-405) (0069: [PLA-86](https://linear.app/playportdev/issue/PLA-86)).

## Decision

- **What a side copy may run.** With the owner's authorization, a worktree under
  `.work/worktrees/<name>` on its own branch, with its own `.work` (`PLAYPORT_BUILD=$PWD/.work`,
  its own `inputs.local`), may run `pp build`, `pp check`, `pp verify`, `pp test`, `pp rebase`,
  `pp slots`, the stage scripts, host tools and desktop Wine/Proton in its own prefixes.
- **Its first build** starts from reflinks (`cp -a --reflink=always`, never a symlink or a
  shared directory) of main's `.work/cache`, `.work/inputs` and `.work/run`, and of inputs built
  apart (`.work/cef-src/out-stage-c`, `.work/notices`), read only on main's side. Before
  building, grep the copy's `run` and `cache` build files (CMake caches, ninja and make files,
  `config.status`, `.la`, `.pc`, cargo dep-info, `.done` markers) for main's `.work` paths and
  rewrite the prefix, re-point absolute symlinks and git alternates, `patchelf` RUNPATHs in
  `inputs/apple-linker`, or delete a build directory so it rebuilds. The first build still
  reruns every stage (each tree's toolchain digest names the copy's path), about 20 minutes on
  the copied trees and caches; without the copies every tree builds cold.
- **Main stays untouched, and that is shown.** `touch` a marker before the copy and its builds;
  afterwards `find <main>/.work -path '*/worktrees' -prune -o -newer <marker> -print` lists
  nothing the copy wrote (entries from other sessions are named as such; none names the copy).
- **Build records** (`app/artifacts.tsv`, `build/generated/wine-pe-*.tsv`) hash the build path.
  A copy commits only the rows its change causes and a reproduction shows path-independent;
  rows from the copy's path or from trees it rebuilt clean (`lib/libdxmt_combined.a`,
  `lib/libidevice_ffi.a`, a rebuilt GnuTLS) keep main's values. The main checkout's build after
  the move regenerates or confirms them.
- **Main only:** the phone and everything that reaches it or its record (`pp install`, `pp ui`,
  `pp perf`, `pp phone`), `pp release` and `pp sync`. A branch moves into the main checkout,
  rebased onto `main`, for its phone gates.
- **Limits.** At most one writer per worktree. Keep heavy builds few: two at once (main and a
  copy, or two copies) worked on this machine.

## Why

From 2026-10-17 to 10-19 two side copies built and tested this way (the Proton alignment queue
W7 to M2a, the RDR2 Vulkan chunks H1 to H8) while the main checkout played on the phone: a
first build took 19.5 minutes with no stage failing, main's `.work` had no entry newer than the
marker from the copies ([H4](../evidence/2026-10-17-rdr2-vulkan-needs.md)), and M2b's build in
the main checkout reproduced byte for byte the records M2a committed from a copy
([evidence](../evidence/2026-10-18-proton-alignment-phone.md)). 0069's host-only rule had left
such work waiting for the main session.

## Costs

Each copy holds its own build area (reflinks share blocks until a build rewrites them). The
path rewrite must be redone for each new copy and is easy to miss in one file; the marker check
catches a write to main, not a copy that silently reads main's tree. Records committed from a
copy are provisional until the main checkout's build confirms them, and phone gates still wait
for the main checkout.
