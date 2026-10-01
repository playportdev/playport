# 0027: Titles run as children of one session root, so one app run plays several games

**Status:** accepted, 2026-09-29. Replaces the one-game-per-process rule
([ARCHITECTURE.md](../ARCHITECTURE.md#product-ui), the `spent` guard) that
the [session-root record](../evidence/2026-09-28-multigame-session-root.md)
kept because child pseudo-processes did not work. Changes how
[0022](0022-stop-a-game-that-ran-the-pool-out.md) stops a game; its rule
stands. The runs are in the
[evidence record](../evidence/2026-09-29-several-games.md).

## Decision

- **One session root per app process.** The first Play acquires the JIT pool,
  starts the wineserver and runs `playport-session.exe` as the process's one
  `__wine_main` (`wine_host_session_start`). It is Playport's own program
  (`app/SessionRoot`, built by `build/stages/session-root.sh`, staged in
  `Runtime/arm64ec-windows` in both variants): x86-64 like every title,
  kernel32 and user32 only, no C runtime.
- **Every title is its child.** Each Play, the first included, asks the root
  to start the title (`wine_host_session_launch`) with its arguments, working
  directory and the launch's variables (Steam's game id, FEX's, the backend's)
  over the root's own environment. The root puts the title in a job and
  reports its exit once the job is empty: the title and everything it
  started. A game that ran the pool out is stopped by ending that job
  (`wine_host_session_stop`).
- **The root brings up user32 before any title**, as explorer does at a Wine
  session's start: the desktop window and win32u's shared GDI handle table are
  the root's, and every title's PEB, cloned from the root's, carries the table.
- **The host talks to the root through files** in
  `C:\users\playport\AppData\Local\Playport\session` (`session_protocol.h`):
  a request and a stop, written whole and renamed into place, and the root's
  reply. Both run in the app's one Mach process; the host writes a request
  only for a Play from the UI, so this is not an entry point (0012).
- **A later Play is refused when the pool is too full**: with less than
  192 MiB of room between head and tail, or less than 256 MiB counting the
  tail the ended titles gave back (`JitPool.hasRoomForNextTitle`). The
  result screen then offers to close Playport, as it does when the session
  itself failed (it cannot be started twice in a process), when the root
  stopped answering, or when a stopped game goes on running. A title is
  judged by the refusals it ran into itself (`JitPool.Use.since`).
- **The runtime fix it needed**: each pseudo-process's emulator gets its own
  JIT aliases (`patches/madeira-unix` 0044). Before it, a child's x86-64 code
  calling ntdll ran the session's ntdll copy, and an MSVC `__except` in a child
  (Hollow Knight's Mono naming a thread) resumed with its registers lost.

## Why

**The runtime can start once per process, and a child can now run a game.**
A second `wine_host_init` or `__wine_main` aborts the app; a child
pseudo-process is the only way to start a second program in one session.
0039 to 0043 made a child start, draw and be waited for; 0044 made Hollow
Knight run as one. The JIT is not the limit: the one blessed pool serves
every child.

**The root, not the first title, owns what the session shares.** win32u
initialises once, in the first process that calls it, and writes the GDI
table into that process's PEB alone. With the first title as that process,
the second title's gdi32 read a NULL table and faulted at once (Hollow Knight
then Hollow Knight). A root that lives for the session holds them for every
title, and nothing it holds goes away when a title ends.

**A job, because a title's own children are part of it.** A launcher or a
crash handler outlives the process the root started; the next title must not
start beside it, and a stop must end it too.

**A refusal before the pool is too full, not after.** An ended title's
images are not reused (most of its head lost its execute permission during
its life, [launcher stress](../evidence/2026-09-28-launcher-stress.md)), so
each Hollow Knight costs about 160 MiB of head for the rest of the session;
its code buffers are reused. The thresholds let a title of Hollow Knight's
size start with its head and a code buffer FEX can work with; a larger title
that runs out still ends as *ran out of JIT memory*.

## What it costs

- The root's user32, gdi32 and their DLLs in the pool, once per session.
- About three Hollow Knight sessions fit in an 896 MiB pool before a Play is
  refused; then the app is relaunched as before.
- One more Playport program in the IPA (14 KB) and one build step.
