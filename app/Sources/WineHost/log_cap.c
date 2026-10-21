/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * log_cap — see include/log_cap.h.
 */

#include "log_cap.h"

#include <stdio.h>
#include <string.h>

void log_cap_tally_init(log_cap_tally *t, long cap)
{
    memset(t, 0, sizeof(*t));
    t->cap = cap;
    t->last_report = -1;
}

size_t log_cap_tally_feed(log_cap_tally *t, const char *buf, size_t n, double now, double interval,
                          char *out, size_t out_size)
{
    for (size_t i = 0; i < n; i++) {
        if (buf[i] == '\n') {
            memcpy(t->latest, t->current, t->current_len);
            t->latest[t->current_len] = 0;
            t->current_len = 0;
            t->lines++;
        } else if (t->current_len < LOG_CAP_LINE_MAX) {
            /* A control byte would break the report's one line. */
            t->current[t->current_len++] = (unsigned char)buf[i] < 0x20 ? ' ' : buf[i];
        }
    }
    t->bytes += n;
    if (!t->lines || !out || !out_size) return 0;
    if (t->last_report >= 0 && now - t->last_report < interval) return 0;
    t->last_report = now;
    int len = snprintf(out, out_size,
                       "[wine_host] log: past the %ld MiB dev cap, %llu lines (%llu bytes) dropped so far; the latest: %s\n",
                       t->cap >> 20, t->lines, t->bytes, t->latest);
    if (len < 0) return 0;
    if ((size_t)len >= out_size) {   /* cut, but still one line */
        out[out_size - 2] = '\n';
        return out_size - 1;
    }
    return (size_t)len;
}
