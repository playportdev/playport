/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * play_end — see include/play_end.h.
 */

#include "play_end.h"

#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char mark_path[1024];
static volatile sig_atomic_t armed;
static int installed;

/* strlen, but on POSIX's list of async-signal-safe functions only since 2016. */
static size_t length(const char *s)
{
    size_t n = 0;

    while (s[n]) n++;
    return n;
}

void play_end_mark(const char *why)
{
    int fd;

    if (!armed) return;
    fd = open(mark_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    if (write(fd, why, length(why)) >= 0) (void)!write(fd, "\n", 1);
    close(fd);
}

void play_end_signal(int sig)
{
    char why[24] = "signal ", digits[12];
    size_t n = length(why), d = 0;
    unsigned v = sig > 0 ? (unsigned)sig : 0;

    do {
        digits[d++] = (char)('0' + v % 10);
        v /= 10;
    } while (v && d < sizeof(digits));
    while (d && n < sizeof(why) - 1) why[n++] = digits[--d];
    why[n] = 0;
    play_end_mark(why);
}

/* SA_RESETHAND: the default disposition is back, so the signal raised again
 * once this returns ends the process as it would have. */
static void on_signal(int sig)
{
    play_end_signal(sig);
    raise(sig);
}

static void at_exit(void)
{
    play_end_mark("exit");
}

static void install(int sig)
{
    struct sigaction old, sa;

    if (sigaction(sig, NULL, &old) || (old.sa_flags & SA_SIGINFO) || old.sa_handler != SIG_DFL) return;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sa.sa_flags = SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    sigaction(sig, &sa, NULL);
}

void play_end_arm(const char *path)
{
    size_t n = length(path);

    armed = 0;
    if (n >= sizeof(mark_path)) return;
    memcpy(mark_path, path, n + 1);
    armed = 1;
    if (!installed) {
        installed = 1;
        install(SIGTERM);
        install(SIGHUP);
        atexit(at_exit);
    }
}

void play_end_disarm(void)
{
    armed = 0;
}

void play_end_unmark(void)
{
    if (armed) unlink(mark_path);
}
