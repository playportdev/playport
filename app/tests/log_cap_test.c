/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * log_cap_test.c — log_cap.c on the Linux host (pp test): past the dev log's
 * cap, dropped output is counted line by line across reads, a report comes
 * once the first line is complete and then at most once per interval, quotes
 * the latest dropped line cut to LOG_CAP_LINE_MAX with control bytes blanked,
 * and stays one line when it does not fit. The switch at the cap, forced with
 * a 4 KiB cap on a file: under it nothing changes; at it the "reached" line is
 * appended, stderr's stand-in becomes a pipe, and what is written there is
 * counted, with only the reports landing in the log.
 */
#include "log_cap.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static double fake_clock;
static double fake_now(void)
{
    return fake_clock += 1.0;   /* one second a read */
}

static int switched;
static void count_switch(void)
{
    switched++;
}

static long size_of(int fd)
{
    struct stat st;
    return fstat(fd, &st) ? -1 : (long)st.st_size;
}

/* log_cap_divert and log_cap_drain on a real file with a 4 KiB cap. */
static void check_divert(void)
{
    const char *tmp = getenv("TMPDIR");
    char path[1024], chunk[1000], all[16384];
    snprintf(path, sizeof(path), "%s/log_cap_test_XXXXXX", tmp && *tmp ? tmp : ".");
    int log_fd = mkstemp(path);
    if (log_fd < 0) { CHECK(0); return; }
    close(log_fd);
    log_fd = open(path, O_RDWR | O_APPEND);
    int err_fd = open(path, O_WRONLY | O_APPEND);   /* stderr's stand-in, the log as wine_host_init makes it */
    memset(chunk, 'r', sizeof(chunk));
    chunk[sizeof(chunk) - 1] = '\n';

    /* Under the cap: no switch, and the runtime's lines still land. */
    for (int i = 0; i < 3; i++) (void)!write(err_fd, chunk, sizeof(chunk));
    CHECK(log_cap_divert(log_fd, err_fd, 4096, count_switch) == -1 && switched == 0 && size_of(log_fd) == 3000);

    /* At the cap: the reached line, then the switch, then stderr is the pipe. */
    for (int i = 0; i < 2; i++) (void)!write(err_fd, chunk, sizeof(chunk));
    int in = log_cap_divert(log_fd, err_fd, 4096, count_switch);
    CHECK(in >= 0 && switched == 1);
    long at_switch = size_of(log_fd);
    CHECK(at_switch > 5000);

    /* The runtime goes on writing: 200 lines into the pipe, none into the log. */
    for (int i = 0; i < 200; i++) (void)!write(err_fd, "E 24 [iOS-xrem] via=section\n", 28);
    CHECK(size_of(log_fd) == at_switch);
    close(err_fd);   /* the last writer: the reader ends */
    log_cap_drain(in, log_fd, 4096, 10.0, fake_now);
    close(in);

    /* One report for what arrived in one read, quoting the latest line. */
    long n = pread(log_fd, all, sizeof(all) - 1, 0);
    all[n > 0 ? n : 0] = 0;
    CHECK(strstr(all, "[wine_host] log: 0 MiB reached; the runtime's lines are counted from here, not written\n") != NULL);
    CHECK(strstr(all, "200 lines (5600 bytes) dropped so far; the latest: E 24 [iOS-xrem] via=section\n") != NULL);
    CHECK(strstr(all, "[iOS-xrem] via=section\nE 24") == NULL);
    close(log_fd);
    unlink(path);
}

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

    check_divert();

    printf("log cap: %s\n", failures ? "FAILED" : "dropped lines counted, reports first and per interval, one line each; "
           "the switch forced at a 4 KiB cap");
    return failures != 0;
}
