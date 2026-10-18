/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * steam_client_protocol.h — the unix call table through which Playport's
 * steamclient64.dll (app/SteamClientShim, decision 0115) asks the host for what
 * Steam's client gives a game: a snapshot of the account for the launched app,
 * auth session and web API tickets (the play's SteamTicketBroker, decision 0062)
 * and the encrypted app ticket fetched at Play (decision 0017). The shim
 * reaches it as any Wine library reaches its unix side: NtQueryVirtualMemory(
 * MemoryWineLoadUnixLib) on its own module, which the runtime answers with
 * playport_steamclient_unix_call_funcs by the module's export name
 * (steamclient, patches/madeira-unix), then __wine_unix_call(handle, code, args).
 *
 * The rules are 0087's: every block is fixed-size with no pointers, starts
 * with PP_SC_MAGIC and its own size, and is refused, not read, when either is
 * wrong. Callbacks and call results are made by the shim: nothing on the host
 * answers later, so there is no host queue. The shim carries no copy of
 * anything else: no token, no key, and no other app's data (the host answers
 * for the app it launched only).
 */

#ifndef STEAM_CLIENT_PROTOCOL_H
#define STEAM_CLIENT_PROTOCOL_H

#include <stdint.h>

#define PP_SC_MAGIC 0x43535050u /* "PPSC" */
#define PP_SC_PROTOCOL 1u
#define PP_SC_PERSONA_MAX 128
#define PP_SC_LANGUAGE_MAX 32
#define PP_SC_IDENTITY_MAX 256
#define PP_SC_DATA_MAX 2560      /* GetTicketForWebApiResponse_t's buffer */
#define PP_SC_LOG_MAX 240

enum pp_sc_code {
    PP_SC_HELLO = 0,   /* pp_sc_hello: once, at the shim's first use */
    PP_SC_CALL = 1,    /* pp_sc_call: one method that needs the host */
    PP_SC_POLL = 2,    /* pp_sc_poll: a ticket's state, for its callback */
    PP_SC_LOG = 3,     /* pp_sc_log: a line for the app log (`steamclient:`) */
    PP_SC_CALLS = 4
};

/* PP_SC_CALL's methods. */
enum pp_sc_method {
    PP_SC_TICKET_SESSION = 1,  /* GetAuthSessionTicket: handle and bytes out */
    PP_SC_TICKET_WEB_API = 2,  /* GetAuthTicketForWebApi: handle and bytes out */
    PP_SC_TICKET_CANCEL = 3,   /* CancelAuthTicket: handle in */
    PP_SC_APP_TICKET = 4,      /* the encrypted app ticket fetched at Play: bytes out */
    PP_SC_METHODS = 5
};

/* POLL's states, as the ticket broker's. */
enum pp_sc_state { PP_SC_PENDING = 0, PP_SC_ACKED = 1, PP_SC_FAILED = 2 };

/* NTSTATUS values the calls return. NOT_SUPPORTED: no play is armed, or no
 * host; the shim then answers as Steam's client does when not logged on. */
#define PP_SC_OK 0x00000000u
#define PP_SC_NOT_SUPPORTED 0xC00000BBu
#define PP_SC_INVALID_PARAMETER 0xC000000Du
#define PP_SC_INVALID_HANDLE 0xC0000008u
#define PP_SC_QUOTA_EXCEEDED 0xC0000044u    /* too many live tickets, or too often */
#define PP_SC_NO_MORE_ENTRIES 0x8000001Au   /* Steam has no token (or no app ticket) */

typedef struct {
    uint32_t magic, size;
    uint32_t version;    /* in: the shim's PP_SC_PROTOCOL; out: the host's */
    uint32_t armed;      /* out: 1 when this play's client is armed */
    uint64_t steam_id;   /* out: the account's SteamID64, 0 when not known */
    uint32_t app_id;     /* out: the launched app */
    uint32_t logged_on;  /* out: 1 when the host's session is logged on for the play */
    uint32_t owns_app;   /* out: 1 when the account owns the launched app */
    uint32_t tickets;    /* out: 1 when auth tickets are armed */
    char persona[PP_SC_PERSONA_MAX];    /* out: NUL-terminated UTF-8 */
    char language[PP_SC_LANGUAGE_MAX];  /* out: a Steam API language code, NUL-terminated */
} pp_sc_hello;

typedef struct {
    uint32_t magic, size;
    uint32_t method;                       /* in: pp_sc_method */
    uint32_t handle;                       /* in (CANCEL), out (tickets): nonzero */
    char identity[PP_SC_IDENTITY_MAX];     /* in (tickets): NUL-terminated; "" binds nothing */
    uint32_t data_size;                    /* out: bytes in data */
    uint32_t reserved;
    uint8_t data[PP_SC_DATA_MAX];          /* out */
} pp_sc_call;

typedef struct {
    uint32_t magic, size;
    uint32_t handle;    /* in */
    uint32_t state;     /* out: pp_sc_state */
    uint32_t eresult;   /* out: a refusing server's EAuthSessionResponse, else 0 */
    uint32_t reserved;
} pp_sc_poll;

typedef struct {
    uint32_t magic, size;
    char text[PP_SC_LOG_MAX];   /* in: NUL-terminated */
} pp_sc_log;

static inline int pp_sc_has_nul(const char *s, int n)
{
    for (int i = 0; i < n; i++)
        if (s[i] == 0) return 1;
    return 0;
}

/* Whether a block is what the call expects: its magic, its size, and for
 * CALL a known method and a NUL inside the identity, for LOG a NUL in the text. */
static inline int pp_sc_block_valid(unsigned code, const void *args)
{
    const uint32_t *h = (const uint32_t *)args;
    if (!h || h[0] != PP_SC_MAGIC) return 0;
    switch (code) {
    case PP_SC_HELLO: return h[1] == sizeof(pp_sc_hello);
    case PP_SC_POLL: return h[1] == sizeof(pp_sc_poll);
    case PP_SC_LOG:
        return h[1] == sizeof(pp_sc_log) && pp_sc_has_nul(((const pp_sc_log *)args)->text, PP_SC_LOG_MAX);
    case PP_SC_CALL: {
        const pp_sc_call *c = (const pp_sc_call *)args;
        if (h[1] != sizeof(pp_sc_call)) return 0;
        if (c->method == 0 || c->method >= PP_SC_METHODS) return 0;
        return pp_sc_has_nul(c->identity, PP_SC_IDENTITY_MAX);
    }
    default: return 0;
    }
}

#endif /* STEAM_CLIENT_PROTOCOL_H */
