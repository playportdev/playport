# 0069: Owner-authorized worktrees for isolated host-only work

**Status:** accepted, 2026-10-08. Narrowly amends
[0028](0028-one-checkout.md)'s prohibition on per-agent checkouts; its main-checkout
build policy and [0016](0016-agents-share-the-phone.md)'s device safety rules stand.
**Linear:** https://linear.app/playportdev/issue/PLA-86 (under PLA-84). Amended by
[0117](0117-side-copies-that-build.md): a side copy may build and test with its own reflinked
build area.

## Decision

- With explicit owner authorization, a side worktree under `.work/worktrees/` may
  edit documentation/code and run isolated host checks while the main checkout is
  occupied. This is not a second build or device environment.
- Do not change the main checkout's source, index, branch or runtime state. No
  builds (including `pp check`), installs, phone commands, browser or games from the
  side worktree. Do not copy, symlink or share main's `.work`, mutable caches or
  submodules; keep scratch and test outputs in the worktree's own `.work`. A check
  requiring those shared inputs must wait for the main session.
- Commit each coherent host-checked chunk on its worktree branch and report any
  outstanding build/device gates. Integration, builds and required phone checks
  wait for the main checkout to be available; host checks do not replace them.
- Build contention is fail-fast, not a wait: `build/pipeline` uses `flock -n` on
  the run-directory lock and exits if another build holds it. This corrects 0028's
  historical cost description without changing the lock implementation.

## Why

Owner-authorized host-only feedback fixes on October 6 and this documentation
audit can proceed without interrupting the main session. Sharing mutable build
caches defeated that isolation in the feedback session; the exception therefore
permits only local host work, not reuse of the main build environment.

## Costs

Worktree-local checks may lack inputs and must be reported as unrun rather than
borrowing main's state. Runtime/UI fixes remain unverified on the phone until
integration and the relevant device gate. The usual one-checkout build path stays
the default; this does not restore `pp worktree` or automatic per-agent copies.
