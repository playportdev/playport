/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * play_end_test.c — play_end.c on the Linux host (pp test): an armed Play's
 * process leaves its end mark when SIGTERM or SIGHUP ends it, when it calls
 * exit(), and when ntdll declines a host fault (play_end_signal, madeira-unix
 * 0295); a mark the app wrote (going to the background) goes when it comes
 * back; a disarmed Play, a handler someone else installed and a path too long
 * to keep leave none. Each case runs in a child process, which it ends.
 */
#include "play_end.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static char path[512];

/* The mark's text, or "" when there is none. */
static const char *mark(void)
{
    static char text[64];
    FILE *f = fopen(path, "r");
    size_t n = 0;

    text[0] = 0;
    if (f) {
        n = fread(text, 1, sizeof(text) - 1, f);
        fclose(f);
    }
    text[n] = 0;
    return text;
}

/* Runs body in a child; returns its wait status. */
static int child(void (*body)(void))
{
    int status = 0;
    pid_t pid;

    unlink(path);
    fflush(stdout);
    pid = fork();
    if (pid == 0) {
        body();
        _exit(99);
    }
    waitpid(pid, &status, 0);
    return status;
}

static void term(void) { play_end_arm(path); raise(SIGTERM); }
static void hup(void) { play_end_arm(path); raise(SIGHUP); }
static void exits(void) { play_end_arm(path); exit(3); }
static void declined(void) { play_end_arm(path); play_end_signal(11); _exit(0); }
static void disarmed(void) { play_end_arm(path); play_end_disarm(); raise(SIGTERM); }
static void background(void)
{
    play_end_arm(path);
    play_end_mark("background");
    if (strcmp(mark(), "background\n") != 0) _exit(1);
    play_end_unmark();
    _exit(0);
}
static void ignored(void) { signal(SIGHUP, SIG_IGN); play_end_arm(path); raise(SIGHUP); _exit(0); }
static void rearmed(void) { play_end_arm(path); play_end_disarm(); play_end_arm(path); exit(0); }
static void too_long(void)
{
    char long_path[2048];

    memset(long_path, 'a', sizeof(long_path) - 1);
    long_path[sizeof(long_path) - 1] = 0;
    play_end_arm(long_path);
    play_end_mark("background");
    _exit(0);
}

int main(void)
{
    int status;

    const char *tmp = getenv("TMPDIR");

    snprintf(path, sizeof(path), "%s/play_end_test.%d.end", tmp && *tmp ? tmp : ".", (int)getpid());

    status = child(term);
    CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM);   /* the signal still ends it */
    CHECK(strcmp(mark(), "signal 15\n") == 0);

    status = child(hup);
    CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGHUP);
    CHECK(strcmp(mark(), "signal 1\n") == 0);

    status = child(exits);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 3);
    CHECK(strcmp(mark(), "exit\n") == 0);

    status = child(declined);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    CHECK(strcmp(mark(), "signal 11\n") == 0);

    status = child(disarmed);
    CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM);
    CHECK(strcmp(mark(), "") == 0);

    status = child(background);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    CHECK(strcmp(mark(), "") == 0);

    /* Someone else's disposition is theirs: an ignored SIGHUP stays ignored, and marks nothing. */
    status = child(ignored);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    CHECK(strcmp(mark(), "") == 0);

    /* A second Play's arm keeps one atexit: exit() marks once. */
    status = child(rearmed);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    CHECK(strcmp(mark(), "exit\n") == 0);

    status = child(too_long);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    CHECK(access(path, F_OK) != 0);

    unlink(path);
    if (failures) {
        printf("play_end_test: %d failure(s)\n", failures);
        return 1;
    }
    printf("play_end_test: ok\n");
    return 0;
}
