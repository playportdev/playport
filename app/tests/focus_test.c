/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * focus_test.c — hio_focus.c on the Linux host (pp test): the guest window
 * Winios gives the foreground back to after a focus loss left none (WoW's
 * login screen after the Passwords sheet, fg 0 for good: PLA-516). The
 * window that lost focus while it can still be activated, else the topmost
 * activatable window of its process, else the topmost of any, else none.
 */
#include "host_io.h"

#include <stdio.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

#define WS_POPUP         0x80000000u
#define WS_CHILD         0x40000000u
#define WS_MINIMIZE      0x20000000u
#define WS_VISIBLE       0x10000000u
#define WS_DISABLED      0x08000000u
#define WS_CAPTION       0x00C00000u
#define WS_EX_NOACTIVATE 0x08000000u

/* Distinct fake handles. */
static char h_game, h_hidden, h_dialog, h_launcher, h_ime;
#define GAME     ((const void *)&h_game)
#define HIDDEN   ((const void *)&h_hidden)
#define DIALOG   ((const void *)&h_dialog)
#define LAUNCHER ((const void *)&h_launcher)
#define IME      ((const void *)&h_ime)

int main(void)
{
    const unsigned game_pid = 0x64, launcher_pid = 0x40;

    /* WoW's case: its one visible window, under a hidden 1x1 helper, comes back. */
    {
        host_focus_window w[] = {
            { HIDDEN, game_pid, WS_POPUP, 0 },
            { GAME, game_pid, WS_VISIBLE | WS_CAPTION, 0 },
            { LAUNCHER, launcher_pid, WS_VISIBLE | WS_POPUP, 0 },
        };
        CHECK(host_focus_pick(w, 3, GAME, game_pid) == 1);
        /* No saved window (fg was already 0 at the loss): the topmost activatable one. */
        CHECK(host_focus_pick(w, 3, NULL, 0) == 1);
        /* Only its process known: its topmost activatable window. */
        CHECK(host_focus_pick(w, 3, NULL, game_pid) == 1);
    }

    /* The saved window stays first even when another process's is above it. */
    {
        host_focus_window w[] = {
            { LAUNCHER, launcher_pid, WS_VISIBLE | WS_POPUP, 0 },
            { GAME, game_pid, WS_VISIBLE | WS_CAPTION, 0 },
        };
        CHECK(host_focus_pick(w, 2, GAME, game_pid) == 1);
    }

    /* Behind a modal dialog the saved window is disabled: the dialog, its process's top window. */
    {
        host_focus_window w[] = {
            { LAUNCHER, launcher_pid, WS_VISIBLE | WS_POPUP, 0 },
            { DIALOG, game_pid, WS_VISIBLE | WS_POPUP | WS_CAPTION, 0 },
            { GAME, game_pid, WS_VISIBLE | WS_CAPTION | WS_DISABLED, 0 },
        };
        CHECK(host_focus_pick(w, 3, GAME, game_pid) == 1);
    }

    /* Hidden, minimized, WS_EX_NOACTIVATE and child-styled windows are passed over. */
    {
        host_focus_window w[] = {
            { HIDDEN, game_pid, WS_POPUP, 0 },
            { IME, game_pid, WS_VISIBLE | WS_POPUP, WS_EX_NOACTIVATE },
            { DIALOG, game_pid, WS_VISIBLE | WS_CHILD, 0 },
            { GAME, game_pid, WS_VISIBLE | WS_CAPTION | WS_MINIMIZE, 0 },
            { LAUNCHER, launcher_pid, WS_VISIBLE | WS_CAPTION, 0 },
        };
        CHECK(host_focus_pick(w, 5, GAME, game_pid) == 4);   /* none of the game's: any process's */
        CHECK(host_focus_pick(w, 4, GAME, game_pid) == -1);  /* none at all */
    }

    /* The saved window is gone (not listed): the topmost of its process. */
    {
        host_focus_window w[] = {
            { LAUNCHER, launcher_pid, WS_VISIBLE | WS_POPUP, 0 },
            { DIALOG, game_pid, WS_VISIBLE | WS_POPUP, 0 },
        };
        CHECK(host_focus_pick(w, 2, GAME, game_pid) == 1);
    }

    /* Nothing listed. */
    CHECK(host_focus_pick(NULL, 0, GAME, game_pid) == -1);

    if (failures) {
        printf("focus_test: %d failure(s)\n", failures);
        return 1;
    }
    printf("focus_test: ok\n");
    return 0;
}
