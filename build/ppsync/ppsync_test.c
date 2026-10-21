/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Host tests for ppsync (build/ppsync/README.md): NT semantics, wait-all
 * atomicity, mutex abandonment, the server's kick and freeze, and a
 * multithreaded stress run. `pp test' builds it twice: plainly, and under
 * ThreadSanitizer. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "linux/ntsync.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ThreadSanitizer cannot see that try_wake_all() takes several object locks
 * only while it holds g_all_lock, the one lock every such path takes first
 * (the ntsync driver's spin_lock_nest_lock), and reports the orders it sees as
 * an inversion. Every other lock-order report stays on. */
const char *__tsan_default_suppressions( void );
const char *__tsan_default_suppressions( void ) { return "deadlock:try_wake_all\n"; }

static int failures;
#define CHECK(c) do { if (!(c)) { fprintf( stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c ); failures++; } } while (0)

static uint64_t mono_ns(void)
{
    struct timespec ts;
    clock_gettime( CLOCK_MONOTONIC, &ts );
    return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}
static uint64_t in_ms( unsigned int ms ) { return mono_ns() + ms * 1000000ull; }
static void sleep_ms( unsigned int ms )
{
    struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000 };
    nanosleep( &ts, NULL );
}

static int event( int manual, int signaled )
{
    struct ntsync_event_args a = { manual, signaled };
    return ioctl( PPSYNC_DEVICE_FD, NTSYNC_IOC_CREATE_EVENT, &a );
}
static int sem( unsigned int count, unsigned int max )
{
    struct ntsync_sem_args a = { count, max };
    return ioctl( PPSYNC_DEVICE_FD, NTSYNC_IOC_CREATE_SEM, &a );
}
static int mutex( unsigned int owner, unsigned int count )
{
    struct ntsync_mutex_args a = { owner, count };
    return ioctl( PPSYNC_DEVICE_FD, NTSYNC_IOC_CREATE_MUTEX, &a );
}
static unsigned int set( int fd ) { unsigned int prev = 99; CHECK( !ioctl( fd, NTSYNC_IOC_EVENT_SET, &prev ) ); return prev; }
static unsigned int reset( int fd ) { unsigned int prev = 99; CHECK( !ioctl( fd, NTSYNC_IOC_EVENT_RESET, &prev ) ); return prev; }
static unsigned int signaled( int fd )
{
    struct ntsync_event_args a;
    CHECK( !ioctl( fd, NTSYNC_IOC_EVENT_READ, &a ) );
    return a.signaled;
}
static unsigned int sem_count( int fd )
{
    struct ntsync_sem_args a;
    CHECK( !ioctl( fd, NTSYNC_IOC_SEM_READ, &a ) );
    return a.count;
}
static int release( int fd, unsigned int n ) { return ioctl( fd, NTSYNC_IOC_SEM_RELEASE, &n ); }
static int unlock( int fd, unsigned int owner )
{
    struct ntsync_mutex_args a = { owner, 0 };
    return ioctl( fd, NTSYNC_IOC_MUTEX_UNLOCK, &a );
}

/* Returns 0 / -1 as the ioctl, *index the index. timeout_ms < 0: forever. */
static int wait_objs( const int *fds, unsigned int count, int all, unsigned int owner, int alert,
                      int timeout_ms, unsigned int *index )
{
    struct ntsync_wait_args a = { 0 };
    int ret;
    a.timeout = timeout_ms < 0 ? ~(uint64_t)0 : in_ms( (unsigned int)timeout_ms );
    a.objs = (uintptr_t)fds;
    a.count = count;
    a.owner = owner;
    a.alert = (unsigned int)alert;
    a.index = ~0u;
    ret = ioctl( PPSYNC_DEVICE_FD, all ? NTSYNC_IOC_WAIT_ALL : NTSYNC_IOC_WAIT_ANY, &a );
    if (index) *index = a.index;
    return ret;
}
static int wait1( int fd, unsigned int owner, int timeout_ms )
{
    return wait_objs( &fd, 1, 0, owner, 0, timeout_ms, NULL );
}

static void test_events(void)
{
    int m = event( 1, 0 ), a = event( 0, 1 );
    unsigned int idx;

    CHECK( PPSYNC_IS_FD( m ) && PPSYNC_IS_FD( a ) );
    errno = 0; CHECK( wait1( m, 4, 0 ) == -1 && errno == ETIMEDOUT );
    CHECK( set( m ) == 0 );
    CHECK( set( m ) == 1 );
    CHECK( !wait1( m, 4, 0 ) && !wait1( m, 4, 0 ) );   /* manual: stays set */
    CHECK( reset( m ) == 1 && signaled( m ) == 0 );
    CHECK( !wait1( a, 4, 0 ) );                           /* auto: consumed */
    errno = 0; CHECK( wait1( a, 4, 0 ) == -1 && errno == ETIMEDOUT );
    { unsigned int prev; CHECK( !ioctl( a, NTSYNC_IOC_EVENT_PULSE, &prev ) && prev == 0 ); }
    CHECK( signaled( a ) == 0 );
    { int fds[2] = { a, m }; set( m ); CHECK( !wait_objs( fds, 2, 0, 4, 0, 0, &idx ) && idx == 1 ); }
    { int fds[2] = { a, m }; set( a ); CHECK( !wait_objs( fds, 2, 0, 4, 0, 0, &idx ) && idx == 0 ); }
    close( m ); close( a );
}

static void test_semaphores(void)
{
    int s = sem( 2, 3 );
    struct ntsync_sem_args bad = { 4, 3 };

    errno = 0; CHECK( ioctl( PPSYNC_DEVICE_FD, NTSYNC_IOC_CREATE_SEM, &bad ) == -1 && errno == EINVAL );
    CHECK( !wait1( s, 4, 0 ) && !wait1( s, 4, 0 ) );
    errno = 0; CHECK( wait1( s, 4, 0 ) == -1 && errno == ETIMEDOUT );
    { unsigned int n = 2; CHECK( !ioctl( s, NTSYNC_IOC_SEM_RELEASE, &n ) && n == 0 ); }
    errno = 0; CHECK( release( s, 2 ) == -1 && errno == EOVERFLOW );
    CHECK( sem_count( s ) == 2 );
    close( s );
}

static void test_mutexes(void)
{
    int mx = mutex( 8, 1 );
    struct ntsync_mutex_args r;
    unsigned int owner = 8, idx;

    errno = 0; CHECK( wait1( mx, 12, 0 ) == -1 && errno == ETIMEDOUT );   /* another owner */
    CHECK( !wait1( mx, 8, 0 ) );                                          /* recursive */
    errno = 0; CHECK( unlock( mx, 12 ) == -1 && errno == EPERM );
    CHECK( !unlock( mx, 8 ) );
    CHECK( !ioctl( mx, NTSYNC_IOC_MUTEX_READ, &r ) && r.owner == 8 && r.count == 1 );
    CHECK( !unlock( mx, 8 ) );
    CHECK( !wait1( mx, 12, 0 ) );
    owner = 12;
    CHECK( !ioctl( mx, NTSYNC_IOC_MUTEX_KILL, &owner ) );                 /* thread 12 died holding it */
    errno = 0; CHECK( ioctl( mx, NTSYNC_IOC_MUTEX_READ, &r ) == -1 && errno == EOWNERDEAD );
    { int fds[2] = { event( 0, 0 ), mx };
      errno = 0; CHECK( wait_objs( fds, 2, 0, 16, 0, 0, &idx ) == -1 && errno == EOWNERDEAD && idx == 1 );
      CHECK( !unlock( mx, 16 ) );
      CHECK( !wait1( mx, 16, 0 ) );                                       /* reported once */
      close( fds[0] ); }
    close( mx );
}

static void test_wait_all(void)
{
    int a = event( 0, 1 ), b = event( 0, 0 ), s = sem( 1, 1 ), al = event( 0, 0 );
    int fds[3] = { a, b, s };
    unsigned int idx = 0;

    errno = 0; CHECK( wait_objs( fds, 3, 1, 4, 0, 0, &idx ) == -1 && errno == ETIMEDOUT );
    CHECK( signaled( a ) == 1 && sem_count( s ) == 1 );                    /* nothing taken */
    set( b );
    CHECK( !wait_objs( fds, 3, 1, 4, 0, 0, &idx ) && idx == 0 );
    CHECK( signaled( a ) == 0 && signaled( b ) == 0 && sem_count( s ) == 0 );
    { int dup[2] = { a, a }; errno = 0; CHECK( wait_objs( dup, 2, 1, 4, 0, 0, &idx ) == -1 && errno == EINVAL ); }
    set( al );
    CHECK( !wait_objs( fds, 3, 1, 4, al, 0, &idx ) && idx == 3 );          /* the alert */
    set( al );
    CHECK( !wait_objs( fds, 2, 0, 4, al, 0, &idx ) && idx == 2 );
    close( a ); close( b ); close( s ); close( al );
}

static void test_timeouts(void)
{
    int e = event( 0, 0 );
    uint64_t t0 = mono_ns();
    struct ntsync_wait_args a = { 0 };
    struct timespec now;

    errno = 0; CHECK( wait1( e, 4, 30 ) == -1 && errno == ETIMEDOUT );
    CHECK( mono_ns() - t0 >= 29000000ull );
    clock_gettime( CLOCK_REALTIME, &now );
    a.timeout = (uint64_t)now.tv_sec * 1000000000ull + now.tv_nsec + 20000000ull;
    a.flags = NTSYNC_WAIT_REALTIME;
    a.objs = (uintptr_t)&e; a.count = 1; a.owner = 4;
    errno = 0; CHECK( ioctl( PPSYNC_DEVICE_FD, NTSYNC_IOC_WAIT_ANY, &a ) == -1 && errno == ETIMEDOUT );
    close( e );
}

/* ---- blocking waits, kicks and freezes ---------------------------------- */

struct waiter_arg { int fds[4]; unsigned int count, owner, all; int alert, timeout_ms;
                    int ret, err; unsigned int index; _Atomic int done; };

static void *waiter_main( void *p )
{
    struct waiter_arg *w = p;
    w->ret = wait_objs( w->fds, w->count, w->all, w->owner, w->alert, w->timeout_ms, &w->index );
    w->err = errno;
    atomic_store( &w->done, 1 );
    return NULL;
}

static pthread_t start_waiter( struct waiter_arg *w )
{
    pthread_t t;
    atomic_store( &w->done, 0 );
    pthread_create( &t, NULL, waiter_main, w );
    return t;
}

static unsigned long long slept(void)
{
    struct ppsync_stats s;
    ppsync_get_stats( &s );
    return s.blocked;
}

/* start a waiter and return once it is asleep in its wait */
static pthread_t start_blocked( struct waiter_arg *w )
{
    unsigned long long before = slept();
    uint64_t end = in_ms( 2000 );
    pthread_t t = start_waiter( w );
    while (slept() == before && mono_ns() < end) sleep_ms( 1 );
    CHECK( slept() > before );
    sleep_ms( 2 );
    return t;
}

static void test_blocking(void)
{
    struct waiter_arg w = { .count = 1, .owner = 0x100, .timeout_ms = -1 };
    pthread_t t;

    w.fds[0] = event( 0, 0 );
    t = start_blocked( &w );
    CHECK( !atomic_load( &w.done ) );
    set( w.fds[0] );
    pthread_join( t, NULL );
    CHECK( w.ret == 0 && w.index == 0 && signaled( w.fds[0] ) == 0 );

    /* a wait-all satisfied by the second of two releases */
    w.fds[1] = sem( 0, 4 ); w.count = 2; w.all = 1;
    t = start_blocked( &w );
    set( w.fds[0] );
    sleep_ms( 20 );
    CHECK( !atomic_load( &w.done ) && signaled( w.fds[0] ) == 1 );
    release( w.fds[1], 1 );
    pthread_join( t, NULL );
    CHECK( w.ret == 0 && signaled( w.fds[0] ) == 0 && sem_count( w.fds[1] ) == 0 );

    close( w.fds[0] ); close( w.fds[1] );

    /* closed while waited on: the wait keeps the object until it ends */
    w.count = 1; w.all = 0;
    w.fds[0] = event( 0, 0 );
    t = start_blocked( &w );
    close( w.fds[0] );
    set( w.fds[0] );
    pthread_join( t, NULL );
    CHECK( w.ret == 0 );
    errno = 0; CHECK( wait1( w.fds[0], 4, 0 ) == -1 && errno == EBADF );
}

static void test_kick(void)
{
    struct waiter_arg w = { .count = 1, .owner = 0x200, .timeout_ms = -1 };
    pthread_t t;

    w.fds[0] = event( 0, 0 );
    t = start_blocked( &w );
    ppsync_kick( 0x200 );
    pthread_join( t, NULL );
    CHECK( w.ret == -1 && w.err == ECANCELED );
    set( w.fds[0] );                                    /* nothing was consumed, nothing is linked */
    CHECK( signaled( w.fds[0] ) == 1 );
    CHECK( !wait1( w.fds[0], 0x200, 0 ) );              /* the kick was taken once */

    ppsync_kick( 0x200 );                                /* a kick while not waiting is remembered */
    set( w.fds[0] );
    errno = 0; CHECK( wait1( w.fds[0], 0x200, 0 ) == -1 && errno == ECANCELED );
    CHECK( signaled( w.fds[0] ) == 1 );
    CHECK( !wait1( w.fds[0], 0x200, 0 ) );

    /* a kick does not end an unrelated thread's wait */
    w.owner = 0x204;
    t = start_blocked( &w );
    ppsync_kick( 0x208 );
    sleep_ms( 20 );
    CHECK( !atomic_load( &w.done ) );
    set( w.fds[0] );
    pthread_join( t, NULL );
    CHECK( w.ret == 0 );
    close( w.fds[0] );
}

static void test_freeze(void)
{
    struct waiter_arg w = { .count = 1, .owner = 0x300, .timeout_ms = -1 };
    pthread_t t;

    w.fds[0] = event( 0, 0 );
    t = start_blocked( &w );
    ppsync_freeze( 0x300, 1 );
    set( w.fds[0] );
    sleep_ms( 30 );
    CHECK( !atomic_load( &w.done ) );                   /* a suspended thread's wait is not satisfied */
    CHECK( signaled( w.fds[0] ) == 1 );                  /* and takes nothing */
    ppsync_freeze( 0x300, 0 );
    pthread_join( t, NULL );
    CHECK( w.ret == 0 && signaled( w.fds[0] ) == 0 );

    /* frozen before it waits: it does not start */
    ppsync_freeze( 0x300, 1 );
    set( w.fds[0] );
    t = start_waiter( &w );
    sleep_ms( 30 );
    CHECK( !atomic_load( &w.done ) && signaled( w.fds[0] ) == 1 );
    ppsync_freeze( 0x300, 0 );
    pthread_join( t, NULL );
    CHECK( w.ret == 0 && signaled( w.fds[0] ) == 0 );

    /* a timeout while frozen is reported after the thaw */
    w.timeout_ms = 10;
    ppsync_freeze( 0x300, 1 );
    t = start_waiter( &w );
    sleep_ms( 40 );
    CHECK( !atomic_load( &w.done ) );
    ppsync_freeze( 0x300, 0 );
    pthread_join( t, NULL );
    CHECK( w.ret == -1 && w.err == ETIMEDOUT );

    /* a frozen wait-all, thawed */
    w.timeout_ms = -1; w.count = 2; w.all = 1;
    w.fds[1] = event( 0, 0 );
    t = start_blocked( &w );
    ppsync_freeze( 0x300, 1 );
    set( w.fds[0] ); set( w.fds[1] );
    sleep_ms( 20 );
    CHECK( !atomic_load( &w.done ) && signaled( w.fds[0] ) && signaled( w.fds[1] ) );
    ppsync_freeze( 0x300, 0 );
    pthread_join( t, NULL );
    CHECK( w.ret == 0 && !signaled( w.fds[0] ) && !signaled( w.fds[1] ) );

    /* a kick reaches a thread held frozen at the start of a wait */
    ppsync_freeze( 0x300, 1 );
    t = start_waiter( &w );
    sleep_ms( 20 );
    CHECK( !atomic_load( &w.done ) );
    ppsync_kick( 0x300 );
    pthread_join( t, NULL );
    CHECK( w.ret == -1 && w.err == ECANCELED );
    ppsync_freeze( 0x300, 0 );

    /* gone: a frozen waiter is thawed and kicked */
    w.count = 1; w.all = 0;
    t = start_blocked( &w );
    ppsync_freeze( 0x300, 1 );
    sleep_ms( 10 );
    ppsync_thread_gone( 0x300 );
    pthread_join( t, NULL );
    CHECK( w.ret == -1 && w.err == ECANCELED );
    close( w.fds[0] ); close( w.fds[1] );
}

static void test_handoff(void)
{
    int e = event( 0, 1 ), fd;
    ppsync_post( 0x30, 0x44, e );
    CHECK( ppsync_take( 0x30, 0x48 ) == -1 );
    fd = ppsync_take( 0x30, 0x44 );
    CHECK( fd == e );
    CHECK( ppsync_take( 0x30, 0x44 ) == -1 );
    close( e );                       /* the creator's reference */
    CHECK( !wait1( fd, 4, 0 ) );      /* the posted one still holds it */
    close( fd );
    errno = 0; CHECK( wait1( fd, 4, 0 ) == -1 && errno == EBADF );
}

static unsigned long long live(void)
{
    struct ppsync_stats s;
    ppsync_get_stats( &s );
    return s.live_objects;
}

/* Posts nobody takes do not fill the table: a repost of the same handle
 * replaces the old one, a full table drops its oldest, and each dropped post
 * gives its reference back. */
static void test_handoff_leaks(void)
{
    unsigned long long before = live();
    int e = event( 0, 1 ), f = event( 0, 0 ), fd, i;

    ppsync_post( 0x34, 0x10, e );
    ppsync_post( 0x34, 0x10, f );               /* the same handle again: replaces */
    CHECK( ppsync_take( 0x34, 0x10 ) == f );
    CHECK( ppsync_take( 0x34, 0x10 ) == -1 );
    close( f );                                 /* the take's reference */

    for (i = 0; i < 3000; i++) ppsync_post( 0x38, 0x1000 + 4 * i, e );   /* never taken */
    ppsync_post( 0x38, 0x8, e );
    fd = ppsync_take( 0x38, 0x8 );              /* the newest still gets through */
    CHECK( fd == e );
    close( fd );
    CHECK( ppsync_take( 0x38, 0x1000 ) == -1 );  /* the oldest went */
    for (i = 3000 - 1024 + 1; i < 3000; i++)    /* take the rest, so each reference returns */
        if ((fd = ppsync_take( 0x38, 0x1000 + 4 * i )) == e) close( fd );
    close( f );
    close( e );
    CHECK( live() == before );
}

/* ---- stress ---------------------------------------------------------------
 * Workers share a mutex guarding a plain counter, a pair of semaphores whose
 * tokens move only through wait-all (so their counts stay equal), an
 * auto-reset event handed around, and are kicked and frozen at random. */

#define WORKERS 8
#define ROUNDS  4000

static int g_mx, g_s1, g_s2, g_ev, g_tok;
static long g_counter;
static _Atomic long g_ev_takes, g_ev_sets, g_tok_taken, g_tok_given;
static _Atomic int g_stop;

static void *stress_main( void *p )
{
    unsigned int owner = (unsigned int)(uintptr_t)p;
    unsigned int seed = owner, i;

    for (i = 0; i < ROUNDS; i++)
    {
        unsigned int r = rand_r( &seed ) % 5, idx;
        int ret;
        switch (r)
        {
        case 0:   /* mutex: plain counter */
            while ((ret = wait1( g_mx, owner, -1 )) && errno == ECANCELED) ;
            CHECK( !ret );
            g_counter++;
            CHECK( !unlock( g_mx, owner ) );
            break;
        case 1:   /* the pair moves together */
        {
            int fds[2] = { g_s1, g_s2 };
            ret = wait_objs( fds, 2, 1, owner, 0, 2, &idx );
            if (!ret) { CHECK( !release( g_s1, 1 ) ); CHECK( !release( g_s2, 1 ) ); }
            else CHECK( errno == ETIMEDOUT || errno == ECANCELED );
            break;
        }
        case 2:   /* the event: any of tok or ev */
        {
            int fds[2] = { g_tok, g_ev };
            ret = wait_objs( fds, 2, 0, owner, 0, 1, &idx );
            if (!ret && idx == 0) { atomic_fetch_add( &g_tok_taken, 1 ); release( g_tok, 1 ); atomic_fetch_add( &g_tok_given, 1 ); }
            else if (!ret) atomic_fetch_add( &g_ev_takes, 1 );
            break;
        }
        case 3: { unsigned int prev; ioctl( g_ev, NTSYNC_IOC_EVENT_SET, &prev ); if (!prev) atomic_fetch_add( &g_ev_sets, 1 ); break; }
        case 4:   /* poke another worker */
        {
            unsigned int other = 0x1000 + 4 * (rand_r( &seed ) % WORKERS);
            if (rand_r( &seed ) & 1) ppsync_kick( other );
            else { ppsync_freeze( other, 1 ); ppsync_freeze( other, 0 ); }
            break;
        }
        }
    }
    return NULL;
}

static void test_stress(void)
{
    pthread_t t[WORKERS];
    int i;
    unsigned int left;

    g_mx = mutex( 0, 0 ); g_s1 = sem( 3, 3 ); g_s2 = sem( 3, 3 ); g_ev = event( 0, 0 ); g_tok = sem( 2, 2 );
    for (i = 0; i < WORKERS; i++) pthread_create( &t[i], NULL, stress_main, (void *)(uintptr_t)(0x1000 + 4 * i) );
    for (i = 0; i < WORKERS; i++) pthread_join( t[i], NULL );
    (void)g_stop;
    CHECK( sem_count( g_s1 ) == 3 && sem_count( g_s2 ) == 3 );
    CHECK( sem_count( g_tok ) == 2 );
    left = signaled( g_ev );
    CHECK( atomic_load( &g_ev_takes ) + left == atomic_load( &g_ev_sets ) );
    { struct ntsync_mutex_args r; CHECK( !ioctl( g_mx, NTSYNC_IOC_MUTEX_READ, &r ) && r.owner == 0 && r.count == 0 ); }
    {
        long expect = 0;
        unsigned int w;
        for (w = 0; w < WORKERS; w++)
        {
            unsigned int seed = 0x1000 + 4 * w, k;
            for (k = 0; k < ROUNDS; k++)
            {
                unsigned int r = rand_r( &seed ) % 5;
                if (r == 0) expect++;
                if (r == 4) { rand_r( &seed ); rand_r( &seed ); }
            }
        }
        CHECK( g_counter == expect );
    }
    close( g_mx ); close( g_s1 ); close( g_s2 ); close( g_ev ); close( g_tok );
}

/* Two threads hand a token back and forth through two auto-reset events: a
 * lost wake shows as a timed-out hand. */
#define PINGS 20000
static int g_ping, g_pong;
static _Atomic int g_ping_lost;

static void *pong_main( void *p )
{
    int i;
    (void)p;
    for (i = 0; i < PINGS; i++)
    {
        if (wait1( g_ping, 0x2004, 2000 )) { atomic_fetch_add( &g_ping_lost, 1 ); break; }
        set( g_pong );
    }
    return NULL;
}

static void test_ping_pong(void)
{
    pthread_t t;
    int i;
    g_ping = event( 0, 0 ); g_pong = event( 0, 0 );
    pthread_create( &t, NULL, pong_main, NULL );
    for (i = 0; i < PINGS && !atomic_load( &g_ping_lost ); i++)
    {
        set( g_ping );
        if (wait1( g_pong, 0x2008, 2000 )) { atomic_fetch_add( &g_ping_lost, 1 ); set( g_ping ); break; }
    }
    pthread_join( t, NULL );
    CHECK( !atomic_load( &g_ping_lost ) );
    close( g_ping ); close( g_pong );
}

/* A waiter takes an auto-reset event over and over, with infinite waits,
 * while another thread freezes and thaws it as fast as it can: a thaw the
 * waiter misses leaves it asleep on a set event. */
#define STORM 3000
static int g_storm_ev, g_storm_ack;
static _Atomic int g_storm_done, g_storm_stuck;

static void *storm_waiter( void *p )
{
    int i;
    (void)p;
    for (i = 0; i < STORM; i++)
    {
        int ret;
        while ((ret = wait1( g_storm_ev, 0x3004, 3000 )) && errno == ECANCELED) ;
        if (ret) { atomic_fetch_add( &g_storm_stuck, 1 ); break; }
        set( g_storm_ack );
    }
    atomic_store( &g_storm_done, 1 );
    return NULL;
}

static void *storm_poker( void *p )
{
    (void)p;
    while (!atomic_load( &g_storm_done )) { ppsync_freeze( 0x3004, 1 ); ppsync_freeze( 0x3004, 0 ); }
    return NULL;
}

static void test_freeze_storm(void)
{
    pthread_t w, k;
    int i;
    g_storm_ev = event( 0, 0 ); g_storm_ack = event( 0, 0 );
    pthread_create( &w, NULL, storm_waiter, NULL );
    pthread_create( &k, NULL, storm_poker, NULL );
    for (i = 0; i < STORM && !atomic_load( &g_storm_done ); i++)
    {
        set( g_storm_ev );
        while (wait1( g_storm_ack, 0x3008, 100 ) && !atomic_load( &g_storm_done )) ;
    }
    pthread_join( w, NULL );
    pthread_join( k, NULL );
    ppsync_freeze( 0x3004, 0 );
    CHECK( !atomic_load( &g_storm_stuck ) );
    close( g_storm_ev ); close( g_storm_ack );
}

int main(void)
{
    struct ppsync_stats s;

    test_events();
    test_semaphores();
    test_mutexes();
    test_wait_all();
    test_timeouts();
    test_blocking();
    test_kick();
    test_freeze();
    test_handoff();
    test_handoff_leaks();
    test_stress();
    test_ping_pong();
    test_freeze_storm();
    ppsync_get_stats( &s );
    printf( "ppsync: %llu waits, %llu slept, %llu polls, %llu wakes, %llu kicks, %llu frozen, %llu live objects\n",
            s.waits, s.blocked, s.polls, s.wakes, s.cancels, s.frozen_waits, s.live_objects );
    CHECK( s.live_objects == 0 );
    if (failures) { fprintf( stderr, "%d failure(s)\n", failures ); return 1; }
    puts( "ppsync tests passed" );
    return 0;
}
