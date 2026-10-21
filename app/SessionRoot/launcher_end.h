/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Which of the title's processes the session root ends of the Rockstar Games
 * Launcher when the app asks, at the game's sign-in (PP_CONTROL_END_LAUNCHER,
 * decisions 0125, 0130), and which later starts it counts as the launcher's restarts.
 * The root lists the job's processes with Toolhelp (id, parent id, executable
 * name) and asks this header, which the host test runs too: no library calls.
 *
 * On desktop the launcher starts RDR2.exe as its own child, and the game starts
 * its own Social Club helpers. So a tree-kill of the launcher would end the
 * game: the root ends processes one at a time, never RDR2.exe or a process
 * whose parent chain reaches it.
 *   the end (one step): Launcher.exe, RockstarErrorHandler.exe and every
 *                       SocialClubHelper.exe whose parent chain reaches a
 *                       Launcher.exe (the launcher's own CEF);
 *   restarts (after):   every start of one of those images not under the game;
 *                       a Social Club helper counts when its chain reaches a
 *                       Launcher.exe or a launcher process the root ended or saw
 *                       restart. The root ends the first restarts it finds still
 *                       running once more, in one round, and only reports the rest. */
#ifndef PLAYPORT_LAUNCHER_END_H
#define PLAYPORT_LAUNCHER_END_H

#include <stdint.h>
#include "../Sources/WineHost/include/session_protocol.h"

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

/* Whether process i's parent chain reaches one of the `nknown` launcher processes
 * (ones that are gone end the chain at their id). */
static inline int pp_launcher_from_known(const pp_launcher_proc *p, uint32_t n, uint32_t i,
                                         const uint32_t *known, uint32_t nknown)
{
    uint32_t depth, k;
    int at = (int)i;
    for (depth = 0; at >= 0 && depth < PP_LAUNCHER_END_DEPTH; depth++) {
        for (k = 0; k < nknown; k++) if (p[at].parent == known[k]) return 1;
        if (p[at].parent == p[at].pid) break;
        at = pp_launcher_find(p, n, p[at].parent);
    }
    return 0;
}

/* Whether process i is one of the launcher's own Social Club helpers: a
 * SocialClubHelper.exe whose parent chain reaches a Launcher.exe, not under the
 * game (the game's own helpers are RDR2.exe's). */
static inline int pp_launcher_helper(const pp_launcher_proc *p, uint32_t n, uint32_t i)
{
    uint32_t depth;
    int at;
    if (!pp_launcher_name_is(p[i].name, "SocialClubHelper.exe") || pp_launcher_under_game(p, n, i)) return 0;
    at = p[i].parent == p[i].pid ? -1 : pp_launcher_find(p, n, p[i].parent);
    for (depth = 0; at >= 0 && depth < PP_LAUNCHER_END_DEPTH; depth++) {
        if (pp_launcher_name_is(p[at].name, "Launcher.exe")) return 1;
        if (p[at].parent == p[at].pid) break;
        at = pp_launcher_find(p, n, p[at].parent);
    }
    return 0;
}

/* Whether the launcher itself or its error handler, not under the game. */
static inline int pp_launcher_main(const pp_launcher_proc *p, uint32_t n, uint32_t i)
{
    return (pp_launcher_name_is(p[i].name, "Launcher.exe") ||
            pp_launcher_name_is(p[i].name, "RockstarErrorHandler.exe")) &&
           !pp_launcher_under_game(p, n, i);
}

/* Whether the end ends process i: the launcher, its error handler or its own
 * Social Club helpers, never the game or a process under it. */
static inline int pp_launcher_end(const pp_launcher_proc *p, uint32_t n, uint32_t i)
{
    return pp_launcher_main(p, n, i) || pp_launcher_helper(p, n, i);
}

/* The exit code the end gives process i (decision 0156). Rockstar's Steam stub PlayRDR2.exe
 * waits on Launcher.exe and shows "Unable to launch game" unless its exit code is 0, so
 * Launcher.exe ends with 0, as when a person quits it; the launcher's other processes end
 * with ERROR_PROCESS_ABORTED. */
#define PP_LAUNCHER_END_ABORTED 1067u   /* ERROR_PROCESS_ABORTED */

static inline uint32_t pp_launcher_end_code(const pp_launcher_proc *p, uint32_t i)
{
    return pp_launcher_name_is(p[i].name, "Launcher.exe") ? 0 : PP_LAUNCHER_END_ABORTED;
}

/* Whether process i, started after the end, is the launcher's restart: the
 * launcher or its error handler again, or a Social Club helper of the launcher or
 * of one of the `nknown` launcher processes the root ended or saw restart. */
static inline int pp_launcher_restart(const pp_launcher_proc *p, uint32_t n, uint32_t i,
                                      const uint32_t *known, uint32_t nknown)
{
    if (pp_launcher_main(p, n, i) || pp_launcher_helper(p, n, i)) return 1;
    return pp_launcher_name_is(p[i].name, "SocialClubHelper.exe") && !pp_launcher_under_game(p, n, i) &&
           pp_launcher_from_known(p, n, i, known, nknown);
}

/* Whether process i is one of the game's own Social Club helpers, which a dev build's
 * PP_CONTROL_END_GAME_SOCIAL_CLUB ends after the game's sign-in (decision 0133): a
 * SocialClubHelper.exe whose parent chain reaches RDR2.exe (its browser, the game's
 * child, and the browser's renderers). Never RDR2.exe itself or any other image. */
static inline int pp_game_social_club(const pp_launcher_proc *p, uint32_t n, uint32_t i)
{
    return pp_launcher_name_is(p[i].name, "SocialClubHelper.exe") && pp_launcher_under_game(p, n, i);
}

/* Whether the root's sweep after the game's Social Club end ends process i
 * (decisions 0133, 0135): one of the game's own Social Club helpers that is
 * not among the `nended` processes it ended already, which may still be listed
 * while they go. */
static inline int pp_game_social_club_restart(const pp_launcher_proc *p, uint32_t n, uint32_t i,
                                              const uint32_t *ended, uint32_t nended)
{
    uint32_t k;
    if (!pp_game_social_club(p, n, i)) return 0;
    for (k = 0; k < nended; k++) if (ended[k] == p[i].pid) return 0;
    return 1;
}

/* The game's Social Club controls (decisions 0133, 0135, 0155). END ends the game's helpers
 * and starts the sweep that ends their restarts (`*ended` 1), once until an ALLOW; ALLOW,
 * after an end, stops the sweep (`*ended` 0) so a restart runs, at most PP_GAME_SC_MAX_ALLOWS
 * times a title (`*allows`), and a later END ends them again. What the root does now. */
#define PP_GAME_SC_MAX_ALLOWS 2u
enum { PP_GAME_SC_NOTHING, PP_GAME_SC_END, PP_GAME_SC_STOP_SWEEP };

static inline int pp_game_sc_control(int kind, int *ended, uint32_t *allows)
{
    if (kind == PP_CONTROL_END_GAME_SOCIAL_CLUB) {
        if (*ended) return PP_GAME_SC_NOTHING;
        *ended = 1;
        return PP_GAME_SC_END;
    }
    if (kind == PP_CONTROL_ALLOW_GAME_SOCIAL_CLUB) {
        if (!*ended || *allows >= PP_GAME_SC_MAX_ALLOWS) return PP_GAME_SC_NOTHING;
        *ended = 0;
        ++*allows;
        return PP_GAME_SC_STOP_SWEEP;
    }
    return PP_GAME_SC_NOTHING;
}

/* What the root does with a restart: the first ones it finds still running are
 * ended once more, in one round; any later or already gone are only reported. */
enum { PP_LAUNCHER_RESTART_REPORT, PP_LAUNCHER_RESTART_END };

static inline int pp_launcher_restart_action(int running, int round_done)
{
    return running && !round_done ? PP_LAUNCHER_RESTART_END : PP_LAUNCHER_RESTART_REPORT;
}

#endif
