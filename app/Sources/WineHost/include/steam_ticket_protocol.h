/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * steam_ticket_protocol.h — the unix call table through which the game's
 * Steam API emulator (patches/gbe) asks the host for Steam's auth session and
 * web API tickets during a play (decision 0062). The emulator reaches it as
 * any Wine library reaches its unix side: NtQueryVirtualMemory(
 * MemoryWineLoadUnixLib) on its own module, which the runtime answers with
 * playport_steam_unix_call_funcs by the module's export name (steam_api,
 * patches/madeira-unix), then __wine_unix_call(handle, code, args).
 *
 * Every argument block is fixed-size with no pointers, so an i386 game's
 * blocks (through WoW64) have the same layout and the same table serves both.
 * Each starts with PP_STEAM_MAGIC and its own size; a block that does not
 * match is refused, not read. The emulator carries its own copy of this file.
 *
 * What crosses: ticket bytes, a handle and a state. No token, no SteamID, and
 * no app ID: the host makes every ticket for the app it launched.
 */

#ifndef STEAM_TICKET_PROTOCOL_H
#define STEAM_TICKET_PROTOCOL_H

#include <stdint.h>

#define PP_STEAM_MAGIC 0x54535050u /* "PPST" */
#define PP_STEAM_PROTOCOL 1u
#define PP_STEAM_IDENTITY_MAX 256
#define PP_STEAM_TICKET_MAX 2560   /* GetTicketForWebApiResponse_t's buffer */

enum pp_steam_call {
    PP_STEAM_HELLO = 0,   /* pp_steam_hello: once at the emulator's start */
    PP_STEAM_CREATE = 1,  /* pp_steam_create: a new ticket */
    PP_STEAM_STATUS = 2,  /* pp_steam_status: has Steam taken it */
    PP_STEAM_CANCEL = 3,  /* pp_steam_cancel: the game is done with it */
    PP_STEAM_CALLS = 4
};

enum pp_steam_ticket_type { PP_STEAM_TICKET_SESSION = 2, PP_STEAM_TICKET_WEB_API = 5 };

/* STATUS states: Steam's ack (or 10 s without one) makes a ticket acked; a
 * server's refusal or the session's end makes it failed. */
enum pp_steam_state { PP_STEAM_PENDING = 0, PP_STEAM_ACKED = 1, PP_STEAM_FAILED = 2 };

/* NTSTATUS values the calls return. NOT_SUPPORTED: no play is armed (or no
 * host at all); the emulator then makes up its own ticket, as at its pin. */
#define PP_STEAM_OK 0x00000000u
#define PP_STEAM_NOT_SUPPORTED 0xC00000BBu
#define PP_STEAM_INVALID_PARAMETER 0xC000000Du
#define PP_STEAM_INVALID_HANDLE 0xC0000008u
#define PP_STEAM_QUOTA_EXCEEDED 0xC0000044u   /* too many live, or too often */
#define PP_STEAM_NO_MORE_ENTRIES 0x8000001Au  /* Steam has no token left */

typedef struct {
    uint32_t magic, size;
    uint32_t version;   /* in: the emulator's PP_STEAM_PROTOCOL; out: the host's */
    uint32_t armed;     /* out: 1 when this play's tickets are armed */
} pp_steam_hello;

typedef struct {
    uint32_t magic, size;
    uint32_t type;                            /* in: pp_steam_ticket_type */
    char identity[PP_STEAM_IDENTITY_MAX];     /* in: NUL-terminated; "" binds nothing.
                                                 A web API ticket's identity string, or a
                                                 session ticket's SteamNetworkingIdentity
                                                 in its string form ("steamid:…", "ip:…") */
    uint32_t handle;                          /* out: nonzero */
    uint32_t ticket_size;                     /* out: bytes in ticket */
    uint8_t ticket[PP_STEAM_TICKET_MAX];      /* out */
} pp_steam_create;

typedef struct {
    uint32_t magic, size;
    uint32_t handle;    /* in */
    uint32_t state;     /* out: pp_steam_state */
    uint32_t eresult;   /* out: a refusing server's EAuthSessionResponse, else 0 */
} pp_steam_status;

typedef struct {
    uint32_t magic, size;
    uint32_t handle;    /* in */
} pp_steam_cancel;

/* Whether a block is what the call expects: its magic, its size, and for
 * CREATE a known type and a NUL inside the identity. */
static inline int pp_steam_block_valid(unsigned code, const void *args)
{
    const uint32_t *h = (const uint32_t *)args;
    if (!h || h[0] != PP_STEAM_MAGIC) return 0;
    switch (code) {
    case PP_STEAM_HELLO: return h[1] == sizeof(pp_steam_hello);
    case PP_STEAM_STATUS: return h[1] == sizeof(pp_steam_status);
    case PP_STEAM_CANCEL: return h[1] == sizeof(pp_steam_cancel);
    case PP_STEAM_CREATE: {
        const pp_steam_create *c = (const pp_steam_create *)args;
        if (h[1] != sizeof(pp_steam_create)) return 0;
        if (c->type != PP_STEAM_TICKET_SESSION && c->type != PP_STEAM_TICKET_WEB_API) return 0;
        for (int i = 0; i < PP_STEAM_IDENTITY_MAX; i++)
            if (c->identity[i] == 0) return 1;
        return 0;
    }
    default: return 0;
    }
}

#endif /* STEAM_TICKET_PROTOCOL_H */
