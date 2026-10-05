# 0050: `pp release` reuses the release build of HEAD

**Status:** accepted, 2026-10-05, by the owner. Changes
[0038](0038-unsigned-release-ipas.md) in one point: a release no longer always
builds `--clean`. The rest of 0038 stands.

## Decision

- `pp release VERSION` takes the newest unsigned release output of HEAD when
  one exists and was built without local changes, and builds nothing.
- When there is none, it runs `pp build --variant release --unsigned`, which
  builds only the stages whose inputs changed, as any other build.
- `pp release VERSION --clean` builds every tree afresh from its pin, as every
  release did before. `--no-build` still never builds.
- Every check after the build is unchanged: a clean, pushed HEAD, the exact
  provenance of HEAD, the build checksums, `pp names`, `pp secrets`,
  `pp verify --unsigned` and, for a GitHub draft, `--distribution`.

## Why

A release follows a build of the same commit: the build records it rewrites
must be committed before the release, and the check of that build is the one
anybody reads. The `--clean` build then took another 15 to 25 minutes to make
the same trees again (the 0.3.1 pairing fix waited on it). Every tree stage is
stamped with a digest of its inputs (pins, series, build scripts, toolchains),
so an incremental build of a commit builds what that commit names.

## What it costs

- A tree that is wrong for a reason its digest does not cover (a toolchain
  changed outside its version, a hand edit under `.work/run`) goes into a
  release unless the release uses `--clean`. Use it after toolchain or build-area
  surgery, and for a release whose trees are suspect.
- The source bundle still comes from the pins and series, not the run tree, so
  what a recipient rebuilds is the same either way.
