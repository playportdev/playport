/* SPDX-License-Identifier: GPL-3.0-or-later */
/* wine-pe 0023's guest_stack_span, compiled from the patch: the windowed
 * guest's fault log reads its stack only inside the thread's committed 32-bit
 * stack, so a bad or switched esp or ebp is never dereferenced. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint32_t ULONG;
#include "wow64_window.h"

static uint64_t wow64_window_base;
static void *wow64_to_host( ULONG guest ) { return wow64_window_to_host( wow64_window_base, guest ); }

#include "stack_span_api.h"

int main(void)
{
    const ULONG limit = 0x00a02000, base = 0x00b00000;

    wow64_window_base = UINT64_C(0x7038010000);
    /* inside: the host address of the guest address */
    assert( guest_stack_span( limit, base, limit, 64 ) == (void *)(uintptr_t)(wow64_window_base + limit) );
    assert( guest_stack_span( limit, base, base - 64, 64 ) == (void *)(uintptr_t)(wow64_window_base + base - 64) );
    assert( guest_stack_span( limit, base, base - 8, 8 ) );
    /* below the limit (guard page, a switched or wild esp), at or past the base,
     * a span running past the base, or misaligned */
    assert( !guest_stack_span( limit, base, limit - 4, 8 ) );
    assert( !guest_stack_span( limit, base, 0, 8 ) );
    assert( !guest_stack_span( limit, base, base, 4 ) );
    assert( !guest_stack_span( limit, base, base - 60, 64 ) );
    assert( !guest_stack_span( limit, base, base - 4, 8 ) );
    assert( !guest_stack_span( limit, base, 0xfffffffc, 8 ) );
    assert( !guest_stack_span( limit, base, limit + 2, 8 ) );
    /* no stack (zeroed TEB32 bounds): nothing is readable */
    assert( !guest_stack_span( 0, 0, 0x1000, 8 ) );
    puts( "wow64 fault log: guest stack reads stay in the committed stack" );
    return EXIT_SUCCESS;
}
