# 0026: The dev build carries one test title, a launcher that stresses the JIT pool

**Status:** accepted, 2026-09-28; superseded by [0035](0035-no-dev-test-title.md), which removes the title. An exception to
[0012](0012-the-ui-is-the-only-entry-point.md), which retired the dev build's
test programs; the rest of 0012 stands. It follows the answer "Yes" to the
question of whether a test program may be used for the pool stress test in item 2 of the
[runtime-risks plan](../plans/2026-09-27-runtime-risks.md) (a launcher that
starts child processes). That test had been deferred because no installed title starts a child,
and 0012 was read as forbidding a staged test program. The runs are in the
[evidence record](../evidence/2026-09-28-launcher-stress.md).

## Decision

- **One test program, in the dev build only.** `pool-stress.exe`
  (`app/DevTitles/PoolStress/pool-stress.c`) is an x86-64 Windows program
  that starts N child processes, one at a time. Each child and the parent run
  guest code: some of the executable's own, and guest JIT code generated at
  run time (64 KiB regions of `PAGE_EXECUTE_READWRITE` holding 512 small
  functions, each called). In `alive` mode
  the children stay until all have started; in `serial` mode each exits before
  the next starts. It paces itself so that each child gets its own `pool:` line.
  It is freestanding (kernel32 only, no C runtime).
- **Built with the trees, shipped only in dev.** `build/stages/dev-titles.sh`
  (the `stage` stage) builds it into `app/Staged/DevTitles/`. The dev
  variant's `xtool.yml` ships that as `DevTitles/` at the app root, and the
  release variant's copy of the file leaves it out. `pp verify` checks both
  sides: a dev IPA carries exactly that program, an x86-64 PE that imports only
  KERNEL32; a release IPA has no `DevTitles/`, no `DevTitles` type and no
  `DevTitles` string in its executable.
- **Reached only through the UI.** Before each library scan, the dev app
  itself copies the bundled folder into the prefix's `C:\Games\PoolStress`
  (`Sources/S1Probe/Dev/DevTitles.swift`, compiled out of release), where
  adoption finds it like any other folder: *PoolStress*, `dir-poolstress`.
  It is played with the Play button. Its mode and N are the game's launch
  arguments, set on its page or by `pp ui --settings
  'dir-poolstress:{"arguments":"alive 40"}'`. No launch mode, environment
  switch or workstation push reaches it.

## Why

**The question could not be answered any other way.** Decision
[0019](0019-jit-pool-sized-from-the-limit.md) kept a private ntdll copy per
pseudo-process from code reading alone: no cohort title starts a child
(Hollow Knight's crash handler is refused by the spawn gate; The Witcher 3 and
En Garde! start none). A title that does is a launcher, which the cohort does
not hold, and installing one from Steam to test a runtime limit adds a
download, a Steam session and a game's own behaviour to the measurement. A
program that does only this measures only this, and N is set per run.

**This keeps 0012's reason.** 0012 retired side entrances because they test a
route no player takes. This program is played through the path a player
takes, and it tests the runtime under it, not a side route. What 0012 forbids,
a tool that pushes files into the container, is not used: the app copies its
own bundled file, as it seeds the prefix registry from its bundle.

**It found what code reading could not.** Its first play showed that no child
process had started since the port onto wine-11.18: the child faulted before
its first instruction (fixed by madeira-unix 0039). It also showed that a
child's head is mostly its own copies of the parent's system DLLs, and that a
dead child's images are never reused.

**Dev only, as the driver is.** A player has no use for it, and the release
build's check that it carries no dev code now covers it.

## What it costs

- A dev build's library shows a *PoolStress* entry, badged *Untested* like any
  unknown folder. Uninstalling it removes the folder until the next scan copies
  it back. A release build installed over a dev build leaves the folder in
  `C:\Games` (the container is kept), where the release library shows it as an
  unknown program that can be played. Uninstalling it there removes it for good.
- One more piece of dev-only code and one more build step, about a second.
- The program is Playport's own test code (GPL-3.0-or-later), not upstream
  code, so no patch series carries it.
