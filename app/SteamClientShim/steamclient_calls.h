/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * steamclient_calls.h — the callbacks and call results Playport's Steam client
 * (steamclient.c, decision 0115) makes for a game, guest side, and the launched
 * app's DLC as the host lists it (PP_SC_DLC).
 *
 * A request that Steam answers later (RequestCurrentStats, RequestUserStats,
 * CreateLobby, RequestEncryptedAppTicket) is answered at once here: a posted
 * callback (its struct, handed out by Steam_BGetCallback), or a call result (a
 * SteamAPICall_t handle, then SteamAPICallCompleted_t from Steam_BGetCallback,
 * then the struct from GetAPICallResult). A game that polls IsAPICallCompleted
 * itself sees the call completed from the start.
 *
 * Each struct is written in its Windows layout, which steam_api packs at 8 on
 * x86-64 and i386 alike (VALVE_CALLBACK_PACK_LARGE): the same bytes for both.
 *
 * Freestanding (no C runtime), as the DLL is; the host C test
 * (app/tests/steamclient_calls_test.c) builds it on Linux.
 */

#ifndef STEAMCLIENT_CALLS_H
#define STEAMCLIENT_CALLS_H

#include <stdint.h>
#include "../Sources/WineHost/include/steam_client_protocol.h"

#define PP_CB_SLOTS 16       /* posted callbacks waiting, and call results not taken */
#define PP_CB_DATA_MAX 32    /* the largest struct made here */

/* Callback ids (k_iCallback). */
#define PP_CB_ENCRYPTED_APP_TICKET 154   /* EncryptedAppTicketResponse_t */
#define PP_CB_LOBBY_CREATED 513          /* LobbyCreated_t */
#define PP_CB_CALL_COMPLETED 703         /* SteamAPICallCompleted_t */
#define PP_CB_USER_STATS_RECEIVED 1101   /* UserStatsReceived_t */

/* EResult. */
#define PP_ER_OK 1
#define PP_ER_FAIL 2
#define PP_ER_NO_CONNECTION 3

typedef struct {
    int32_t callback;
    uint32_t size;
    uint8_t data[PP_CB_DATA_MAX];
} pp_cb_record;

typedef struct {
    pp_cb_record posted[PP_CB_SLOTS];   /* a ring, oldest first */
    unsigned first, count;
    struct {
        uint64_t call;       /* 0: a free slot */
        int announced;       /* its SteamAPICallCompleted_t was handed out */
        pp_cb_record r;
    } results[PP_CB_SLOTS];
    uint64_t last_call;
} pp_cb_queue;

static inline void pp_cb_copy(void *d, const void *s, uint32_t n)
{
    uint8_t *p = d;
    const uint8_t *q = s;
    while (n--) *p++ = *q++;
}

static inline void pp_cb_zero(void *d, uint32_t n)
{
    uint8_t *p = d;
    while (n--) *p++ = 0;
}

static inline void pp_cb_fill(pp_cb_record *r, int32_t callback, const void *data, uint32_t size)
{
    pp_cb_zero(r, sizeof(*r));
    r->callback = callback;
    r->size = size;
    pp_cb_copy(r->data, data, size);
}

/* A callback for Steam_BGetCallback, after those already posted. 0 when the queue is full
 * (a game that never pumps callbacks) or the struct does not fit. */
static inline int pp_cb_post(pp_cb_queue *q, int32_t callback, const void *data, uint32_t size)
{
    if (q->count >= PP_CB_SLOTS || size > PP_CB_DATA_MAX) return 0;
    pp_cb_fill(&q->posted[(q->first + q->count) % PP_CB_SLOTS], callback, data, size);
    q->count++;
    return 1;
}

/* A call result, complete now: its handle, or 0 (k_uAPICallInvalid) when the struct does not
 * fit or every slot holds a result whose SteamAPICallCompleted_t is still to be handed out.
 * A result already announced but never taken (steam_api had no CCallResult for it) gives up
 * its slot to a new one, the oldest first. */
static inline uint64_t pp_cb_call(pp_cb_queue *q, int32_t callback, const void *data, uint32_t size)
{
    int slot = -1;
    if (size > PP_CB_DATA_MAX) return 0;
    for (int i = 0; i < PP_CB_SLOTS && slot < 0; i++)
        if (!q->results[i].call) slot = i;
    if (slot < 0)
        for (int i = 0; i < PP_CB_SLOTS; i++)
            if (q->results[i].announced && (slot < 0 || q->results[i].call < q->results[slot].call)) slot = i;
    if (slot < 0) return 0;
    q->results[slot].call = ++q->last_call;
    q->results[slot].announced = 0;
    pp_cb_fill(&q->results[slot].r, callback, data, size);
    return q->results[slot].call;
}

/* The next callback for Steam_BGetCallback: the oldest posted one, else the
 * SteamAPICallCompleted_t of the oldest call result not yet announced. 0 for none. */
static inline int pp_cb_next(pp_cb_queue *q, pp_cb_record *out)
{
    int slot = -1;
    if (q->count) {
        *out = q->posted[q->first];
        q->first = (q->first + 1) % PP_CB_SLOTS;
        q->count--;
        return 1;
    }
    for (int i = 0; i < PP_CB_SLOTS; i++)
        if (q->results[i].call && !q->results[i].announced && (slot < 0 || q->results[i].call < q->results[slot].call))
            slot = i;
    if (slot < 0) return 0;
    q->results[slot].announced = 1;
    pp_cb_zero(out, sizeof(*out));
    out->callback = PP_CB_CALL_COMPLETED;
    out->size = 16;   /* uint64 m_hAsyncCall, int m_iCallback, uint32 m_cubParam */
    pp_cb_copy(out->data, &q->results[slot].call, 8);
    pp_cb_copy(out->data + 8, &q->results[slot].r.callback, 4);
    pp_cb_copy(out->data + 12, &q->results[slot].r.size, 4);
    return 1;
}

/* IsAPICallCompleted: 1 for a result not yet taken; an unknown handle is not completed and failed. */
static inline int pp_cb_completed(const pp_cb_queue *q, uint64_t call, uint8_t *failed)
{
    for (int i = 0; call && i < PP_CB_SLOTS; i++)
        if (q->results[i].call == call) {
            if (failed) *failed = 0;
            return 1;
        }
    if (failed) *failed = 1;
    return 0;
}

/* GetAPICallResult: the struct, once, into a buffer of at least its size, for the callback id it
 * is. A wrong id or a short buffer fails and keeps the result; an unknown handle fails. */
static inline int pp_cb_take(pp_cb_queue *q, uint64_t call, void *buf, int size, int expected, uint8_t *failed)
{
    for (int i = 0; call && i < PP_CB_SLOTS; i++) {
        if (q->results[i].call != call) continue;
        if (expected != q->results[i].r.callback || size < 0 || (uint32_t)size < q->results[i].r.size || !buf) break;
        pp_cb_copy(buf, q->results[i].r.data, q->results[i].r.size);
        q->results[i].call = 0;
        if (failed) *failed = 0;
        return 1;
    }
    if (failed) *failed = 1;
    return 0;
}

/* UserStatsReceived_t: uint64 m_nGameID (a Steam app's CGameID is its app id), EResult
 * m_eResult, 4 bytes of padding, CSteamID m_steamIDUser. */
static inline uint32_t pp_cb_user_stats_received(uint8_t *d, uint32_t app, int32_t eresult, uint64_t user)
{
    uint64_t game = app;
    pp_cb_zero(d, 24);
    pp_cb_copy(d, &game, 8);
    pp_cb_copy(d + 8, &eresult, 4);
    pp_cb_copy(d + 16, &user, 8);
    return 24;
}

/* LobbyCreated_t: EResult m_eResult, 4 bytes of padding, uint64 m_ulSteamIDLobby. */
static inline uint32_t pp_cb_lobby_created(uint8_t *d, int32_t eresult, uint64_t lobby)
{
    pp_cb_zero(d, 16);
    pp_cb_copy(d, &eresult, 4);
    pp_cb_copy(d + 8, &lobby, 8);
    return 16;
}

/* The host's entry for a DLC app of the launched app the account owns (PP_SC_DLC), or NULL:
 * an app the list lacks is not owned. */
static inline const pp_sc_dlc *pp_dlc_find(const pp_sc_dlc *list, uint32_t n, uint32_t app)
{
    for (uint32_t i = 0; app && i < n; i++)
        if (list[i].app_id == app) return &list[i];
    return 0;
}

#endif /* STEAMCLIENT_CALLS_H */
