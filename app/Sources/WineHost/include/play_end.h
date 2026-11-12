/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * play_end.h — the running Play's end mark, for the memory-kill note
 * (PlayClock.swift; PlayportKit MemoryKill.swift, PlaySessionStore; PLA-847).
 *
 * iOS ends a process past its memory limit with SIGKILL, and nothing runs. So
 * every other end of a Play's process that runs code first leaves one line in
 * the mark file beside the Play's session, and the next start does not take
 * that Play for a memory end however near the limit it was:
 * - a fatal signal the runtime leaves to the default (SIGTERM, SIGHUP):
 *   "signal N", and the signal then ends the process as before;
 * - exit(): "exit";
 * - a host fault ntdll declines, which the restored default then makes fatal
 *   (madeira-unix 0295; wine_host.c passes play_end_signal): "signal N";
 * - the app's own calls: going to the background ("background", removed when
 *   it comes back) and iOS terminating it ("terminated").
 *
 * A mark only opens, writes and closes the path copied when the Play was
 * armed, so it runs in a signal handler. Plain C with no Apple headers, so the
 * host C tests (`pp test`, app/tests) build it on the Linux host.
 */
#ifndef PLAY_END_H
#define PLAY_END_H

/* From now until play_end_disarm, a mark goes to path (a Play's start); a path
 * of 1024 bytes or more marks nothing. The first call installs the handlers:
 * SIGTERM's and SIGHUP's where the disposition is the default, and an atexit. */
void play_end_arm(const char *path);

/* No mark from now on: the Play ended in this process. */
void play_end_disarm(void);

/* The process may end, or is ending, other than by its memory: why, one line. */
void play_end_mark(const char *why);

/* The mark of a fatal signal, "signal N". */
void play_end_signal(int sig);

/* No mark after all: the app came back to the foreground. */
void play_end_unmark(void);

#endif
