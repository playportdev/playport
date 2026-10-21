/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * log_cap_test.c — log_cap.c on the Linux host (pp test): past the dev log's
 * cap, dropped output is counted line by line across reads, a report comes
 * once the first line is complete and then at most once per interval, quotes
 * the latest dropped line cut to LOG_CAP_LINE_MAX with control bytes blanked,
 * and stays one line when it does not fit.
 */
#include "log_cap.h"

#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

int main(void)
{
    log_cap_tally t;
    char out[512];
    size_t len;

    log_cap_tally_init(&t, 256L << 20);

    /* Half a line: counted bytes, no line, no report. */
    len = log_cap_tally_feed(&t, "D 1A4 Exception: Code: C00", 26, 100.0, 10.0, out, sizeof(out));
    CHECK(len == 0 && t.lines == 0 && t.bytes == 26);

    /* Its end: the first report, quoting the whole line. */
    len = log_cap_tally_feed(&t, "00005\n", 6, 100.5, 10.0, out, sizeof(out));
    CHECK(len > 0 && out[len - 1] == '\n' && strlen(out) == len);
    CHECK(strstr(out, "256 MiB dev cap, 1 lines (32 bytes)") != NULL);
    CHECK(strstr(out, "the latest: D 1A4 Exception: Code: C0000005\n") != NULL);

    /* More lines within the interval: counted, no report. */
    for (int i = 0; i < 1000; i++) {
        len = log_cap_tally_feed(&t, "a\nb\n", 4, 101.0 + i * 0.001, 10.0, out, sizeof(out));
        CHECK(len == 0);
    }
    CHECK(t.lines == 2001 && t.bytes == 4032);

    /* The interval passed: a report with the counts so far. */
    len = log_cap_tally_feed(&t, "x\ttab\n", 6, 110.5, 10.0, out, sizeof(out));
    CHECK(len > 0 && strstr(out, "2002 lines (4038 bytes)") != NULL);
    CHECK(strstr(out, "the latest: x tab\n") != NULL);

    /* A long line is quoted cut to LOG_CAP_LINE_MAX. */
    char longline[1000];
    memset(longline, 'y', sizeof(longline));
    longline[sizeof(longline) - 1] = '\n';
    len = log_cap_tally_feed(&t, longline, sizeof(longline), 121.0, 10.0, out, sizeof(out));
    CHECK(len > 0 && strlen(t.latest) == LOG_CAP_LINE_MAX);

    /* A report that does not fit stays one line. */
    len = log_cap_tally_feed(&t, "z\n", 2, 132.0, 10.0, out, 40);
    CHECK(len == 39 && out[38] == '\n' && strlen(out) == 39);

    printf("log cap: %s\n", failures ? "FAILED" : "dropped lines counted, reports first and per interval, one line each");
    return failures != 0;
}
