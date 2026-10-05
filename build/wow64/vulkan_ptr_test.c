/* SPDX-License-Identifier: GPL-3.0-or-later */
/* winevulkan's WoW64 pointer conversions (wine-unix 0011's vulkan_private.h),
 * with a mock TEB/TEB32 pair laid out as madeira-unix 0052 lays it out. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef unsigned long ULONG_PTR;
typedef uint32_t ULONG;
typedef uint64_t UINT64;
typedef struct { ULONG ExceptionList, StackBase, StackLimit, SubSystemTib, FiberData, ArbitraryUserPointer, Self; } NT_TIB32;
typedef struct { NT_TIB32 Tib; } TEB32;
typedef struct { ULONG_PTR WowTebOffset; } TEB;

static TEB *current_teb;
static TEB *NtCurrentTeb(void) { return current_teb; }

static int rejected;
static ULONG vulkan_wow64_rejected(const void *host, ULONG_PTR base)
{
    (void)host; (void)base;
    rejected++;
    return 0;
}

#include "vulkan_api.h"

int main(void)
{
    /* a TEB at guest 0x7fe00000 and its TEB32 0x2000 above; two pages stand
     * in for the window, and base is what the pair implies */
    static _Alignas(16) char pages[0x4000];
    const ULONG guest_teb32 = 0x7fe02000;
    TEB *teb = (TEB *)pages;
    TEB32 *teb32 = (TEB32 *)(pages + 0x2000);
    ULONG_PTR base = (ULONG_PTR)teb32 - guest_teb32;
    static const ULONG edges[] = {1, 0x10000, 0x400000, 0x7bf40000, 0x7fffffff, 0x80000000, 0xffffffff};

    teb->WowTebOffset = 0x2000;
    teb32->Tib.Self = guest_teb32;
    current_teb = teb;
    assert( vulkan_wow64_window_base() == base );
    assert( vulkan_wow64_to_host( 0 ) == NULL );
    assert( vulkan_wow64_to_guest( NULL ) == 0 );
    for (unsigned int i = 0; i < sizeof(edges) / sizeof(edges[0]); i++)
    {
        void *host = vulkan_wow64_to_host( edges[i] );
        assert( (ULONG_PTR)host == base + edges[i] );
        assert( vulkan_wow64_to_guest( host ) == edges[i] );
        assert( vulkan_wow64_client_handle( edges[i] ) == base + edges[i] );
    }
    /* outside the window: 0 and a report, never a truncated pointer */
    assert( vulkan_wow64_to_guest( (void *)(base - 1) ) == 0 && rejected == 1 );
    assert( vulkan_wow64_to_guest( (void *)(base + UINT64_C(0x100000000)) ) == 0 && rejected == 2 );
    /* a 64-bit handle value or NULL is not a guest pointer */
    assert( vulkan_wow64_client_handle( 0 ) == 0 );
    assert( vulkan_wow64_client_handle( UINT64_C(0x7100004000) ) == UINT64_C(0x7100004000) );

    /* a thread without a TEB32 (the x86-64 session): identity */
    teb->WowTebOffset = 0;
    assert( vulkan_wow64_window_base() == 0 );
    assert( (ULONG_PTR)vulkan_wow64_to_host( 0x400000 ) == 0x400000 );
    assert( vulkan_wow64_to_guest( (void *)0x400000 ) == 0x400000 );
    assert( vulkan_wow64_client_handle( 0x400000 ) == 0x400000 );
    assert( rejected == 2 );
    printf( "winevulkan guest window: base from the TEB pair, round trips, rejection, client handles, no TEB32\n" );
    return EXIT_SUCCESS;
}
