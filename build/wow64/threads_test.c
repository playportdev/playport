/* A WoW64 window's secondary threads (madeira-unix 0073, wow64_threads.h),
 * compiled from the patch, with real pthreads: the owner's release only
 * retires the window while threads still run on their TEB pairs in it, the
 * window goes when its last thread has been joined, joins form no cycle, and
 * a reclaimed pair is the next thread's.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

typedef int BOOL;
#define TRUE 1
#define FALSE 0
#define IOS_WOW64_WINDOWS_MAX 4
static struct
{
    void *owner;
    uintptr_t base;
    BOOL retiring;
    unsigned int threads;
} ios_wow64_windows[IOS_WOW64_WINDOWS_MAX];
static pthread_mutex_t ios_wow64_windows_lock = PTHREAD_MUTEX_INITIALIZER;
struct thread_data { unsigned int id; volatile int exited, freed; pthread_t self; };
static void virtual_free_thread_data( struct thread_data *data );

#include "wow64_threads.h"

#define WORKERS 48
#define PAIR 0x1000
static struct thread_data workers[WORKERS + 4];
static int owner;
static unsigned int teardowns, exited_at_teardown;
static volatile unsigned int exited;
static uintptr_t torn_base, mapping[IOS_WOW64_WINDOWS_MAX];

/* ios_wow64_teardown_window's order: unpublish, then the views go (here the
 * whole window is unmapped: a thread still using its pair would fault). */
static void teardown( unsigned int slot )
{
    uintptr_t base = ios_wow64_window_unpublish( slot );
    exited_at_teardown = exited;
    assert( !munmap( (void *)mapping[slot], (WORKERS + 4) * PAIR ) );
    ios_wow64_windows[slot].base = 0;
    ios_wow64_windows[slot].retiring = FALSE;
    torn_base = base;
    teardowns++;
}

/* virtual_free_thread_data -> ios_wow64_free_teb's record handling */
static void virtual_free_thread_data( struct thread_data *data )
{
    int entry, slot;
    pthread_mutex_lock( &ios_wow64_windows_lock );
    entry = ios_wow64_thread_find( data );
    assert( entry >= 0 );
    assert( ios_wow64_threads[entry].state == IOS_WOW64_THREAD_JOINING ||
            ios_wow64_threads[entry].state == IOS_WOW64_THREAD_LIVE );
    assert( !data->self || !pthread_equal( data->self, pthread_self() ) );  /* never itself */
    data->freed = 1;
    if ((slot = ios_wow64_thread_reclaimed( entry )) >= 0) teardown( slot );
    pthread_mutex_unlock( &ios_wow64_windows_lock );
}

static int add_thread( unsigned int slot, struct thread_data *data, uint32_t *pair )
{
    int entry;
    pthread_mutex_lock( &ios_wow64_windows_lock );
    if ((entry = ios_wow64_thread_entry( slot, pair )) >= 0)
    {
        if (!*pair) *pair = 0x10000 + (uint32_t)entry * PAIR;  /* a new pair */
        ios_wow64_thread_commit( slot, entry, data, *pair );
    }
    pthread_mutex_unlock( &ios_wow64_windows_lock );
    return entry;
}

/* A thread running on its TEB pair until it exits (pthread_exit_wrapper). */
static void *worker( void *arg )
{
    struct thread_data *data = arg;
    volatile uint32_t *teb;
    unsigned int i, rounds = 2000 + (data->id * 7919) % 20000;

    data->self = pthread_self();
    pthread_mutex_lock( &ios_wow64_windows_lock );
    teb = (volatile uint32_t *)(ios_wow64_windows[0].base +
                                ios_wow64_threads[ios_wow64_thread_find( data )].pair);
    pthread_mutex_unlock( &ios_wow64_windows_lock );
    for (i = 0; i < rounds; i++)
    {
        teb[i % (PAIR / 4)] = data->id;
        if (!(i % 512)) sched_yield();
    }
    __atomic_add_fetch( &exited, 1, __ATOMIC_SEQ_CST );
    data->exited = 1;
    ios_wow64_thread_exit( data );
    return NULL;
}

int main(void)
{
    pthread_t threads[WORKERS];
    uintptr_t base;
    uint32_t pair, first_pair;
    unsigned int i;
    int entry;

    alarm( 120 );  /* a join cycle would hang */
    base = (uintptr_t)mmap( NULL, (WORKERS + 4) * PAIR, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0 );
    assert( (void *)base != MAP_FAILED );
    mapping[0] = base;
    base -= 0x10000;  /* guest 0x10000 is the first pair */
    ios_wow64_windows[0].base = base;
    ios_wow64_windows[0].owner = &owner;
    for (i = 0; i < WORKERS + 4; i++) workers[i].id = i + 1;

    /* A thread that never started is reclaimed directly; its pair is the
     * next thread's spare. */
    assert( add_thread( 0, &workers[WORKERS], &first_pair ) >= 0 && first_pair == 0x10000 );
    assert( ios_wow64_windows[0].threads == 1 && ios_wow64_is_window_thread( &workers[WORKERS] ) );
    virtual_free_thread_data( &workers[WORKERS] );
    assert( !ios_wow64_windows[0].threads && !ios_wow64_is_window_thread( &workers[WORKERS] ) );
    assert( ios_wow64_threads[0].state == IOS_WOW64_THREAD_SPARE );

    /* Threads exit while the owner releases: the window stays until the last
     * is joined, whoever joins it. */
    for (i = 0; i < WORKERS; i++)
    {
        entry = add_thread( 0, &workers[i], &pair );
        assert( entry >= 0 && (i || pair == first_pair) );
        assert( !pthread_create( &threads[i], NULL, worker, &workers[i] ) );
    }
    while (exited < WORKERS / 4) sched_yield();
    pthread_mutex_lock( &ios_wow64_windows_lock );
    assert( !ios_wow64_window_retire( 0 ) );  /* threads left: retired only */
    assert( ios_wow64_thread_entry( 0, &pair ) < 0 );  /* no new thread */
    pthread_mutex_unlock( &ios_wow64_windows_lock );
    assert( !teardowns && ios_wow64_fault_enter( &owner ) == base );
    ios_wow64_fault_leave();
    while (exited < WORKERS) sched_yield();
    /* The last exited thread is joined by the next reaper (a creation, a
     * release or another exit); none of them joins itself. */
    while (!teardowns)
    {
        ios_wow64_reap_threads( NULL );
        sched_yield();
    }
    assert( teardowns == 1 && exited_at_teardown == WORKERS && torn_base == base );
    for (i = 0; i < WORKERS; i++) assert( workers[i].exited && workers[i].freed );
    for (i = 0; i < IOS_WOW64_THREADS_MAX; i++) assert( !ios_wow64_threads[i].state );
    assert( !ios_wow64_windows[0].owner && !ios_wow64_fault_enter( &owner ) );
    assert( ios_wow64_threads_created == WORKERS + 1 && ios_wow64_threads_reclaimed == WORKERS + 1 );

    /* A window with no thread left is torn down by its release. */
    teardowns = 0;
    base = (uintptr_t)mmap( NULL, (WORKERS + 4) * PAIR, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0 );
    assert( (void *)base != MAP_FAILED );
    mapping[1] = base;
    ios_wow64_windows[1].base = base;
    ios_wow64_windows[1].owner = &owner;
    pthread_mutex_lock( &ios_wow64_windows_lock );
    if (ios_wow64_window_retire( 1 )) teardown( 1 );
    pthread_mutex_unlock( &ios_wow64_windows_lock );
    assert( teardowns == 1 && !ios_wow64_windows[1].owner );
    printf( "wow64 window threads: retired until the last of %d threads is joined, no join cycle, "
            "spare pairs reused\n", WORKERS );
    return 0;
}
