/* The Mach handler's window lookup and teardown's wait for it (madeira-unix
 * 0073, wow64_threads.h), compiled from the patch, against real mappings that
 * teardown unmaps and a slot another owner reuses.
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

typedef int BOOL;
#define TRUE 1
#define FALSE 0
#define IOS_WOW64_WINDOWS_MAX 64
static struct
{
    void *owner;
    uintptr_t base;
    BOOL retiring;
    unsigned int threads;
} ios_wow64_windows[IOS_WOW64_WINDOWS_MAX];
static pthread_mutex_t ios_wow64_windows_lock = PTHREAD_MUTEX_INITIALIZER;
struct thread_data;
static void virtual_free_thread_data( struct thread_data *data ) { (void)data; assert( 0 ); }

#include "wow64_threads.h"

static int owner_a, owner_b, owner_c;
static const uintptr_t base_a = 0x7038010000;
static volatile int stop;
static unsigned long pinned_reads, foreign;

/* Reservation: base, then owner (release). */
static void publish( unsigned int slot, void *owner, uintptr_t base )
{
    ios_wow64_windows[slot].base = base;
    __atomic_store_n( &ios_wow64_windows[slot].owner, owner, __ATOMIC_RELEASE );
}

static uintptr_t map_window(void)
{
    void *p = mmap( NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0 );
    assert( p != MAP_FAILED );
    *(volatile uint32_t *)p = 0x57303634;
    return (uintptr_t)p;
}

/* The production order: unpublish (owner cleared, lookups drained), then the
 * views go and the slot is free; the next reservation reuses it for another
 * owner at another base. A reader holding a stale base would read unmapped
 * memory (SIGSEGV) or see the other owner's base. */
static void *churn( void *arg )
{
    unsigned long n = 0;
    (void)arg;
    while (!stop)
    {
        void *owner = (n & 1) ? &owner_c : &owner_b;
        uintptr_t base = map_window();
        pthread_mutex_lock( &ios_wow64_windows_lock );
        publish( 5, owner, base );
        pthread_mutex_unlock( &ios_wow64_windows_lock );
        sched_yield();
        pthread_mutex_lock( &ios_wow64_windows_lock );
        ios_wow64_windows[5].retiring = TRUE;
        assert( ios_wow64_window_unpublish( 5 ) == base );
        assert( !munmap( (void *)base, 0x4000 ) );
        ios_wow64_windows[5].base = 0;
        ios_wow64_windows[5].retiring = FALSE;
        pthread_mutex_unlock( &ios_wow64_windows_lock );
        n++;
    }
    return NULL;
}

static void *reader( void *arg )
{
    void *owner = arg;
    while (!stop)
    {
        uintptr_t got = ios_wow64_fault_enter( owner );
        unsigned int spin;
        if (!got) continue;
        /* pinned: still mapped, still this owner's slot */
        for (spin = 0; spin < 2048; spin++)
        {
            assert( *(volatile uint32_t *)got == 0x57303634 );
            if (!(spin & 255)) sched_yield();
        }
        /* teardown may have cleared the owner and be waiting for this reader,
         * but the slot keeps this base and is not another owner's */
        {
            void *now = __atomic_load_n( &ios_wow64_windows[5].owner, __ATOMIC_RELAXED );
            if (__atomic_load_n( &ios_wow64_windows[5].base, __ATOMIC_RELAXED ) != got ||
                (now && now != owner))
                __atomic_add_fetch( &foreign, 1, __ATOMIC_RELAXED );
        }
        __atomic_add_fetch( &pinned_reads, 1, __ATOMIC_RELAXED );
        ios_wow64_fault_leave();
    }
    return NULL;
}

int main(void)
{
    pthread_t churner, readers[3];
    unsigned long i;

    assert( !ios_wow64_fault_enter( NULL ) );
    assert( !ios_wow64_fault_enter( &owner_a ) && !ios_wow64_fault_readers );
    publish( 3, &owner_a, base_a );
    assert( ios_wow64_fault_enter( &owner_a ) == base_a && ios_wow64_fault_readers == 1 );
    ios_wow64_fault_leave();
    assert( !ios_wow64_fault_enter( &owner_c ) && !ios_wow64_fault_readers );

    /* The window's slot is not free (owner set) until unpublish, which drops
     * this window's spare records and no other's. */
    ios_wow64_threads[0].window = base_a;
    ios_wow64_threads[0].state = IOS_WOW64_THREAD_SPARE;
    ios_wow64_threads[1].window = base_a + 0x100000000ull;
    ios_wow64_threads[1].state = IOS_WOW64_THREAD_SPARE;
    ios_wow64_windows[3].retiring = TRUE;
    assert( ios_wow64_window_unpublish( 3 ) == base_a );
    assert( !ios_wow64_windows[3].owner && !ios_wow64_fault_enter( &owner_a ) );
    assert( !ios_wow64_threads[0].state && ios_wow64_threads[1].state == IOS_WOW64_THREAD_SPARE );
    memset( ios_wow64_threads, 0, sizeof(ios_wow64_threads) );
    ios_wow64_windows[3].base = 0;
    ios_wow64_windows[3].retiring = FALSE;

    /* Readers race unpublish, unmap and reuse by another owner at another base. */
    publish( 3, &owner_a, base_a );
    assert( !pthread_create( &churner, NULL, churn, NULL ) );
    assert( !pthread_create( &readers[0], NULL, reader, &owner_b ) );
    assert( !pthread_create( &readers[1], NULL, reader, &owner_c ) );
    assert( !pthread_create( &readers[2], NULL, reader, &owner_b ) );
    for (i = 0; i < 2000000; i++)
    {
        assert( ios_wow64_fault_enter( &owner_a ) == base_a );
        ios_wow64_fault_leave();
    }
    stop = 1;
    pthread_join( churner, NULL );
    for (i = 0; i < 3; i++) pthread_join( readers[i], NULL );
    assert( !foreign && !ios_wow64_fault_readers );
    printf( "wow64 fault-window lookup: pinned bases stay mapped and owned across teardown and reuse "
            "(%lu pinned reads)\n", pinned_reads );
    return 0;
}
