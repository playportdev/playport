/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * ppsync: Playport's in-process NT synchronisation. Design and rules:
 * build/ppsync/README.md. Interface: ppsync.h and linux/ntsync.h here.
 *
 * Grown from Madeira's userspace ntsync (build/madsync/madsync.c, ml1058):
 * its pseudo-descriptor table, its server -> client hand-off and its
 * lock-free answer to a poll that finds nothing are kept. What changed:
 *
 * - Locking is the ntsync driver's: every object has its own lock, and one
 *   global lock is taken only for wait-all (and for a change to an object
 *   that a wait-all waiter is linked on). madsync took one global mutex for
 *   every operation of every thread.
 * - A waiter is satisfied by whoever changes the object: the changer claims it
 *   with a compare-and-swap on its `signaled' word, consumes the object and
 *   wakes the waiting thread's futex word. madsync re-scanned every waiter.
 * - The server can reach a waiting thread (ppsync_kick, ppsync_freeze): a
 *   system APC or the thread's end makes its wait return ECANCELED, so ntdll
 *   makes the server call that runs it; a suspended thread is not woken and
 *   does not leave a wait until it is resumed, as with a server wait. madsync
 *   had neither, so a named-pipe read never completed (madeira-unix 0014).
 * - A lock-free poll answers only a single object, where a load is the
 *   object's state at one instant; several objects take the locks.
 *
 * Builds for iOS (os_unfair_lock, os_sync_wait_on_address, __ulock_wait) and
 * for Linux (pthread mutexes, futex), where build/ppsync/ppsync_test.c runs it
 * under ThreadSanitizer. */
#define PPSYNC_IMPLEMENTATION
#include "linux/ntsync.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(__has_include)
# if __has_include("../madeira_cfg.h")
#  include "../madeira_cfg.h"   /* Madeira's madeira.cfg reader, in the runtime build */
#  define PPS_HAVE_CFG 1
# endif
#endif

#ifdef __APPLE__
# include <os/lock.h>
# include <AvailabilityMacros.h>
# ifdef MAC_OS_VERSION_14_4
#  include <os/os_sync_wait_on_address.h>
# endif
extern int __ulock_wait( uint32_t operation, void *addr, uint64_t value, uint32_t timeout_us );
extern int __ulock_wake( uint32_t operation, void *addr, uint64_t wake_value );
# ifndef UL_COMPARE_AND_WAIT
#  define UL_COMPARE_AND_WAIT 1
# endif
# ifndef ULF_WAKE_ALL
#  define ULF_WAKE_ALL 0x00000100
# endif
#else
# include <linux/futex.h>
# include <sys/syscall.h>
#endif

#define RLX memory_order_relaxed
#define ACQ memory_order_acquire
#define REL memory_order_release

/* ---- platform: locks, futex words, clocks ------------------------------- */

#ifdef __APPLE__
typedef os_unfair_lock pps_lock_t;
# define PPS_LOCK_INITIALIZER OS_UNFAIR_LOCK_INIT
static inline void pps_lock_init( pps_lock_t *l ) { *l = OS_UNFAIR_LOCK_INIT; }
static inline int  pps_trylock( pps_lock_t *l ) { return os_unfair_lock_trylock( l ); }
static inline void pps_lock_wait( pps_lock_t *l ) { os_unfair_lock_lock( l ); }
static inline void pps_unlock( pps_lock_t *l ) { os_unfair_lock_unlock( l ); }
#else
typedef pthread_mutex_t pps_lock_t;
# define PPS_LOCK_INITIALIZER PTHREAD_MUTEX_INITIALIZER
static inline void pps_lock_init( pps_lock_t *l ) { pthread_mutex_init( l, NULL ); }
static inline int  pps_trylock( pps_lock_t *l ) { return !pthread_mutex_trylock( l ); }
static inline void pps_lock_wait( pps_lock_t *l ) { pthread_mutex_lock( l ); }
static inline void pps_unlock( pps_lock_t *l ) { pthread_mutex_unlock( l ); }
#endif

/* Sleep while *addr reads val, for at most rel_ns (0 = no limit). Spurious
 * returns are allowed: every caller re-checks. */
static void pps_futex_wait( _Atomic uint32_t *addr, uint32_t val, uint64_t rel_ns )
{
#ifdef __APPLE__
# ifdef MAC_OS_VERSION_14_4
    if (__builtin_available( macOS 14.4, iOS 17.4, * ))
    {
        if (rel_ns)
            os_sync_wait_on_address_with_timeout( (void *)addr, val, 4, OS_SYNC_WAIT_ON_ADDRESS_NONE,
                                                  OS_CLOCK_MACH_ABSOLUTE_TIME, rel_ns );
        else
            os_sync_wait_on_address( (void *)addr, val, 4, OS_SYNC_WAIT_ON_ADDRESS_NONE );
        return;
    }
# endif
    {
        uint64_t us = rel_ns / 1000;
        if (rel_ns && !us) us = 1;
        if (us > 0xffffffffull) us = 0xffffffffull;
        __ulock_wait( UL_COMPARE_AND_WAIT, (void *)addr, val, (uint32_t)us );
    }
#else
    struct timespec ts = { (time_t)(rel_ns / 1000000000ull), (long)(rel_ns % 1000000000ull) };
    syscall( SYS_futex, (uint32_t *)addr, FUTEX_WAIT_PRIVATE, val, rel_ns ? &ts : NULL, NULL, 0 );
#endif
}

static void pps_futex_wake( _Atomic uint32_t *addr )
{
#ifdef __APPLE__
# ifdef MAC_OS_VERSION_14_4
    if (__builtin_available( macOS 14.4, iOS 17.4, * ))
    {
        os_sync_wake_by_address_all( (void *)addr, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE );
        return;
    }
# endif
    __ulock_wake( UL_COMPARE_AND_WAIT | ULF_WAKE_ALL, (void *)addr, 0 );
#else
    syscall( SYS_futex, (uint32_t *)addr, FUTEX_WAKE_PRIVATE, 0x7fffffff, NULL, NULL, 0 );
#endif
}

static uint64_t now_ns( int realtime )
{
    struct timespec ts;
    clock_gettime( realtime ? CLOCK_REALTIME : CLOCK_MONOTONIC, &ts );
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static long long cfg_int( const char *key, long long dflt )
{
#ifdef PPS_HAVE_CFG
    return madeira_cfg_int( key, dflt );
#else
    (void)key;
    return dflt;
#endif
}

/* ---- per-thread state ------------------------------------------------------
 * One record per Windows thread id, never freed, so the server can kick or
 * freeze a thread that is not waiting (the record remembers it) and a waker
 * may touch a record after the waiter is gone. Its futex word is the only
 * thing a waiting thread sleeps on: it is bumped whenever the thread's wait is
 * satisfied, the thread is kicked or it is thawed. */
struct pps_tstate
{
    _Atomic uint32_t futex;
    _Atomic uint32_t kicked;
    _Atomic uint32_t frozen;
    _Atomic uint32_t sleeping;   /* about to sleep, or asleep, on futex: a waker must make the call */
    _Atomic uint32_t thaws;      /* bumped by every thaw: a waiter looks at its objects again */
    _Atomic unsigned long long waits, polls, blocked, wakes, timeouts, cancels, frozen_waits,
                               spin_hits, contended;
};

#define PPS_TBLOCK      1024          /* records per block */
#define PPS_TBLOCKS     1024          /* blocks: thread ids below 4 M */
#define PPS_PRIVATE     64            /* records for threads with no usable id */

static struct pps_tstate *_Atomic g_tblocks[PPS_TBLOCKS];
static pps_lock_t g_tblock_lock = PPS_LOCK_INITIALIZER;
static struct pps_tstate g_private[PPS_PRIVATE + 1];   /* the last one is shared when they run out */
static _Atomic unsigned int g_nprivate;
static _Atomic unsigned long long g_contended_unowned;  /* lock contention of threads with no record */

static __thread struct pps_tstate *tls_t;   /* this thread's record, once it waited */

static struct pps_tstate *tstate_of( uint32_t tid, int create )
{
    uint32_t idx = tid >> 2, b = idx / PPS_TBLOCK;
    struct pps_tstate *block;

    if (!tid || b >= PPS_TBLOCKS) return NULL;
    if (!(block = atomic_load_explicit( &g_tblocks[b], ACQ )))
    {
        if (!create) return NULL;
        pps_lock_wait( &g_tblock_lock );
        if (!(block = atomic_load_explicit( &g_tblocks[b], RLX )))
        {
            if (!(block = calloc( PPS_TBLOCK, sizeof(*block) ))) { pps_unlock( &g_tblock_lock ); return NULL; }
            atomic_store_explicit( &g_tblocks[b], block, REL );
        }
        pps_unlock( &g_tblock_lock );
    }
    return &block[idx % PPS_TBLOCK];
}

/* The record a waiting thread with Windows thread id `owner' sleeps on. */
static struct pps_tstate *self_tstate( uint32_t owner )
{
    struct pps_tstate *t = tstate_of( owner, 1 );
    if (!t)
    {
        static __thread struct pps_tstate *priv;
        if (!priv)
        {
            unsigned int n = atomic_fetch_add_explicit( &g_nprivate, 1, RLX );
            priv = &g_private[n < PPS_PRIVATE ? n : PPS_PRIVATE];
        }
        t = priv;
    }
    tls_t = t;
    return t;
}

static inline void count( _Atomic unsigned long long *c )
{
    atomic_fetch_add_explicit( c, 1, RLX );
}

static inline void pps_lock( pps_lock_t *l )
{
    if (pps_trylock( l )) return;
    if (tls_t) count( &tls_t->contended ); else count( &g_contended_unowned );
    pps_lock_wait( l );
}

/* Wake a thread: bump its futex word after whatever made it runnable, then
 * make the futex call only if it may be asleep. All seq_cst: a sleeper stores
 * `sleeping' before it checks its condition one last time, so either it sees
 * the change or the waker sees it sleeping; and a sleeper whose word moved
 * since it read it does not sleep. */

static void wake_tstate( struct pps_tstate *t )
{
    atomic_fetch_add( &t->futex, 1 );
    /* the last private record is shared, so its `sleeping' is not one thread's */
    if (atomic_load( &t->sleeping ) || t == &g_private[PPS_PRIVATE]) pps_futex_wake( &t->futex );
}

/* Sleep on t's word, which read `seq' before the caller's last check. */
static void sleep_tstate( struct pps_tstate *t, uint32_t seq, uint64_t rel_ns )
{
    atomic_store( &t->sleeping, 1 );
    if (atomic_load( &t->futex ) == seq) pps_futex_wait( &t->futex, seq, rel_ns );
    atomic_store( &t->sleeping, 0 );
}

/* Wakes collected under an object lock and made after it is released; a
 * record is never freed, so this is safe once the waiter has moved on. */
struct pps_wakeset { unsigned int n; struct pps_tstate *t[16]; };

static void ws_add( struct pps_wakeset *ws, struct pps_tstate *t )
{
    unsigned int i;
    for (i = 0; i < ws->n; i++) if (ws->t[i] == t) return;
    if (ws->n < sizeof(ws->t) / sizeof(ws->t[0])) ws->t[ws->n++] = t;
    else wake_tstate( t );
}

/* `self' (or NULL) is the calling thread, which checks its own wait again
 * before it sleeps and needs no wake. */
static void ws_flush( struct pps_wakeset *ws, struct pps_tstate *self )
{
    unsigned int i;
    if (self == &g_private[PPS_PRIVATE]) self = NULL;   /* shared: the wake may be another thread's */
    for (i = 0; i < ws->n; i++) if (ws->t[i] != self) wake_tstate( ws->t[i] );
    ws->n = 0;
}

/* ---- objects -------------------------------------------------------------- */

enum { PPS_SEM = 1, PPS_MUTEX, PPS_EVENT };

struct pps_list { struct pps_list *next, *prev; };

static inline void list_init( struct pps_list *h ) { h->next = h->prev = h; }
static inline void list_add_tail( struct pps_list *h, struct pps_list *n )
{
    n->prev = h->prev; n->next = h; h->prev->next = n; h->prev = n;
}
static inline void list_del( struct pps_list *n )
{
    n->prev->next = n->next; n->next->prev = n->prev; n->next = n->prev = NULL;
}

struct pps_obj
{
    pps_lock_t       lock;
    int              type;
    _Atomic uint32_t a, b;       /* sem: count,max  mutex: owner,count  event: manual,signaled */
    int              ownerdead;  /* mutex: abandoned and not yet reported (under lock) */
    _Atomic int      refs;
    int              all_hint;   /* wait-all waiters linked: changed under g_all_lock and lock */
    unsigned int     idx;
    struct pps_list  any_waiters, all_waiters;
};

/* Taken for wait-all, and for any change to an object with all_hint set,
 * before the object's own lock. Only a holder of g_all_lock ever holds more
 * than one object lock, so no two orders can meet. */
static pps_lock_t g_all_lock = PPS_LOCK_INITIALIZER;

static inline uint32_t ld( _Atomic uint32_t *v ) { return atomic_load_explicit( v, ACQ ); }
static inline void st( _Atomic uint32_t *v, uint32_t x ) { atomic_store_explicit( v, x, REL ); }

/* Could a waiter owned by `owner' take this object now? Single loads, so the
 * lock-free poll may call it too. */
static int obj_ready( struct pps_obj *o, uint32_t owner )
{
    switch (o->type)
    {
    case PPS_SEM:   return ld( &o->a ) > 0;
    case PPS_MUTEX:
    {
        uint32_t own = ld( &o->a );
        return !own || (own == owner && ld( &o->b ) < UINT32_MAX);
    }
    default:        return ld( &o->b ) != 0;
    }
}

/* ---- the descriptor table ------------------------------------------------- */

static pps_lock_t g_tab_lock = PPS_LOCK_INITIALIZER;
static _Atomic(struct pps_obj *) *_Atomic g_tab;
static _Atomic unsigned int g_cap;
static unsigned int *g_freelist, g_nfree, g_freecap, g_next = 1;   /* index 0 is never used: alert 0 = none */
static _Atomic unsigned long long g_created, g_live;

/* Readable without a lock: growth publishes the new table before the new
 * capacity and never frees the old one, so (cap, tab) read in this order
 * always index a live table. The caller holds a reference to the object it
 * names (its descriptor), so the object cannot be freed under it. */
static struct pps_obj *obj_of( int fd )
{
    unsigned int idx = (unsigned int)fd & 0x0fffffffu, cap;
    _Atomic(struct pps_obj *) *tab;

    if (!PPSYNC_IS_FD( fd )) return NULL;
    cap = atomic_load_explicit( &g_cap, ACQ );
    tab = atomic_load_explicit( &g_tab, ACQ );
    return idx < cap ? atomic_load_explicit( &tab[idx], ACQ ) : NULL;
}

static int obj_new( int type, uint32_t a, uint32_t b )
{
    struct pps_obj *o = calloc( 1, sizeof(*o) );
    unsigned int idx, cap;
    _Atomic(struct pps_obj *) *tab;

    if (!o) { errno = ENOMEM; return -1; }
    pps_lock_init( &o->lock );
    o->type = type;
    atomic_init( &o->a, a );
    atomic_init( &o->b, b );
    atomic_init( &o->refs, 1 );
    list_init( &o->any_waiters );
    list_init( &o->all_waiters );

    pps_lock_wait( &g_tab_lock );
    cap = atomic_load_explicit( &g_cap, RLX );
    tab = atomic_load_explicit( &g_tab, RLX );
    if (g_nfree) idx = g_freelist[--g_nfree];
    else
    {
        if (g_next >= 0x0fffffffu) { pps_unlock( &g_tab_lock ); free( o ); errno = EMFILE; return -1; }
        if (g_next >= cap)
        {
            unsigned int ncap = cap ? cap * 2 : 4096, i;
            _Atomic(struct pps_obj *) *nt = calloc( ncap, sizeof(*nt) );   /* the old table is leaked on purpose */
            if (!nt) { pps_unlock( &g_tab_lock ); free( o ); errno = ENOMEM; return -1; }
            for (i = 0; i < cap; i++) atomic_init( &nt[i], atomic_load_explicit( &tab[i], RLX ) );
            atomic_store_explicit( &g_tab, nt, REL );
            atomic_store_explicit( &g_cap, ncap, REL );
            tab = nt;
        }
        idx = g_next++;
    }
    o->idx = idx;
    atomic_store_explicit( &tab[idx], o, REL );
    pps_unlock( &g_tab_lock );
    count( &g_created );
    count( &g_live );
    return PPSYNC_FD_BASE | (int)idx;
}

static void obj_unref( struct pps_obj *o )
{
    _Atomic(struct pps_obj *) *tab;

    if (atomic_fetch_sub_explicit( &o->refs, 1, memory_order_acq_rel ) != 1) return;
    pps_lock_wait( &g_tab_lock );
    tab = atomic_load_explicit( &g_tab, RLX );
    atomic_store_explicit( &tab[o->idx], NULL, REL );
    if (g_nfree == g_freecap)
    {
        unsigned int ncap = g_freecap ? g_freecap * 2 : 1024;
        unsigned int *nf = realloc( g_freelist, ncap * sizeof(*nf) );
        if (nf) { g_freelist = nf; g_freecap = ncap; }
    }
    if (g_nfree < g_freecap) g_freelist[g_nfree++] = o->idx;
    pps_unlock( &g_tab_lock );
    atomic_fetch_sub_explicit( &g_live, 1, RLX );
#ifndef __APPLE__
    pthread_mutex_destroy( &o->lock );
#endif
    free( o );
}

int ppsync_close( int fd )
{
    struct pps_obj *o;
    if (fd == PPSYNC_DEVICE_FD) return 0;
    if (!PPSYNC_IS_FD( fd )) return close( fd );
    if ((o = obj_of( fd ))) obj_unref( o );
    return 0;
}

/* ---- server -> client hand-off -------------------------------------------- */

/* A post is taken by the requesting thread right after the server's reply,
 * so a live entry is microseconds old. An entry that is never taken (a reply
 * the client did not act on) must not fill the table: a post for the same
 * (tid, handle) replaces it, and a full table drops its oldest entry. Each
 * dropped entry gives back the reference its post took, and the first few
 * are logged, as are takes that find nothing. */
#define PPS_POSTS 1024
static struct { unsigned int tid, handle; int fd; unsigned long long seq; } g_post[PPS_POSTS];
static unsigned long long g_post_seq;
static pps_lock_t g_post_lock = PPS_LOCK_INITIALIZER;
static _Atomic unsigned long long g_post_replaced, g_post_evicted, g_take_missed;

static void post_drop( unsigned int i, const char *why, _Atomic unsigned long long *counter )
{
    struct pps_obj *o = obj_of( g_post[i].fd );
    unsigned long long n = atomic_fetch_add_explicit( counter, 1, RLX );
    if (n < 8 || !(n & (n - 1)))
        dprintf( 2, "[ppsync] hand-off %s: tid %04x handle %#x (%llu posts old), %llu so far\n",
                 why, g_post[i].tid, g_post[i].handle, g_post_seq - g_post[i].seq, n + 1 );
    g_post[i].fd = 0;
    if (o) obj_unref( o );
}

void ppsync_post( unsigned int tid, unsigned int handle, int fd )
{
    struct pps_obj *o = obj_of( fd );
    unsigned int i, slot = PPS_POSTS, oldest = 0;

    if (!o) return;
    atomic_fetch_add_explicit( &o->refs, 1, RLX );
    pps_lock_wait( &g_post_lock );
    for (i = 0; i < PPS_POSTS; i++)
    {
        if (!g_post[i].fd) { if (slot == PPS_POSTS) slot = i; continue; }
        if (g_post[i].tid == tid && g_post[i].handle == handle)
        {
            post_drop( i, "replaced", &g_post_replaced );
            if (slot == PPS_POSTS || slot > i) slot = i;
            continue;
        }
        if (g_post[i].seq < g_post[oldest].seq || !g_post[oldest].fd) oldest = i;
    }
    if (slot == PPS_POSTS)
    {
        post_drop( oldest, "evicted", &g_post_evicted );
        slot = oldest;
    }
    g_post[slot].tid = tid; g_post[slot].handle = handle; g_post[slot].fd = fd;
    g_post[slot].seq = ++g_post_seq;
    pps_unlock( &g_post_lock );
}

int ppsync_take( unsigned int tid, unsigned int handle )
{
    unsigned int i; int fd = -1;
    pps_lock_wait( &g_post_lock );
    for (i = 0; i < PPS_POSTS; i++)
        if (g_post[i].fd && g_post[i].tid == tid && g_post[i].handle == handle)
        {
            fd = g_post[i].fd; g_post[i].fd = 0;
            break;
        }
    pps_unlock( &g_post_lock );
    if (fd < 0)
    {
        unsigned long long n = atomic_fetch_add_explicit( &g_take_missed, 1, RLX );
        if (n < 8 || !(n & (n - 1)))
            dprintf( 2, "[ppsync] hand-off missed: tid %04x handle %#x, %llu so far\n", tid, handle, n + 1 );
    }
    return fd;
}

/* ---- waiters -------------------------------------------------------------- */

#define PPS_PENDING   (-1)
#define PPS_CANCELLED (-2)   /* the waiter itself gave up: timeout or kick */

struct pps_waiter;
struct pps_entry
{
    struct pps_list    node;
    struct pps_waiter *q;
    struct pps_obj    *obj;
    uint32_t           index;
};

struct pps_waiter
{
    _Atomic int        signaled;   /* PPS_PENDING, PPS_CANCELLED or the index that satisfied it */
    uint32_t           owner;
    int                all;
    int                ownerdead;  /* set by the satisfier under the mutex's lock */
    int                linked;
    uint32_t           count;      /* objects, the alert not included */
    uint32_t           n;          /* entries: count, plus one for the alert */
    struct pps_tstate *t;
    struct pps_entry   e[NTSYNC_MAX_WAIT_COUNT + 1];
};

static void obj_consume( struct pps_obj *o, struct pps_waiter *q )
{
    switch (o->type)
    {
    case PPS_SEM:   st( &o->a, ld( &o->a ) - 1 ); break;
    case PPS_MUTEX:
        if (o->ownerdead) { q->ownerdead = 1; o->ownerdead = 0; }
        st( &o->b, ld( &o->b ) + 1 );
        st( &o->a, q->owner );
        break;
    default:        if (!ld( &o->a )) st( &o->b, 0 ); break;   /* auto-reset consumes; manual stays set */
    }
}

static inline int frozen( struct pps_waiter *q )
{
    return atomic_load_explicit( &q->t->frozen, ACQ ) != 0;
}

/* o is locked: satisfy its wait-any waiters (and wait-all waiters' alerts),
 * first come first served, while it stays ready. */
static void try_wake_any_obj( struct pps_obj *o, struct pps_wakeset *ws )
{
    struct pps_list *n;

    for (n = o->any_waiters.next; n != &o->any_waiters; n = n->next)
    {
        struct pps_entry *e = (struct pps_entry *)((char *)n - offsetof(struct pps_entry, node));
        struct pps_waiter *q = e->q;
        int pending = PPS_PENDING;

        if (!obj_ready( o, q->owner ))
        {
            if (o->type != PPS_MUTEX) break;   /* a mutex may be ready for another owner */
            continue;
        }
        if (atomic_load( &q->signaled ) != PPS_PENDING || frozen( q )) continue;
        if (atomic_compare_exchange_strong( &q->signaled, &pending, (int)e->index ))
        {
            obj_consume( o, q );
            count( &q->t->wakes );
            ws_add( ws, q->t );
        }
    }
}

/* g_all_lock is held, and `locked' (one of q's objects, or NULL) is: satisfy
 * wait-all waiter q if every one of its objects is ready at once. */
static void try_wake_all( struct pps_waiter *q, struct pps_obj *locked, struct pps_wakeset *ws )
{
    uint32_t i;
    int ok = 1, pending = PPS_PENDING;

    if (atomic_load( &q->signaled ) != PPS_PENDING || frozen( q )) return;
    for (i = 0; i < q->count; i++) if (q->e[i].obj != locked) pps_lock( &q->e[i].obj->lock );
    for (i = 0; i < q->count && ok; i++) ok = obj_ready( q->e[i].obj, q->owner );
    if (ok && atomic_compare_exchange_strong( &q->signaled, &pending, 0 ))
    {
        for (i = 0; i < q->count; i++) obj_consume( q->e[i].obj, q );
        count( &q->t->wakes );
        ws_add( ws, q->t );
    }
    for (i = 0; i < q->count; i++) if (q->e[i].obj != locked) pps_unlock( &q->e[i].obj->lock );
}

/* g_all_lock and o are locked */
static void try_wake_all_obj( struct pps_obj *o, struct pps_wakeset *ws )
{
    struct pps_list *n;
    for (n = o->all_waiters.next; n != &o->all_waiters; n = n->next)
        try_wake_all( ((struct pps_entry *)((char *)n - offsetof(struct pps_entry, node)))->q, o, ws );
}

/* Lock o for a change. Returns 1 when g_all_lock was taken as well, because
 * a wait-all waiter is linked on o: all_hint only changes under both locks, so
 * reading it under o's lock is enough to decide. */
static int lock_obj( struct pps_obj *o )
{
    pps_lock( &o->lock );
    if (!o->all_hint) return 0;
    pps_unlock( &o->lock );
    pps_lock( &g_all_lock );
    pps_lock( &o->lock );
    return 1;
}

static void unlock_obj( struct pps_obj *o, int all )
{
    pps_unlock( &o->lock );
    if (all) pps_unlock( &g_all_lock );
}

/* o's state rose and o is locked (all: with g_all_lock): satisfy whom it can. */
static void obj_changed( struct pps_obj *o, int all, struct pps_wakeset *ws )
{
    if (all) try_wake_all_obj( o, ws );
    try_wake_any_obj( o, ws );
}

static void waiter_link( struct pps_waiter *q, struct pps_wakeset *ws )
{
    uint32_t i;

    if (!q->all)
    {
        for (i = 0; i < q->n; i++)
        {
            int all = lock_obj( q->e[i].obj );
            list_add_tail( &q->e[i].obj->any_waiters, &q->e[i].node );
            unlock_obj( q->e[i].obj, all );
        }
        q->linked = 1;
        for (i = 0; i < q->n && atomic_load( &q->signaled ) == PPS_PENDING; i++)
        {
            int all = lock_obj( q->e[i].obj );
            try_wake_any_obj( q->e[i].obj, ws );
            unlock_obj( q->e[i].obj, all );
        }
        return;
    }
    pps_lock( &g_all_lock );
    for (i = 0; i < q->count; i++)
    {
        struct pps_obj *o = q->e[i].obj;
        pps_lock( &o->lock );
        o->all_hint++;
        list_add_tail( &o->all_waiters, &q->e[i].node );
        pps_unlock( &o->lock );
    }
    if (q->n > q->count)
    {
        struct pps_obj *alert = q->e[q->count].obj;
        pps_lock( &alert->lock );
        list_add_tail( &alert->any_waiters, &q->e[q->count].node );
        pps_unlock( &alert->lock );
    }
    q->linked = 1;
    try_wake_all( q, NULL, ws );
    if (q->n > q->count)
    {
        struct pps_obj *alert = q->e[q->count].obj;
        pps_lock( &alert->lock );
        try_wake_any_obj( alert, ws );
        pps_unlock( &alert->lock );
    }
    pps_unlock( &g_all_lock );
}

/* After a thaw (or a spurious wake): look again, as a resumed thread's server
 * wait is checked again. */
static void waiter_retry( struct pps_waiter *q, struct pps_wakeset *ws )
{
    uint32_t i;

    if (!q->all)
    {
        for (i = 0; i < q->n && atomic_load( &q->signaled ) == PPS_PENDING; i++)
        {
            int all = lock_obj( q->e[i].obj );
            try_wake_any_obj( q->e[i].obj, ws );
            unlock_obj( q->e[i].obj, all );
        }
        return;
    }
    pps_lock( &g_all_lock );
    try_wake_all( q, NULL, ws );
    if (q->n > q->count)
    {
        struct pps_obj *alert = q->e[q->count].obj;
        pps_lock( &alert->lock );
        try_wake_any_obj( alert, ws );
        pps_unlock( &alert->lock );
    }
    pps_unlock( &g_all_lock );
}

/* Once this returns no waker can reach q: it was unlinked under the lock of
 * every object it was on. */
static void waiter_unlink( struct pps_waiter *q )
{
    uint32_t i;

    if (!q->linked) return;
    if (!q->all)
    {
        for (i = 0; i < q->n; i++)
        {
            int all = lock_obj( q->e[i].obj );
            list_del( &q->e[i].node );
            unlock_obj( q->e[i].obj, all );
        }
    }
    else
    {
        pps_lock( &g_all_lock );
        for (i = 0; i < q->count; i++)
        {
            struct pps_obj *o = q->e[i].obj;
            pps_lock( &o->lock );
            list_del( &q->e[i].node );
            o->all_hint--;
            pps_unlock( &o->lock );
        }
        if (q->n > q->count)
        {
            struct pps_obj *alert = q->e[q->count].obj;
            pps_lock( &alert->lock );
            list_del( &q->e[q->count].node );
            pps_unlock( &alert->lock );
        }
        pps_unlock( &g_all_lock );
    }
    q->linked = 0;
}

static void waiter_release( struct pps_waiter *q )
{
    uint32_t i;
    for (i = 0; i < q->n; i++) obj_unref( q->e[i].obj );
    q->n = 0;
}

/* The waiter is per thread, on the heap: a thread that ends while it waits
 * (pthread_exit) is unlinked by the destructor, so no waker reaches freed
 * memory. */
static pthread_key_t  g_wkey;
static pthread_once_t g_wkey_once = PTHREAD_ONCE_INIT;
static __thread struct pps_waiter *tls_w;

static void waiter_destroy( void *arg )
{
    struct pps_waiter *q = arg;
    waiter_unlink( q );
    waiter_release( q );
    free( q );
}
static void wkey_init(void) { pthread_key_create( &g_wkey, waiter_destroy ); }

static struct pps_waiter *self_waiter(void)
{
    if (tls_w) return tls_w;
    pthread_once( &g_wkey_once, wkey_init );
    if (!(tls_w = calloc( 1, sizeof(*tls_w) ))) return NULL;
    pthread_setspecific( g_wkey, tls_w );
    return tls_w;
}

/* A frozen thread does not go on past a wait until it is thawed, or until it
 * is kicked: a suspended thread still runs system APCs (check_wait). Returns
 * whether a kick ended it. */
static int wait_thawed( struct pps_tstate *t )
{
    int counted = 0;
    for (;;)
    {
        uint32_t seq = atomic_load( &t->futex );
        if (!atomic_load( &t->frozen )) return 0;
        if (atomic_load( &t->kicked )) return 1;
        if (!counted++) count( &t->frozen_waits );
        sleep_tstate( t, seq, 0 );
    }
}

static _Atomic int g_spin_ns = -1;   /* madeira.cfg ppsync-spin-us, read at the first wait that would sleep */

static void stats_maybe_log( void );

static int do_wait( struct ntsync_wait_args *args, int all )
{
    const int *fds = (const int *)(uintptr_t)args->objs;
    const int realtime = (args->flags & NTSYNC_WAIT_REALTIME) != 0;
    const int forever = args->timeout == ~(uint64_t)0;
    struct pps_wakeset ws = { 0 };
    struct pps_tstate *t;
    struct pps_waiter *q;
    uint32_t i, j;
    int ret = 0, s, kicked = 0;
    uint32_t thaws;

    if (args->count > NTSYNC_MAX_WAIT_COUNT) { errno = EINVAL; return -1; }
    t = self_tstate( args->owner );
    count( &t->waits );

    /* A suspended thread does not start a wait, as the server would not let
     * its wait be satisfied. A system APC (or the thread's end) goes first,
     * suspended or not: nothing has been consumed. */
    wait_thawed( t );
    if (atomic_load( &t->kicked ) && atomic_exchange( &t->kicked, 0 ))
    {
        count( &t->cancels );
        errno = ECANCELED;
        return -1;
    }

    /* A poll on one object that finds it not ready needs no lock: one load is
     * its state at one instant, and the alert (read last) is only ever lowered
     * by this thread. The caller's descriptor pins the object. */
    if (!forever && args->count <= 1 && now_ns( realtime ) >= args->timeout)
    {
        struct pps_obj *o = args->count ? obj_of( fds[0] ) : NULL, *alert = NULL;
        if ((o || !args->count) && (!o || !obj_ready( o, args->owner )) &&
            (!args->alert || ((alert = obj_of( (int)args->alert )) && !obj_ready( alert, args->owner ))))
        {
            count( &t->polls );
            errno = ETIMEDOUT;
            return -1;
        }
    }

    if (!(q = self_waiter())) { errno = ENOMEM; return -1; }
    atomic_store( &q->signaled, PPS_PENDING );
    q->owner = args->owner;
    q->all = all && args->count > 1;
    q->ownerdead = 0;
    q->linked = 0;
    q->count = args->count;
    q->n = 0;
    q->t = t;

    for (i = 0; i < args->count; i++)
    {
        struct pps_obj *o = obj_of( fds[i] );
        if (!o) { waiter_release( q ); errno = EBADF; return -1; }
        if (q->all)
            for (j = 0; j < i; j++)
                if (q->e[j].obj == o) { waiter_release( q ); errno = EINVAL; return -1; }
        atomic_fetch_add_explicit( &o->refs, 1, RLX );   /* outlives a close during the wait */
        q->e[i].q = q; q->e[i].obj = o; q->e[i].index = i;
        q->n++;
    }
    if (args->alert)
    {
        struct pps_obj *o = obj_of( (int)args->alert );
        if (!o) { waiter_release( q ); errno = EBADF; return -1; }
        atomic_fetch_add_explicit( &o->refs, 1, RLX );
        q->e[q->count].q = q; q->e[q->count].obj = o; q->e[q->count].index = q->count;
        q->n++;
    }

    /* Wakers pass over a frozen waiter, so every thaw from here on makes it
     * look at its objects again (read before linking: a freeze and thaw during
     * the link are not missed). */
    thaws = atomic_load( &t->thaws );
    waiter_link( q, &ws );
    ws_flush( &ws, t );

    if (atomic_load( &q->signaled ) == PPS_PENDING && !atomic_load( &t->frozen ))
    {
        int spin_ns = atomic_load_explicit( &g_spin_ns, RLX );
        if (spin_ns < 0)
        {
            long long us = cfg_int( "ppsync-spin-us", 0 );
            spin_ns = (int)((us < 0 ? 0 : us > 200 ? 200 : us) * 1000);
            atomic_store_explicit( &g_spin_ns, spin_ns, RLX );
        }
        if (spin_ns)   /* opt-in: spin on our own word before sleeping */
        {
            uint64_t end = now_ns( 0 ) + (uint64_t)spin_ns;
            while (atomic_load_explicit( &q->signaled, ACQ ) == PPS_PENDING && !atomic_load( &t->kicked ) &&
                   now_ns( 0 ) < end)
            {
#if defined(__aarch64__) || defined(__arm64__)
                __asm__ __volatile__( "yield" );
#endif
            }
            if (atomic_load( &q->signaled ) != PPS_PENDING) count( &t->spin_hits );
        }
    }

    if (atomic_load( &q->signaled ) == PPS_PENDING) count( &t->blocked );
    for (;;)
    {
        uint32_t seq = atomic_load( &t->futex );
        uint64_t rel = 0;
        int pending = PPS_PENDING;

        if (atomic_load( &q->signaled ) != PPS_PENDING) break;
        if (atomic_load( &t->kicked ))
        {
            if (atomic_compare_exchange_strong( &q->signaled, &pending, PPS_CANCELLED )) { kicked = 1; break; }
            continue;
        }
        if (!atomic_load( &t->frozen ) && atomic_load( &t->thaws ) != thaws)
        {
            thaws = atomic_load( &t->thaws );
            waiter_retry( q, &ws );
            ws_flush( &ws, t );
            continue;
        }
        if (!forever)
        {
            uint64_t now = now_ns( realtime );
            if (now >= args->timeout)
            {
                if (atomic_compare_exchange_strong( &q->signaled, &pending, PPS_CANCELLED )) break;
                continue;
            }
            rel = args->timeout - now;
        }
        sleep_tstate( t, seq, rel );
    }

    waiter_unlink( q );
    s = atomic_load( &q->signaled );
    if (s >= 0)
    {
        args->index = (uint32_t)s;
        if (q->ownerdead) { errno = EOWNERDEAD; ret = -1; }
    }
    else if (kicked)
    {
        atomic_store( &t->kicked, 0 );
        count( &t->cancels );
        errno = ECANCELED;
        ret = -1;
    }
    else
    {
        count( &t->timeouts );
        errno = ETIMEDOUT;
        ret = -1;
    }
    waiter_release( q );
    /* A satisfied or timed-out wait of a suspended thread returns when it is
     * resumed. A kick while it is held here cannot be taken without losing
     * the result: it returns, and its next wait takes the kick first (the
     * deferred physical hold stops it in guest code meanwhile). */
    if (!kicked) wait_thawed( t );
    if (!(atomic_load_explicit( &t->waits, RLX ) & 0xffff)) stats_maybe_log();
    return ret;
}

/* ---- the server's reach into a waiting thread ----------------------------- */

void ppsync_kick( unsigned int tid )
{
    struct pps_tstate *t = tstate_of( tid, 1 );
    if (!t) return;
    atomic_store( &t->kicked, 1 );
    wake_tstate( t );
}

/* A thaw bumps `thaws' before it clears `frozen', and the futex word last, so
 * a waiter that sees frozen == 0 sees the new count. */
static void thaw( struct pps_tstate *t )
{
    atomic_fetch_add( &t->thaws, 1 );
    atomic_store( &t->frozen, 0 );
}

void ppsync_freeze( unsigned int tid, int on )
{
    struct pps_tstate *t = tstate_of( tid, 1 );
    if (!t) return;
    if (on) atomic_store( &t->frozen, 1 );
    else if (atomic_load( &t->frozen ))
    {
        thaw( t );
        wake_tstate( t );
    }
}

void ppsync_thread_gone( unsigned int tid )
{
    struct pps_tstate *t = tstate_of( tid, 0 );
    if (!t) return;
    thaw( t );
    atomic_store( &t->kicked, 1 );
    wake_tstate( t );
}

/* ---- statistics ------------------------------------------------------------ */

static void add_tstate( struct ppsync_stats *s, struct pps_tstate *t )
{
    s->waits        += atomic_load_explicit( &t->waits, RLX );
    s->polls        += atomic_load_explicit( &t->polls, RLX );
    s->blocked      += atomic_load_explicit( &t->blocked, RLX );
    s->wakes        += atomic_load_explicit( &t->wakes, RLX );
    s->timeouts     += atomic_load_explicit( &t->timeouts, RLX );
    s->cancels      += atomic_load_explicit( &t->cancels, RLX );
    s->frozen_waits += atomic_load_explicit( &t->frozen_waits, RLX );
    s->spin_hits    += atomic_load_explicit( &t->spin_hits, RLX );
    s->contended    += atomic_load_explicit( &t->contended, RLX );
}

void ppsync_get_stats( struct ppsync_stats *s )
{
    unsigned int b, i;
    memset( s, 0, sizeof(*s) );
    for (b = 0; b < PPS_TBLOCKS; b++)
    {
        struct pps_tstate *block = atomic_load_explicit( &g_tblocks[b], ACQ );
        if (block) for (i = 0; i < PPS_TBLOCK; i++) add_tstate( s, &block[i] );
    }
    for (i = 0; i <= PPS_PRIVATE; i++) add_tstate( s, &g_private[i] );
    s->contended   += atomic_load_explicit( &g_contended_unowned, RLX );
    s->objects      = atomic_load_explicit( &g_created, RLX );
    s->live_objects = atomic_load_explicit( &g_live, RLX );
}

/* At most one line every 10 s, from a thread that just made its 65536th wait. */
static void stats_maybe_log( void )
{
    static _Atomic uint64_t last;
    uint64_t now = now_ns( 0 ), prev = atomic_load_explicit( &last, RLX );
    struct ppsync_stats s;

    if (prev && now - prev < 10000000000ull) return;
    if (!atomic_compare_exchange_strong( &last, &prev, now )) return;
    ppsync_get_stats( &s );
    dprintf( 2, "[ppsync] %llu waits (%llu slept, %llu lock-free polls, %llu spin hits), %llu wakes, "
             "%llu timeouts, %llu kicks, %llu frozen; %llu objects (%llu live); lock contended %llu times\n",
             s.waits, s.blocked, s.polls, s.spin_hits, s.wakes, s.timeouts, s.cancels, s.frozen_waits,
             s.objects, s.live_objects, s.contended );
}

/* ---- the switch ------------------------------------------------------------ */

int ppsync_enabled(void)
{
    static _Atomic int state = -1;
    int on = atomic_load( &state );
    if (on < 0)
    {
        const char *e = getenv( "PLAYPORT_PPSYNC" );
        if (e && (!strcmp( e, "0" ) || !strcmp( e, "off" ) || !strcmp( e, "no" ))) on = 0;
        else on = (int)cfg_int( "inproc-sync", 1 ) != 0;
        atomic_store( &state, on );
        dprintf( 2, "[ppsync] in-process synchronisation %s (madeira.cfg inproc-sync = 0 or "
                 "PLAYPORT_PPSYNC=0 turns it off)\n", on ? "ENABLED" : "disabled" );
    }
    return on;
}

/* ---- the "driver" entry point ---------------------------------------------- */

int ppsync_ioctl( int fd, unsigned long req, void *arg )
{
    struct pps_wakeset ws = { 0 };
    struct pps_obj *o;
    int ret = 0, all;

    if ((req & PPSYNC_IOC_MASK) != PPSYNC_IOC(0)) return ioctl( fd, req, arg );

    switch (req)
    {
    case NTSYNC_IOC_CREATE_SEM:
    {
        struct ntsync_sem_args *a = arg;
        if (a->count > a->max) { errno = EINVAL; return -1; }
        return obj_new( PPS_SEM, a->count, a->max );
    }
    case NTSYNC_IOC_CREATE_MUTEX:
    {
        struct ntsync_mutex_args *a = arg;
        if (!a->owner != !a->count) { errno = EINVAL; return -1; }
        return obj_new( PPS_MUTEX, a->owner, a->count );
    }
    case NTSYNC_IOC_CREATE_EVENT:
    {
        struct ntsync_event_args *a = arg;
        return obj_new( PPS_EVENT, a->manual != 0, a->signaled != 0 );
    }
    case NTSYNC_IOC_WAIT_ANY: return do_wait( arg, 0 );
    case NTSYNC_IOC_WAIT_ALL: return do_wait( arg, 1 );
    }

    if (!(o = obj_of( fd ))) { errno = EBADF; return -1; }
    all = lock_obj( o );
    switch (req)
    {
    case NTSYNC_IOC_SEM_RELEASE:
    {
        uint32_t *n = arg, prev = ld( &o->a );
        if (o->type != PPS_SEM) { errno = EINVAL; ret = -1; break; }
        if ((uint64_t)prev + *n > ld( &o->b )) { errno = EOVERFLOW; ret = -1; break; }
        st( &o->a, prev + *n );
        *n = prev;
        obj_changed( o, all, &ws );
        break;
    }
    case NTSYNC_IOC_SEM_READ:
    {
        struct ntsync_sem_args *a = arg;
        if (o->type != PPS_SEM) { errno = EINVAL; ret = -1; break; }
        a->count = ld( &o->a ); a->max = ld( &o->b );
        break;
    }
    case NTSYNC_IOC_MUTEX_UNLOCK:
    {
        struct ntsync_mutex_args *a = arg;
        if (o->type != PPS_MUTEX) { errno = EINVAL; ret = -1; break; }
        if (!a->owner) { errno = EINVAL; ret = -1; break; }
        if (ld( &o->a ) != a->owner) { errno = EPERM; ret = -1; break; }
        a->count = ld( &o->b );
        st( &o->b, a->count - 1 );
        if (a->count == 1)
        {
            st( &o->a, 0 );
            obj_changed( o, all, &ws );
        }
        break;
    }
    case NTSYNC_IOC_MUTEX_KILL:
    {
        uint32_t owner = *(uint32_t *)arg;
        if (o->type != PPS_MUTEX) { errno = EINVAL; ret = -1; break; }
        if (!owner) { errno = EINVAL; ret = -1; break; }
        if (ld( &o->a ) != owner) { errno = EPERM; ret = -1; break; }
        o->ownerdead = 1;
        st( &o->b, 0 );
        st( &o->a, 0 );
        obj_changed( o, all, &ws );
        break;
    }
    case NTSYNC_IOC_MUTEX_READ:
    {
        struct ntsync_mutex_args *a = arg;
        if (o->type != PPS_MUTEX) { errno = EINVAL; ret = -1; break; }
        a->owner = ld( &o->a ); a->count = ld( &o->b );
        if (o->ownerdead) { errno = EOWNERDEAD; ret = -1; }
        break;
    }
    case NTSYNC_IOC_EVENT_SET:
    case NTSYNC_IOC_EVENT_PULSE:
    {
        uint32_t prev = ld( &o->b );
        if (o->type != PPS_EVENT) { errno = EINVAL; ret = -1; break; }
        st( &o->b, 1 );
        obj_changed( o, all, &ws );
        if (req == NTSYNC_IOC_EVENT_PULSE) st( &o->b, 0 );
        *(uint32_t *)arg = prev;
        break;
    }
    case NTSYNC_IOC_EVENT_RESET:
    {
        uint32_t prev = ld( &o->b );
        if (o->type != PPS_EVENT) { errno = EINVAL; ret = -1; break; }
        st( &o->b, 0 );
        *(uint32_t *)arg = prev;
        break;
    }
    case NTSYNC_IOC_EVENT_READ:
    {
        struct ntsync_event_args *a = arg;
        if (o->type != PPS_EVENT) { errno = EINVAL; ret = -1; break; }
        a->manual = ld( &o->a ); a->signaled = ld( &o->b );
        break;
    }
    default: errno = ENOTTY; ret = -1; break;
    }
    unlock_obj( o, all );
    ws_flush( &ws, NULL );
    return ret;
}
