/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * host_log_test.c — host_log.c on the Linux host (pp test):
 * with no limit every line is appended; with a release build's limit
 * (host_log_set_limit, AppLog.swift) lines stop once the file has reached it,
 * whether host_log appends to the file itself or, once stderr is the log
 * (wine_host_init's dup2), writes through stderr. The rotation at launch
 * (host_log_rotate, AppLog.swift), forced with small sizes: a log over the
 * size becomes the previous log, replacing it; one at or under it stays.
 */
#include "host_io.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static long size_of(const char *path)
{
    struct stat st;
    return stat(path, &st) ? -1 : (long)st.st_size;
}

int main(void)
{
    const char *tmp = getenv("TMPDIR");
    char path[1024], line[100];
    snprintf(path, sizeof(path), "%s/host_log_test_XXXXXX", tmp && *tmp ? tmp : ".");
    int fd = mkstemp(path), i;
    if (fd < 0) return 1;
    close(fd);
    memset(line, 'x', sizeof(line) - 1);
    line[sizeof(line) - 1] = 0;   /* 99 bytes, 100 with the newline */

    /* No limit: everything is appended. */
    for (i = 0; i < 50; i++) host_log(path, line);
    CHECK(size_of(path) == 5000);

    /* A limit: the lines up to it land, then nothing. */
    host_log_set_limit(6000);
    for (i = 0; i < 50; i++) host_log(path, line);
    CHECK(size_of(path) == 6000);

    /* Through stderr, as after wine_host_init: still stopped at the limit. */
    host_log_set_limit(6500);
    fflush(stderr);
    int saved = dup(STDERR_FILENO);
    fd = open(path, O_WRONLY | O_APPEND);
    dup2(fd, STDERR_FILENO);
    close(fd);
    for (i = 0; i < 50; i++) host_log(path, line);
    fflush(stderr);
    dup2(saved, STDERR_FILENO);
    close(saved);
    CHECK(size_of(path) == 6500);

    /* Back to no limit. */
    host_log_set_limit(0);
    host_log(path, line);
    CHECK(size_of(path) == 6600);

    /* Rotation: 6600 bytes is not over 6600, so it stays. */
    char previous[1100];
    snprintf(previous, sizeof(previous), "%s.prev", path);
    host_log_rotate(path, previous, 6600);
    CHECK(size_of(path) == 6600 && size_of(previous) == -1);

    /* Over it: the log becomes the previous log. */
    host_log_rotate(path, previous, 6599);
    CHECK(size_of(path) == -1 && size_of(previous) == 6600);

    /* A new session's log, rotated again: it replaces the older previous log. */
    for (i = 0; i < 3; i++) host_log(path, line);
    host_log_rotate(path, previous, 200);
    CHECK(size_of(path) == -1 && size_of(previous) == 300);

    /* No log at all: nothing happens. */
    host_log_rotate(path, previous, 0);
    CHECK(size_of(previous) == 300);

    unlink(previous);
    unlink(path);
    printf("host_log: %s\n", failures ? "FAILED" : "unlimited, limited and through-stderr appends as expected; rotation forced");
    return failures != 0;
}
