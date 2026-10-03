/* SPDX-License-Identifier: GPL-3.0-or-later */
/* wow64.dll's guest-window conversions (wine-pe 0016's wow64_window.h). */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "wow64_window.h"

static const uint32_t edges[] = {0, 1, 0xffff, 0x10000, 0x400000, 0x7bf40000,
                                 0x7fe02000, 0x7fffffff, 0x80000000, 0xfffffffe, 0xffffffff};

static void test_window( uint64_t base )
{
    uint32_t out;

    assert( wow64_window_valid_base( base ) );
    for (unsigned int i = 0; i < sizeof(edges) / sizeof(edges[0]); i++)
    {
        void *host = wow64_window_to_host( base, edges[i] );
        assert( (uintptr_t)host == (edges[i] ? base + edges[i] : 0) );
        out = 0xdeadbeef;
        assert( wow64_window_to_guest( base, host, &out ) && out == edges[i] );
    }
    /* Out of the window: rejected, never truncated, output untouched. The
     * window's first byte is not the NULL sentinel. */
    const uint64_t bad[] = {1, 0xffffffff, base - 1, base, base + WOW64_WINDOW_SIZE,
                            base + WOW64_WINDOW_SIZE + 0x400000, base - WOW64_WINDOW_SIZE + 0x400000,
                            UINT64_MAX};
    for (unsigned int i = 0; i < sizeof(bad) / sizeof(bad[0]); i++)
    {
        out = 0xdeadbeef;
        assert( !wow64_window_to_guest( base, (void *)(uintptr_t)bad[i], &out ) );
        assert( out == 0xdeadbeef );
    }
    uint32_t guest = 0x9e3779b9;
    for (unsigned int i = 0; i < 200000; i++)
    {
        guest = guest * 1664525u + 1013904223u;
        assert( wow64_window_to_guest( base, wow64_window_to_host( base, guest ), &out ) );
        assert( out == guest );
    }
}

int main(void)
{
    const uint64_t a = UINT64_C(0x7038010000), b = UINT64_C(0x7100000000);
    uint32_t out;

    test_window( a );
    test_window( b );
    out = 0xdeadbeef;
    assert( !wow64_window_to_guest( b, wow64_window_to_host( a, 0x400000 ), &out ) && out == 0xdeadbeef );

    /* Base 0, no window: the identity below 4 GiB, higher pointers rejected. */
    for (unsigned int i = 0; i < sizeof(edges) / sizeof(edges[0]); i++)
    {
        assert( (uintptr_t)wow64_window_to_host( 0, edges[i] ) == edges[i] );
        assert( wow64_window_to_guest( 0, (void *)(uintptr_t)edges[i], &out ) && out == edges[i] );
    }
    out = 0xdeadbeef;
    assert( !wow64_window_to_guest( 0, (void *)(uintptr_t)a, &out ) && out == 0xdeadbeef );

    /* The base named by the TEB32/PEB32 pair (Portal 2's phone layout). */
    assert( wow64_window_base_from_pair( a + 0x7fe02000, 0x7fe02000, a + 0x7ff00000, 0x7ff00000 ) == a );
    assert( !wow64_window_base_from_pair( a + 0x7fe02000, 0x7fe02000, b + 0x7ff00000, 0x7ff00000 ) );
    assert( !wow64_window_base_from_pair( a + 0x7fe02000, 0, a + 0x7ff00000, 0x7ff00000 ) );
    assert( !wow64_window_base_from_pair( a + 0x7fe02000, 0x7fe02000, a, 0 ) );
    /* identity layouts, misaligned and low bases name no window */
    assert( !wow64_window_base_from_pair( 0x7efde000, 0x7efde000, 0x7efdf000, 0x7efdf000 ) );
    assert( !wow64_window_base_from_pair( a + 0x1000 + 0x7fe02000, 0x7fe02000, a + 0x1000 + 0x7ff00000, 0x7ff00000 ) );
    assert( !wow64_window_base_from_pair( 0x10000 + 0x7fe02000, 0x7fe02000, 0x10000 + 0x7ff00000, 0x7ff00000 ) );
    assert( !wow64_window_valid_base( 0 ) && !wow64_window_valid_base( UINT64_MAX - 0xffff ) );
    assert( wow64_window_valid_base( UINT64_MAX - WOW64_WINDOW_SIZE + 1 ) );

    puts( "wow64 guest window: checked round trips, rejection, edges, two windows, no window and the base pair" );
    return 0;
}
