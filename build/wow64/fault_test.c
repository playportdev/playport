/* The Mach handler's lock-free window lookup (madeira-unix 0062), compiled
 * from the patch, against the publication order reservation and release use.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

#define IOS_WOW64_WINDOWS_MAX 64
static struct
{
    void *owner;
    uintptr_t base;
} ios_wow64_windows[IOS_WOW64_WINDOWS_MAX];

#include "fault_api.h"

static int owner_a, owner_b, owner_c;
static const uintptr_t base_a = 0x7038010000, base_b = 0x7138010000;
static volatile int stop;

/* Reservation: base, then owner (release); release: owner first, then base. */
static void publish( unsigned int slot, void *owner, uintptr_t base )
{
    ios_wow64_windows[slot].base = base;
    __atomic_store_n( &ios_wow64_windows[slot].owner, owner, __ATOMIC_RELEASE );
}

static void retire( unsigned int slot )
{
    __atomic_store_n( &ios_wow64_windows[slot].owner, NULL, __ATOMIC_RELEASE );
    ios_wow64_windows[slot].base = 0;
}

static void *churn( void *arg )
{
    (void)arg;
    while (!stop)
    {
        publish( 5, &owner_b, base_b );
        retire( 5 );
    }
    return NULL;
}

int main(void)
{
    pthread_t thread;
    unsigned long i;

    assert( !ios_wow64_fault_base_for_peb( NULL ) );
    assert( !ios_wow64_fault_base_for_peb( &owner_a ) );
    publish( 3, &owner_a, base_a );
    assert( ios_wow64_fault_base_for_peb( &owner_a ) == base_a );
    assert( !ios_wow64_fault_base_for_peb( &owner_c ) );
    publish( 0, &owner_c, base_b );
    assert( ios_wow64_fault_base_for_peb( &owner_c ) == base_b );
    assert( ios_wow64_fault_base_for_peb( &owner_a ) == base_a );
    retire( 0 );
    assert( !ios_wow64_fault_base_for_peb( &owner_c ) );
    assert( ios_wow64_fault_base_for_peb( &owner_a ) == base_a );

    /* A reader racing another owner's publication and release sees that
     * owner's base or nothing, never a stale or foreign base; a third
     * owner's window is unaffected. */
    assert( !pthread_create( &thread, NULL, churn, NULL ) );
    for (i = 0; i < 2000000; i++)
    {
        uintptr_t got = ios_wow64_fault_base_for_peb( &owner_b );
        assert( !got || got == base_b );
        assert( ios_wow64_fault_base_for_peb( &owner_a ) == base_a );
    }
    stop = 1;
    pthread_join( thread, NULL );
    retire( 3 );
    assert( !ios_wow64_fault_base_for_peb( &owner_a ) );
    printf( "wow64 fault-window lookup: publication order, owners and races ok\n" );
    return 0;
}
