/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * steamclient_calls_test.c — the callbacks and call results Playport's Steam
 * client makes (app/SteamClientShim/steamclient_calls.h) on the Linux host
 * (pp test): the Windows layout of each struct; RequestCurrentStats' posted
 * UserStatsReceived_t; RequestUserStats' and CreateLobby's call results through
 * SteamAPICallCompleted_t, IsAPICallCompleted and GetAPICallResult, as steam_api
 * and a game polling by hand take them; the bounds; the DLC lookup.
 */
#include "../SteamClientShim/steamclient_calls.h"

#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

/* The SDK's structs as MSVC lays them out under steam_api's pack 8. */
#pragma pack(push, 8)
typedef struct { uint64_t game; int32_t eresult; uint64_t user; } user_stats_received_t;
typedef struct { int32_t eresult; uint64_t lobby; } lobby_created_t;
typedef struct { uint64_t call; int32_t callback; uint32_t size; } call_completed_t;
#pragma pack(pop)

static const uint64_t me = 76561197960287930ull;

int main(void)
{
    static pp_cb_queue q;
    pp_cb_record r;
    uint8_t d[PP_CB_DATA_MAX], buf[64], failed;

    /* Layouts: the bytes a game reads through its own struct. */
    CHECK(pp_cb_user_stats_received(d, 49520, PP_ER_FAIL, me) == sizeof(user_stats_received_t));
    {
        user_stats_received_t u;
        memcpy(&u, d, sizeof u);
        CHECK(u.game == 49520 && u.eresult == PP_ER_FAIL && u.user == me);
    }
    CHECK(pp_cb_lobby_created(d, PP_ER_FAIL, 0) == sizeof(lobby_created_t));
    {
        lobby_created_t l;
        memcpy(&l, d, sizeof l);
        CHECK(l.eresult == PP_ER_FAIL && l.lobby == 0);
    }
    CHECK(sizeof(pp_sc_dlc) == 8 && PP_SC_DLC_MAX == 320);

    /* RequestCurrentStats: a posted UserStatsReceived_t, handed out once. */
    CHECK(!pp_cb_next(&q, &r));
    CHECK(pp_cb_post(&q, PP_CB_USER_STATS_RECEIVED, d, pp_cb_user_stats_received(d, 49520, PP_ER_FAIL, me)));
    CHECK(pp_cb_next(&q, &r) && r.callback == PP_CB_USER_STATS_RECEIVED && r.size == 24);
    {
        user_stats_received_t u;
        memcpy(&u, r.data, sizeof u);
        CHECK(u.game == 49520 && u.eresult == PP_ER_FAIL && u.user == me);
    }
    CHECK(!pp_cb_next(&q, &r));

    /* RequestUserStats: a handle that is complete at once (a game polling IsAPICallCompleted). */
    uint64_t call = pp_cb_call(&q, PP_CB_USER_STATS_RECEIVED, d, pp_cb_user_stats_received(d, 49520, PP_ER_FAIL, me));
    CHECK(call != 0);
    failed = 9;
    CHECK(pp_cb_completed(&q, call, &failed) && failed == 0);
    /* k_uAPICallInvalid, and a handle never made: not complete, failed. */
    failed = 9;
    CHECK(!pp_cb_completed(&q, 0, &failed) && failed == 1);
    CHECK(!pp_cb_completed(&q, call + 1, &failed) && failed == 1);
    /* steam_api's way: SteamAPICallCompleted_t names the handle, the id and the size. */
    CHECK(pp_cb_next(&q, &r) && r.callback == PP_CB_CALL_COMPLETED && r.size == sizeof(call_completed_t));
    {
        call_completed_t c;
        memcpy(&c, r.data, sizeof c);
        CHECK(c.call == call && c.callback == PP_CB_USER_STATS_RECEIVED && c.size == 24);
    }
    CHECK(!pp_cb_next(&q, &r));   /* announced once */
    /* GetAPICallResult: the wrong id or a short buffer fails and keeps it; then it is taken once. */
    CHECK(!pp_cb_take(&q, call, buf, sizeof buf, PP_CB_LOBBY_CREATED, &failed) && failed == 1);
    CHECK(!pp_cb_take(&q, call, buf, 16, PP_CB_USER_STATS_RECEIVED, &failed) && failed == 1);
    CHECK(pp_cb_completed(&q, call, &failed));
    memset(buf, 0xAA, sizeof buf);
    CHECK(pp_cb_take(&q, call, buf, 24, PP_CB_USER_STATS_RECEIVED, &failed) && failed == 0);
    {
        user_stats_received_t u;
        memcpy(&u, buf, sizeof u);
        CHECK(u.game == 49520 && u.eresult == PP_ER_FAIL && u.user == me);
    }
    CHECK(!pp_cb_take(&q, call, buf, 24, PP_CB_USER_STATS_RECEIVED, &failed) && failed == 1);
    CHECK(!pp_cb_completed(&q, call, &failed) && failed == 1);

    /* CreateLobby: the call result and the callback; posted callbacks come first. */
    uint32_t n = pp_cb_lobby_created(d, PP_ER_FAIL, 0);
    uint64_t lobby = pp_cb_call(&q, PP_CB_LOBBY_CREATED, d, n);
    CHECK(lobby > call);
    CHECK(pp_cb_post(&q, PP_CB_LOBBY_CREATED, d, n));
    CHECK(pp_cb_next(&q, &r) && r.callback == PP_CB_LOBBY_CREATED && r.size == 16 && !memcmp(r.data, d, 16));
    CHECK(pp_cb_next(&q, &r) && r.callback == PP_CB_CALL_COMPLETED && !memcmp(r.data, &lobby, 8));
    CHECK(pp_cb_take(&q, lobby, buf, sizeof buf, PP_CB_LOBBY_CREATED, &failed) && !memcmp(buf, d, 16));

    /* The encrypted app ticket's EResult-only struct. */
    int32_t eresult = PP_ER_NO_CONNECTION;
    uint64_t t = pp_cb_call(&q, PP_CB_ENCRYPTED_APP_TICKET, &eresult, 4);
    CHECK(pp_cb_next(&q, &r) && r.callback == PP_CB_CALL_COMPLETED);
    CHECK(pp_cb_take(&q, t, buf, 4, PP_CB_ENCRYPTED_APP_TICKET, &failed) && !memcmp(buf, &eresult, 4));

    /* Bounds: posted callbacks wait in order up to PP_CB_SLOTS; a struct too big is refused. */
    CHECK(!pp_cb_post(&q, 1, buf, PP_CB_DATA_MAX + 1) && !pp_cb_call(&q, 1, buf, PP_CB_DATA_MAX + 1));
    for (int i = 0; i < PP_CB_SLOTS; i++) CHECK(pp_cb_post(&q, 1000 + i, d, 4));
    CHECK(!pp_cb_post(&q, 2000, d, 4));
    for (int i = 0; i < PP_CB_SLOTS; i++) CHECK(pp_cb_next(&q, &r) && r.callback == 1000 + i);
    CHECK(!pp_cb_next(&q, &r));
    /* Call results never announced hold their slots; one announced but never taken (no
     * CCallResult in steam_api) gives way to a new one, the oldest first. */
    uint64_t calls[PP_CB_SLOTS];
    for (int i = 0; i < PP_CB_SLOTS; i++) CHECK((calls[i] = pp_cb_call(&q, PP_CB_LOBBY_CREATED, d, n)) != 0);
    CHECK(pp_cb_call(&q, PP_CB_LOBBY_CREATED, d, n) == 0);
    CHECK(pp_cb_next(&q, &r) && !memcmp(r.data, &calls[0], 8));
    CHECK(pp_cb_next(&q, &r) && !memcmp(r.data, &calls[1], 8));
    uint64_t again = pp_cb_call(&q, PP_CB_LOBBY_CREATED, d, n);
    CHECK(again > calls[PP_CB_SLOTS - 1]);
    CHECK(!pp_cb_completed(&q, calls[0], &failed) && pp_cb_completed(&q, calls[1], &failed));

    /* The host's DLC list. */
    pp_sc_dlc list[2] = { { 213230, 1 }, { 218560, 0 } };
    CHECK(pp_dlc_find(list, 2, 213230) == &list[0] && pp_dlc_find(list, 2, 218560)->installed == 0);
    CHECK(!pp_dlc_find(list, 2, 49520) && !pp_dlc_find(list, 2, 0) && !pp_dlc_find(list, 0, 213230));

    if (failures) return 1;
    printf("steamclient_calls_test: ok\n");
    return 0;
}
