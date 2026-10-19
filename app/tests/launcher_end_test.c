/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * launcher_end_test.c — app/SessionRoot/launcher_end.h on the Linux host (pp test):
 * which processes the session root ends once the game signed in through the
 * Rockstar Games Launcher (PP_CONTROL_END_LAUNCHER, decision 0124). The process
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
    uint32_t n = 0, ended[4], nended = 0, i;

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

    /* wave 1: the launcher and its error handler, not the namesake under the game */
    for (i = 0; i < n; i++)
        if (pp_launcher_end_first(p, n, i)) ended[nended++] = p[i].pid;
    CHECK(nended == 2 && ended[0] == 0x70 && ended[1] == 0x7c);

    /* the launcher and its error handler are gone; RDR2.exe's parent is now a dead id */
    p[1] = p[--n]; p[2] = p[--n];
    {
        uint32_t count = 0, browser = 0, renderer = 0;
        for (i = 0; i < n; i++) {
            if (!pp_launcher_end_second(p, n, i, ended, nended)) continue;
            count++;
            browser |= p[i].pid == 0x1b4;
            renderer |= p[i].pid == 0x284;
            CHECK(!pp_launcher_under_game(p, n, i));
        }
        /* wave 2: the launcher's browser and renderer; never the game's helpers */
        CHECK(count == 2 && browser && renderer);
    }
    for (i = 0; i < n; i++)
        if (p[i].pid == 0x414 || p[i].pid == 0x500 || p[i].pid == 0x510 || p[i].pid == 0x424)
            CHECK(!pp_launcher_end_first(p, n, i) && !pp_launcher_end_second(p, n, i, ended, nended));

    /* nothing ended in wave 1: wave 2 ends nothing */
    for (i = 0; i < n; i++) CHECK(!pp_launcher_end_second(p, n, i, ended, 0));

    /* a parent cycle (reused ids) ends the walk */
    {
        pp_launcher_proc loop[2] = { { 1, 2, u16(12, "SocialClubHelper.exe") }, { 2, 1, u16(13, "SocialClubHelper.exe") } };
        uint32_t none = 99;
        CHECK(!pp_launcher_under_game(loop, 2, 0));
        CHECK(!pp_launcher_end_second(loop, 2, 0, &none, 1));
    }

    printf("%s\n", failures ? "launcher end: FAILED" : "launcher end: ok");
    return failures != 0;
}
