/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * log_cap.h — the dev log's cap: what the runtime writes once s1-host.log has
 * reached WINE_HOST_DEV_LOG_CAP (wine_host.h) in a session is counted, not written.
 *
 * A dev build has no release limit (wine_host_set_log_limit), and one guest
 * exception loop grew s1-host.log past 1.1 GB on the phone (RDR2 run p1,
 * 2026-10-21). Under the cap the log is whole, so the first occurrences of a
 * repeating line are kept; past it wine_host.c's watchdog points stderr at a
 * pipe whose reader feeds this tally and appends only its report lines: the
 * first once a dropped line is complete, then at most one per interval, each
 * with the counts so far and the latest dropped line.
 *
 * Plain C with no Apple headers, so the host C tests (`pp test`, app/tests)
 * build it on the Linux host.
 */
#ifndef LOG_CAP_H
#define LOG_CAP_H

#include <stddef.h>

/* The latest dropped line quoted in a report is cut to this many bytes. */
#define LOG_CAP_LINE_MAX 200

typedef struct log_cap_tally {
    long cap;                      /* bytes, for the report's text */
    unsigned long long lines;      /* complete lines dropped */
    unsigned long long bytes;      /* bytes dropped, a partial line included */
    double last_report;            /* seconds; negative before the first report */
    char latest[LOG_CAP_LINE_MAX + 1];
    char current[LOG_CAP_LINE_MAX + 1];
    size_t current_len;
} log_cap_tally;

void log_cap_tally_init(log_cap_tally *t, long cap);

/* Counts n dropped bytes read at `now` (seconds, any monotonic clock). When a
 * report is due (a complete line has been dropped, and this is the first
 * report or `interval` seconds have passed since the last), writes it to out
 * as one newline-terminated line and returns its length; otherwise returns 0. */
size_t log_cap_tally_feed(log_cap_tally *t, const char *buf, size_t n, double now, double interval,
                          char *out, size_t out_size);

#endif
