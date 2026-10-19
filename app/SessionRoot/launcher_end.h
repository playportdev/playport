/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Which of the title's processes the session root ends once the game signed in
 * through the Rockstar Games Launcher (PP_CONTROL_END_LAUNCHER, decision 0124).
 * The root lists the job's processes with Toolhelp (id, parent id, executable
 * name) and asks this header, which the host test runs too: no library calls.
 *
 * On desktop the launcher starts RDR2.exe as its own child, and the game starts
 * its own Social Club helpers. So a tree-kill of the launcher would end the
 * game: the root ends processes one at a time, never RDR2.exe or a process
 * whose parent chain reaches it.
 *   wave 1 (at once):  Launcher.exe and RockstarErrorHandler.exe;
 *   wave 2 (10 s on):  SocialClubHelper.exe whose parent chain ends at a
 *                      process wave 1 ended (the launcher's own CEF). */
#ifndef PLAYPORT_LAUNCHER_END_H
#define PLAYPORT_LAUNCHER_END_H

#include <stdint.h>

#define PP_LAUNCHER_END_WAVE2_MS 10000u
/* Parent links followed at most: a cycle of reused process ids cannot loop. */
#define PP_LAUNCHER_END_DEPTH 32u

typedef struct {
    uint32_t pid, parent;
    const uint16_t *name;   /* the executable's file name, NUL-terminated UTF-16 */
} pp_launcher_proc;

static inline int pp_launcher_name_is(const uint16_t *name, const char *want)
{
    uint32_t i = 0;
    if (!name) return 0;
    for (; want[i]; i++) {
        uint16_t c = name[i];
        char w = want[i];
        if (c >= 'A' && c <= 'Z') c = (uint16_t)(c - 'A' + 'a');
        if (w >= 'A' && w <= 'Z') w = (char)(w - 'A' + 'a');
        if (c != (uint16_t)(unsigned char)w) return 0;
    }
    return name[i] == 0;
}

static inline int pp_launcher_find(const pp_launcher_proc *p, uint32_t n, uint32_t pid)
{
    uint32_t i;
    for (i = 0; i < n; i++) if (p[i].pid == pid) return (int)i;
    return -1;
}

/* Whether process i is the game or runs under it: RDR2.exe itself, or a parent
 * chain through the listed processes that reaches it. */
static inline int pp_launcher_under_game(const pp_launcher_proc *p, uint32_t n, uint32_t i)
{
    uint32_t depth;
    int at = (int)i;
    for (depth = 0; at >= 0 && depth < PP_LAUNCHER_END_DEPTH; depth++) {
        if (pp_launcher_name_is(p[at].name, "RDR2.exe")) return 1;
        if (p[at].parent == p[at].pid) break;
        at = pp_launcher_find(p, n, p[at].parent);
    }
    return 0;
}

/* Whether process i's parent chain reaches one of the `nended` processes wave 1
 * ended (those are gone, so the chain ends at their id). */
static inline int pp_launcher_from_ended(const pp_launcher_proc *p, uint32_t n, uint32_t i,
                                         const uint32_t *ended, uint32_t nended)
{
    uint32_t depth, k;
    int at = (int)i;
    for (depth = 0; at >= 0 && depth < PP_LAUNCHER_END_DEPTH; depth++) {
        for (k = 0; k < nended; k++) if (p[at].parent == ended[k]) return 1;
        if (p[at].parent == p[at].pid) break;
        at = pp_launcher_find(p, n, p[at].parent);
    }
    return 0;
}

/* Whether wave 1 ends process i: the launcher or its error handler, not under the game. */
static inline int pp_launcher_end_first(const pp_launcher_proc *p, uint32_t n, uint32_t i)
{
    return (pp_launcher_name_is(p[i].name, "Launcher.exe") ||
            pp_launcher_name_is(p[i].name, "RockstarErrorHandler.exe")) &&
           !pp_launcher_under_game(p, n, i);
}

/* Whether wave 2 ends process i: a Social Club helper the ended launcher started,
 * not under the game. */
static inline int pp_launcher_end_second(const pp_launcher_proc *p, uint32_t n, uint32_t i,
                                         const uint32_t *ended, uint32_t nended)
{
    return pp_launcher_name_is(p[i].name, "SocialClubHelper.exe") && !pp_launcher_under_game(p, n, i) &&
           pp_launcher_from_ended(p, n, i, ended, nended);
}

#endif
