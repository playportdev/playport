# 0035: The dev build carries no test title

**Status:** accepted, 2026-09-30. Supersedes
[0026](0026-a-dev-test-title-for-the-jit-pool.md); [0012](0012-the-ui-is-the-only-entry-point.md)
holds with no exception.

## Decision

- **PoolStress is gone.** `pool-stress.exe` (`app/DevTitles/PoolStress`), the
  `stage` step that built it (`build/stages/dev-titles.sh`), the dev app's copy
  into `C:\Games` (`Sources/S1Probe/Dev/DevTitles.swift`), its line in
  `app/xtool.yml` and `pp verify`'s `dev-titles` checks are removed. A dev
  build's library shows only what is in `C:\Games`, as a release build's does.
- **A phone that has it keeps the folder** until it is uninstalled from its
  game page, which now removes it for good.

## Why

It answered its question. Its runs found the child-process fault fixed by
madeira-unix 0039 and measured how many children the JIT pool holds
([launcher-stress](../evidence/2026-09-28-launcher-stress.md)). Kept, it
sat in the dev library as a game: on Home's Recent row, in the Library's
Installed chip and its count, beside the titles a player has.

## What it costs

- A child-process stress run needs a title that starts children, installed
  from Steam, or the program back from git history under a new record.
- The launcher-stress evidence and the documents that cite it name a program
  the tree no longer holds; its source is in the history before this record.
