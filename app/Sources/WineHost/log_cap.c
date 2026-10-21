/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * log_cap — see include/log_cap.h.
 */

#include "log_cap.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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

int log_cap_divert(int log_fd, int err_fd, long cap, void (*before_switch)(void))
{
    struct stat st;
    int p[2];
    if (fstat(log_fd, &st) || st.st_size < cap) return -1;
    if (pipe(p)) return -1;
    dprintf(log_fd, "[wine_host] log: %ld MiB reached; the runtime's lines are counted from here, not written\n",
            cap >> 20);
    if (before_switch) before_switch();
    dup2(p[1], err_fd);
    close(p[1]);
    return p[0];
}

void log_cap_drain(int in, int log_fd, long cap, double interval, double (*now)(void))
{
    static char buf[65536];
    char report[512];
    log_cap_tally tally;
    log_cap_tally_init(&tally, cap);
    for (;;) {
        ssize_t n = read(in, buf, sizeof(buf));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return;
        size_t len = log_cap_tally_feed(&tally, buf, (size_t)n, now(), interval, report, sizeof(report));
        if (len) (void)!write(log_fd, report, len);
    }
}
