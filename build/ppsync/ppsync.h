/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * ppsync: Playport's in-process NT synchronisation (build/ppsync/README.md).
 *
 * The ntsync driver's interface (linux/ntsync.h in this directory) plus what a
 * one-process runtime needs that the kernel driver gets from signals:
 *
 *   ppsync_kick( tid )    the server queued a system APC for thread `tid', or
 *                         is ending it: its in-process wait (now, or its next
 *                         one) returns -1 / ECANCELED without consuming
 *                         anything, so ntdll can make the server call that runs
 *                         the APC (or ends the thread), then wait again.
 *   ppsync_freeze( tid, on )
 *                         the thread's logical suspend count left or reached
 *                         zero. A frozen waiter is never satisfied, as a
 *                         suspended thread's server wait is never woken; a
 *                         frozen thread leaving a wait blocks until thawed.
 *   ppsync_thread_gone( tid )
 *                         the thread is dead to the server: thaw and kick it.
 *                         The kick stays on the id's record, so a new thread
 *                         that reuses the id may see one spurious ECANCELED
 *                         (one extra zero-timeout server wait).
 *
 * `tid' is the Windows thread id, the `owner' of ntsync_wait_args. */
#ifndef PPSYNC_H
#define PPSYNC_H

#define PPSYNC_FD_BASE    0x70000000
#define PPSYNC_DEVICE_FD  0x6fffffff
#define PPSYNC_IS_FD(fd)  (((unsigned int)(fd) & 0xf0000000u) == (unsigned int)PPSYNC_FD_BASE)

/* 1 unless madeira.cfg says inproc-sync = 0 or the environment says
 * PLAYPORT_PPSYNC=0; read once, logged once. */
extern int  ppsync_enabled(void);
extern int  ppsync_ioctl( int fd, unsigned long req, void *arg );
extern int  ppsync_close( int fd );

/* The server -> client hand-off that replaces SCM_RIGHTS for pseudo fds: the
 * server posts the descriptor it answers a request with (taking a reference),
 * the client takes it (receiving that reference). Both key it by the
 * requesting Wine thread's id and the handle: a TEB's process id can differ
 * from the server's view of the thread. A post nobody takes is replaced by
 * the next for the same key, or dropped when the table is full. */
extern void ppsync_post( unsigned int tid, unsigned int handle, int fd );
extern int  ppsync_take( unsigned int tid, unsigned int handle );

extern void ppsync_kick( unsigned int tid );
extern void ppsync_freeze( unsigned int tid, int frozen );
extern void ppsync_thread_gone( unsigned int tid );

/* Counters for tests and the periodic [ppsync] line. */
struct ppsync_stats
{
    unsigned long long waits, polls, blocked, wakes, timeouts, cancels, frozen_waits;
    unsigned long long objects, live_objects, contended, spin_hits;
};
extern void ppsync_get_stats( struct ppsync_stats *out );

#endif
