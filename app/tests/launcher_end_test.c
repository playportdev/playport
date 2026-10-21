/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * launcher_end_test.c — app/SessionRoot/launcher_end.h on the Linux host (pp test):
 * which processes the session root ends of the Rockstar Games Launcher at the
 * game's first frame, and which later starts are its restarts (PP_CONTROL_END_LAUNCHER,
 * decision 0125). The process
 * tree is RDR2's Steam play: PlayRDR2.exe starts Launcher.exe, which starts its
 * error handler, its Social Club browser (whose renderers are its children) and
 * RDR2.exe; the game starts its own Social Club helper and crash handler.
 */
#include "../SessionRoot/launcher_end.h"

#include <stdio.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

/* A UTF-16 copy of an ASCII name, one slot per process. */
static uint16_t names[16][40];

static const uint16_t *u16(int slot, const char *s)
{
    int i = 0;
    for (; s[i]; i++) names[slot][i] = (uint16_t)(unsigned char)s[i];
    names[slot][i] = 0;
    return names[slot];
}

int main(void)
{
    pp_launcher_proc p[12];
    uint32_t n = 0, ended[8], nended = 0, i;

    p[n++] = (pp_launcher_proc){ 0x64, 0x20, u16(0, "PlayRDR2.exe") };
    p[n++] = (pp_launcher_proc){ 0x70, 0x64, u16(1, "Launcher.exe") };
    p[n++] = (pp_launcher_proc){ 0x7c, 0x70, u16(2, "RockstarErrorHandler.exe") };
    p[n++] = (pp_launcher_proc){ 0x1b4, 0x70, u16(3, "SocialClubHelper.exe") };     /* the launcher's browser */
    p[n++] = (pp_launcher_proc){ 0x284, 0x1b4, u16(4, "SocialClubHelper.exe") };    /* its renderer */
    p[n++] = (pp_launcher_proc){ 0x414, 0x70, u16(5, "RDR2.exe") };                 /* the launcher's child */
    p[n++] = (pp_launcher_proc){ 0x424, 0x414, u16(6, "crashpad_handler.exe") };
    p[n++] = (pp_launcher_proc){ 0x500, 0x414, u16(7, "SocialClubHelper.exe") };    /* the game's own */
    p[n++] = (pp_launcher_proc){ 0x510, 0x500, u16(8, "SocialClubHelper.exe") };    /* the game's renderer */
    p[n++] = (pp_launcher_proc){ 0x520, 0x414, u16(9, "Launcher.exe") };            /* a namesake under the game */
    p[n++] = (pp_launcher_proc){ 0x11c, 0x28, u16(10, "RockstarService.exe") };     /* under services.exe */

    /* names are compared whole and without case */
    CHECK(pp_launcher_name_is(u16(11, "launcher.EXE"), "Launcher.exe"));
    CHECK(!pp_launcher_name_is(u16(11, "Launcher.exe2"), "Launcher.exe"));
    CHECK(!pp_launcher_name_is(u16(11, "Launcher.ex"), "Launcher.exe"));
    CHECK(!pp_launcher_name_is(NULL, "Launcher.exe"));

    /* the game and everything under it, and nothing else, is the game's */
    CHECK(pp_launcher_under_game(p, n, 5));
    CHECK(pp_launcher_under_game(p, n, 6));
    CHECK(pp_launcher_under_game(p, n, 7));
    CHECK(pp_launcher_under_game(p, n, 8));
    CHECK(pp_launcher_under_game(p, n, 9));
    CHECK(!pp_launcher_under_game(p, n, 1));
    CHECK(!pp_launcher_under_game(p, n, 3));
    CHECK(!pp_launcher_under_game(p, n, 4));

    /* the end, in one step: the launcher, its error handler, its browser and renderer; never the
     * game, its crash handler, its own helpers, the namesake under it or RockstarService */
    for (i = 0; i < n; i++)
        if (pp_launcher_end(p, n, i)) ended[nended++] = p[i].pid;
    CHECK(nended == 4 && ended[0] == 0x70 && ended[1] == 0x7c && ended[2] == 0x1b4 && ended[3] == 0x284);
    CHECK(pp_launcher_main(p, n, 1) && pp_launcher_main(p, n, 2) && !pp_launcher_main(p, n, 3));
    CHECK(pp_launcher_helper(p, n, 3) && pp_launcher_helper(p, n, 4));
    CHECK(!pp_launcher_helper(p, n, 7) && !pp_launcher_helper(p, n, 8));
    {
        /* a helper whose chain reaches no Launcher.exe (its browser already gone) is not one */
        pp_launcher_proc orphan[2] = { { 0x600, 0x5f0, u16(14, "SocialClubHelper.exe") },
                                       { 0x610, 0x520, u16(15, "SocialClubHelper.exe") } };
        CHECK(!pp_launcher_helper(orphan, 2, 0));
        CHECK(!pp_launcher_helper(orphan, 2, 1));
        CHECK(!pp_launcher_end(orphan, 2, 0));
    }
    {
        pp_launcher_proc under[3] = { { 0x414, 0x70, u16(5, "RDR2.exe") }, { 0x520, 0x414, u16(9, "Launcher.exe") },
                                      { 0x530, 0x520, u16(14, "SocialClubHelper.exe") } };
        CHECK(!pp_launcher_end(under, 3, 1));   /* the game's namesake launcher */
        CHECK(!pp_launcher_end(under, 3, 2));   /* and a helper under it */
    }

    /* the game's own Social Club end (decision 0133): the game's helper and its renderer only;
     * never the game, its crash handler, the launcher's helpers or the namesake under the game */
    nended = 0;
    for (i = 0; i < n; i++)
        if (pp_game_social_club(p, n, i)) ended[nended++] = p[i].pid;
    CHECK(nended == 2 && ended[0] == 0x500 && ended[1] == 0x510);
    nended = 0;
    for (i = 0; i < n; i++)
        if (pp_launcher_end(p, n, i)) ended[nended++] = p[i].pid;

    /* after the end the launcher's processes are gone; RDR2.exe's parent is a dead id */
    p[1] = p[--n]; p[2] = p[--n];
    for (i = 0; i < n; i++)
        if (p[i].pid == 0x1b4 || p[i].pid == 0x284) { p[i] = p[--n]; i = (uint32_t)-1; }
    for (i = 0; i < n; i++) CHECK(!pp_launcher_end(p, n, i));   /* nothing of the launcher is left */
    for (i = 0; i < n; i++) CHECK(!pp_launcher_restart(p, n, i, ended, nended));   /* the game's are no restarts */
    {
        /* with the launcher gone, the game's helpers are still the game's, and still the only ones */
        uint32_t sc = 0;
        for (i = 0; i < n; i++) sc += pp_game_social_club(p, n, i) ? 1u : 0u;
        CHECK(sc == 2);
    }
    {
        /* restarts: the launcher again (from PlayRDR2.exe), a helper of an ended launcher, a helper of
         * the restarted launcher once the root knows it; never the game's new helper, nor a helper
         * whose dead parent was no launcher process */
        pp_launcher_proc q[8];
        uint32_t m = 0, known[8], nknown = 0;
        q[m++] = (pp_launcher_proc){ 0x64, 0x20, u16(0, "PlayRDR2.exe") };
        q[m++] = (pp_launcher_proc){ 0x414, 0x70, u16(5, "RDR2.exe") };
        q[m++] = (pp_launcher_proc){ 0x630, 0x70, u16(14, "SocialClubHelper.exe") };    /* the ended launcher's */
        q[m++] = (pp_launcher_proc){ 0x640, 0x64, u16(1, "Launcher.exe") };             /* started again */
        q[m++] = (pp_launcher_proc){ 0x650, 0x660, u16(15, "SocialClubHelper.exe") };   /* parent gone, unknown */
        q[m++] = (pp_launcher_proc){ 0x670, 0x414, u16(7, "SocialClubHelper.exe") };    /* the game's new one */
        q[m++] = (pp_launcher_proc){ 0x680, 0x700, u16(3, "SocialClubHelper.exe") };    /* of the restarted launcher, which died */
        for (i = 0; i < nended; i++) known[nknown++] = ended[i];
        CHECK(pp_launcher_restart(q, m, 2, known, nknown));
        CHECK(pp_launcher_restart(q, m, 3, known, nknown));
        CHECK(!pp_launcher_restart(q, m, 4, known, nknown));
        CHECK(!pp_launcher_restart(q, m, 5, known, nknown));
        CHECK(!pp_launcher_restart(q, m, 1, known, nknown));
        CHECK(!pp_launcher_restart(q, m, 0, known, nknown));
        CHECK(!pp_launcher_restart(q, m, 6, known, nknown));
        known[nknown++] = 0x700;                    /* the root saw 0x700 restart */
        CHECK(pp_launcher_restart(q, m, 6, known, nknown));

        /* the sweep after the game's Social Club end: the game's new helper, once; never the
         * launcher's, nor the game */
        {
            uint32_t sc_ended[3] = { 0x600, 0x6c8 }, nsc = 2;
            CHECK(pp_game_social_club_restart(q, m, 5, sc_ended, nsc));
            CHECK(!pp_game_social_club_restart(q, m, 2, sc_ended, nsc));
            CHECK(!pp_game_social_club_restart(q, m, 4, sc_ended, nsc));
            CHECK(!pp_game_social_club_restart(q, m, 1, sc_ended, nsc));
            sc_ended[nsc++] = 0x670;                /* ended by the sweep, still listed */
            CHECK(!pp_game_social_club_restart(q, m, 5, sc_ended, nsc));
        }
    }

    /* restarts are ended once more only while one still runs and only in one round */
    CHECK(pp_launcher_restart_action(1, 0) == PP_LAUNCHER_RESTART_END);
    CHECK(pp_launcher_restart_action(1, 1) == PP_LAUNCHER_RESTART_REPORT);
    CHECK(pp_launcher_restart_action(0, 0) == PP_LAUNCHER_RESTART_REPORT);
    CHECK(pp_launcher_restart_action(0, 1) == PP_LAUNCHER_RESTART_REPORT);

    /* the game's Social Club controls (decision 0155): ALLOW stops the sweep only after an END,
     * at most PP_GAME_SC_MAX_ALLOWS times; END ends again after each ALLOW, never twice in a row */
    {
        int ended = 0;
        uint32_t allows = 0;
        CHECK(pp_game_sc_control(PP_CONTROL_ALLOW_GAME_SOCIAL_CLUB, &ended, &allows) == PP_GAME_SC_NOTHING);
        CHECK(!ended && allows == 0);
        CHECK(pp_game_sc_control(PP_CONTROL_END_GAME_SOCIAL_CLUB, &ended, &allows) == PP_GAME_SC_END && ended);
        CHECK(pp_game_sc_control(PP_CONTROL_END_GAME_SOCIAL_CLUB, &ended, &allows) == PP_GAME_SC_NOTHING && ended);
        CHECK(pp_game_sc_control(PP_CONTROL_ALLOW_GAME_SOCIAL_CLUB, &ended, &allows) == PP_GAME_SC_STOP_SWEEP);
        CHECK(!ended && allows == 1);
        CHECK(pp_game_sc_control(PP_CONTROL_ALLOW_GAME_SOCIAL_CLUB, &ended, &allows) == PP_GAME_SC_NOTHING);
        CHECK(allows == 1);
        CHECK(pp_game_sc_control(PP_CONTROL_END_GAME_SOCIAL_CLUB, &ended, &allows) == PP_GAME_SC_END && ended);
        CHECK(pp_game_sc_control(PP_CONTROL_ALLOW_GAME_SOCIAL_CLUB, &ended, &allows) == PP_GAME_SC_STOP_SWEEP);
        CHECK(!ended && allows == 2);
        CHECK(pp_game_sc_control(PP_CONTROL_END_GAME_SOCIAL_CLUB, &ended, &allows) == PP_GAME_SC_END && ended);
        CHECK(pp_game_sc_control(PP_CONTROL_ALLOW_GAME_SOCIAL_CLUB, &ended, &allows) == PP_GAME_SC_NOTHING);
        CHECK(ended && allows == PP_GAME_SC_MAX_ALLOWS);   /* the third: the sweep goes on */
        CHECK(pp_game_sc_control(PP_CONTROL_PAUSE, &ended, &allows) == PP_GAME_SC_NOTHING && ended);
    }

    /* a parent cycle (reused ids) ends the walk */
    {
        pp_launcher_proc loop[2] = { { 1, 2, u16(12, "SocialClubHelper.exe") }, { 2, 1, u16(13, "SocialClubHelper.exe") } };
        uint32_t none = 99;
        CHECK(!pp_launcher_under_game(loop, 2, 0));
        CHECK(!pp_launcher_helper(loop, 2, 0));
        CHECK(!pp_launcher_restart(loop, 2, 0, &none, 1));
        CHECK(!pp_game_social_club(loop, 2, 0));
    }

    printf("%s\n", failures ? "launcher end: FAILED" : "launcher end: ok");
    return failures != 0;
}
