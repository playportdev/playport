/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * host_log.c — HostIO.swift's lines into s1-host.log (host_io.h).
 *
 * On the device no HostIO line written from Swift appeared once
 * wine_host_init had run: not through GCD at either QoS, not written
 * synchronously, not through the fd-2 fallback.
 * Winios's own fprintf(stderr) lines, called from the same main thread, did.
 * So this does what Winios does: once fd 2 is the log (wine_host_init dup2s it
 * there, O_APPEND), the line goes through stderr; before that it is appended
 * to the file directly. A release build sets a limit (host_log_set_limit):
 * a line is dropped once the file has reached it, whichever way it would go.
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <unistd.h>

#include "host_io.h"

static volatile long log_limit;

void host_log_set_limit(long bytes)
{
    log_limit = bytes > 0 ? bytes : 0;
}

void host_log(const char *path, const char *line)
{
    struct stat log_st, err_st;
    int fd, have_log;
    if (!path || !line) return;
    have_log = stat(path, &log_st) == 0;
    if (log_limit && have_log && log_st.st_size >= log_limit) return;
    if (have_log && fstat(STDERR_FILENO, &err_st) == 0 &&
        log_st.st_dev == err_st.st_dev && log_st.st_ino == err_st.st_ino) {
        fprintf(stderr, "%s\n", line);
        fflush(stderr);
        return;
    }
    fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) return;
    /* One writev, so a line from another thread cannot land between the
     * text and its newline (O_APPEND makes each write call atomic). */
    struct iovec iov[2] = {{(void *)line, strlen(line)}, {"\n", 1}};
    (void)!writev(fd, iov, 2);
    close(fd);
}
