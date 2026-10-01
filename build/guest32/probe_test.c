/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "guest32_probe.h"
#include <assert.h>
#include <stdio.h>

int main(void)
{
    /* Repeated runs must release both 4 GiB windows and leave no stale state. */
    for (unsigned n = 0; n < 3; ++n) {
        g32_probe_report r = g32_probe_native();
        assert(r.checks == 36 && r.failures == 0);
        assert(r.host_page >= 4096);
        assert(r.backing_a >= (UINT64_C(1) << 32));
        assert(r.backing_b >= (UINT64_C(1) << 32));
        assert(r.backing_a != r.backing_b);
    }
    puts("guest32 native Settings probe: 36 checks passed, three repeated runs");
    return 0;
}
