/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef PLAYPORT_GUEST32_PROBE_H
#define PLAYPORT_GUEST32_PROBE_H
#include <stdint.h>

/* Dev-only Settings diagnostic. It acquires/releases software VM windows;
 * never starts Wine, acquires JIT, writes game files or executes guest code. */
typedef struct {
    uint64_t host_page, backing_a, backing_b;
    uint32_t checks, failures;
} g32_probe_report;
g32_probe_report g32_probe_native(void);
#endif
