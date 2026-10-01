# 0028: One checkout: agents work on branches here, with no per-agent copies

**Status:** accepted, 2026-09-29. Changes [0016](0016-agents-share-the-phone.md):
its per-agent checkouts and build areas (`pp worktree`) are gone. The rest
of 0016 stands: one device lock, sessions, drivers that refuse another
checkout's IPA, driven settings undone after their session.

## Decision

- **Work happens in this checkout**, on a branch, one build at a time. `pp`
  has no command that makes another checkout, and the build does not look
  for one.
- **The build area is the anchor.** `$PLAYPORT_BUILD` (`.work`) holds this
  machine's `inputs.local`, the toolchains and caches, and the phone's lock
  and install record (`$PLAYPORT_DEVICE_DIR` defaults to it). There is no
  other checkout's `.work` to fall back to.
- **Build records**: only the checkout's own `.work/run` keeps
  `app/artifacts.tsv` and `build/generated`; a run elsewhere (`PLAYPORT_RUN`,
  a `pp sync` candidate) puts them back and leaves its own beside the IPA.
- **`pp sync` uses throwaway clones.** Its candidate is a `git clone --shared`
  of this repository on `sync/<sha8>`, built with this build area; the branch
  is fetched back into this repository and the clone is deleted when the run
  ends. Its patch replays are sparse `git clone --shared` checkouts of the
  upstream mirrors.

## Why

Every checkout beside this one cost a first build of 10 to 15 minutes and
about 12 GB, with the disk at 98 %. It left build records that only a build
here could commit, and a merge that needed a second build. Twelve had piled up,
none with uncommitted work: their branches were the useful part, and branches
need no checkout. Removing them freed about 80 GB.

## What it costs

- Two agents cannot build at once on this machine; the second waits for the
  build lock or works without building.
- A branch under test replaces what is checked out here: switch with a clean
  tree.
