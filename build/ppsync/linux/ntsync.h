/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * ppsync's stand-in for Linux's <linux/ntsync.h> (build/ppsync/README.md).
 *
 * Wine's in-process synchronisation (server/inproc_sync.c, ntdll/unix/sync.c)
 * is written against the ntsync character device: the server creates the
 * objects, hands clients a descriptor, and every wait / release / set after
 * that is one ioctl with no server round trip. iOS has no such driver, but the
 * wineserver is a thread of the same process, so the "driver" is a library
 * both sides call (ppsync.c). The structures and the semantics below are the
 * driver's (Documentation/userspace-api/ntsync.rst); only the request codes
 * and the descriptors are this library's own.
 *
 * Descriptors are pseudo fds (PPSYNC_FD_BASE | index), never kernel fds, so
 * thousands of events cost no descriptors and an object's identity survives
 * being handed from the server to a client. ioctl() and close() are redirected
 * for the files that include this header; a call that is not ours falls
 * through to libc. */
#ifndef PPSYNC_LINUX_NTSYNC_H
#define PPSYNC_LINUX_NTSYNC_H

#include <stdint.h>
#include <sys/ioctl.h>   /* before the macros below, so libc's prototypes stay intact */
#include <unistd.h>

#ifdef __linux__
# include <linux/types.h>   /* the host test build: the kernel's own __u32 / __u64 */
#else
typedef uint32_t __u32;
typedef uint64_t __u64;
#endif

struct ntsync_sem_args   { __u32 count; __u32 max; };
struct ntsync_mutex_args { __u32 owner; __u32 count; };
struct ntsync_event_args { __u32 manual; __u32 signaled; };

#define NTSYNC_WAIT_REALTIME 0x1
struct ntsync_wait_args
{
    __u64 timeout;   /* absolute ns, CLOCK_MONOTONIC unless REALTIME; ~0 = forever */
    __u64 objs;      /* pointer to an array of int descriptors */
    __u32 count;
    __u32 index;     /* out: which object; == count means the alert fired */
    __u32 flags;
    __u32 owner;     /* the waiting thread's Windows thread id */
    __u32 alert;     /* 0 = none */
    __u32 pad;
};
#define NTSYNC_MAX_WAIT_COUNT 64

/* Request codes are private to this library; only uniqueness matters. */
#define PPSYNC_IOC(n)             (0x50500000ul | (n))
#define PPSYNC_IOC_MASK           0xffff0000ul
#define NTSYNC_IOC_CREATE_SEM     PPSYNC_IOC(0x80)
#define NTSYNC_IOC_SEM_RELEASE    PPSYNC_IOC(0x81)
#define NTSYNC_IOC_WAIT_ANY       PPSYNC_IOC(0x82)
#define NTSYNC_IOC_WAIT_ALL       PPSYNC_IOC(0x83)
#define NTSYNC_IOC_CREATE_MUTEX   PPSYNC_IOC(0x84)
#define NTSYNC_IOC_MUTEX_UNLOCK   PPSYNC_IOC(0x85)
#define NTSYNC_IOC_MUTEX_KILL     PPSYNC_IOC(0x86)
#define NTSYNC_IOC_CREATE_EVENT   PPSYNC_IOC(0x87)
#define NTSYNC_IOC_EVENT_SET      PPSYNC_IOC(0x88)
#define NTSYNC_IOC_EVENT_RESET    PPSYNC_IOC(0x89)
#define NTSYNC_IOC_EVENT_PULSE    PPSYNC_IOC(0x8a)
#define NTSYNC_IOC_SEM_READ       PPSYNC_IOC(0x8b)
#define NTSYNC_IOC_MUTEX_READ     PPSYNC_IOC(0x8c)
#define NTSYNC_IOC_EVENT_READ     PPSYNC_IOC(0x8d)

#include "../ppsync.h"

#ifndef PPSYNC_IMPLEMENTATION
#define ioctl(fd, req, arg) ppsync_ioctl( (fd), (unsigned long)(req), (void *)(arg) )
#define close(fd)           ppsync_close( fd )
#endif

#endif
