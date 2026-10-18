/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * steam_client_test.c — steam_client.c on the Linux host (pp test): the unix
 * call table of Playport's steamclient64.dll (decision 0115) checks every block
 * before the provider sees it, answers NOT_SUPPORTED with no provider, keeps
 * one pointer-free layout, and bounds what the provider writes.
 */
#include "wine_host.h"
#include "steam_client_protocol.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

extern const void *playport_steamclient_unix_call_funcs[];
typedef unsigned (*call_fn)(void *);
static unsigned call(unsigned code, void *args) { return ((call_fn)playport_steamclient_unix_call_funcs[code])(args); }

static unsigned called_method, cancelled, oversize;
static char called_identity[PP_SC_IDENTITY_MAX], logged[PP_SC_LOG_MAX];

static unsigned p_hello(void *args)
{
    pp_sc_hello *h = args;
    h->steam_id = 76561197960287930ull;
    h->app_id = 1174180;
    h->logged_on = 1;
    h->owns_app = 1;
    memset(h->persona, 'p', sizeof h->persona);   /* no NUL: the table ends it */
    strcpy(h->language, "english");
    return 1;
}
static unsigned p_call(void *args)
{
    pp_sc_call *c = args;
    called_method = c->method;
    strncpy(called_identity, c->identity, sizeof(called_identity) - 1);
    switch (c->method) {
    case PP_SC_TICKET_SESSION:
    case PP_SC_TICKET_WEB_API:
        memcpy(c->data, "abc", 3);
        c->data_size = oversize ? PP_SC_DATA_MAX + 1 : 3;
        c->handle = 7;
        return PP_SC_OK;
    case PP_SC_TICKET_CANCEL: cancelled = c->handle; return PP_SC_OK;
    case PP_SC_APP_TICKET: return PP_SC_NO_MORE_ENTRIES;
    }
    return PP_SC_INVALID_PARAMETER;
}
static unsigned p_poll(void *args)
{
    pp_sc_poll *s = args;
    if (s->handle != 7) return PP_SC_INVALID_HANDLE;
    s->state = PP_SC_ACKED;
    return PP_SC_OK;
}
static void p_log(const char *text) { strncpy(logged, text, sizeof(logged) - 1); }
static const wine_host_steamclient_provider provider = { p_hello, p_call, p_poll, p_log };

static void fresh_call(pp_sc_call *c, unsigned method)
{
    memset(c, 0, sizeof *c);
    c->magic = PP_SC_MAGIC; c->size = sizeof *c; c->method = method;
}

int main(void)
{
    /* One layout for x86-64 and i386: fixed sizes, no pointers, the SteamID 8-aligned. */
    CHECK(sizeof(pp_sc_hello) == 208);
    CHECK(offsetof(pp_sc_hello, persona) == 48);
    CHECK(offsetof(pp_sc_hello, steam_id) == 16);
    CHECK(sizeof(pp_sc_call) == 2840);
    CHECK(sizeof(pp_sc_poll) == 24);
    CHECK(sizeof(pp_sc_log) == 248);

    pp_sc_hello h;
    memset(&h, 0, sizeof h);
    h.magic = PP_SC_MAGIC; h.size = sizeof h; h.version = PP_SC_PROTOCOL; h.armed = 9;
    pp_sc_call c;
    pp_sc_poll s = { PP_SC_MAGIC, sizeof s, 7, 9, 9, 0 };
    pp_sc_log l = { PP_SC_MAGIC, sizeof l, "ISteamUser022 slot 13 GetAuthSessionTicket" };

    /* No provider: NOT_SUPPORTED, and the out fields say nothing. */
    wine_host_set_steamclient_provider(NULL);
    CHECK(call(PP_SC_HELLO, &h) == PP_SC_NOT_SUPPORTED && h.armed == 0 && h.version == PP_SC_PROTOCOL && h.app_id == 0);
    fresh_call(&c, PP_SC_TICKET_SESSION);
    CHECK(call(PP_SC_CALL, &c) == PP_SC_NOT_SUPPORTED && c.handle == 0 && c.data_size == 0);
    CHECK(call(PP_SC_POLL, &s) == PP_SC_NOT_SUPPORTED && s.state == PP_SC_FAILED && s.eresult == 0);
    CHECK(call(PP_SC_LOG, &l) == PP_SC_NOT_SUPPORTED);

    wine_host_set_steamclient_provider(&provider);
    /* HELLO: the snapshot, its strings ended inside their fields. */
    CHECK(call(PP_SC_HELLO, &h) == PP_SC_OK && h.armed == 1 && h.app_id == 1174180 && h.logged_on && h.owns_app);
    CHECK(h.steam_id == 76561197960287930ull && strlen(h.persona) == PP_SC_PERSONA_MAX - 1 && !strcmp(h.language, "english"));
    /* Another protocol version: refused, with the host's version back. */
    h.version = 99;
    CHECK(call(PP_SC_HELLO, &h) == PP_SC_NOT_SUPPORTED && h.version == PP_SC_PROTOCOL && h.armed == 0);

    /* CALL: a ticket with its identity; a cancel's handle reaches the provider. */
    fresh_call(&c, PP_SC_TICKET_WEB_API);
    strcpy(c.identity, "rockstar");
    CHECK(call(PP_SC_CALL, &c) == PP_SC_OK && c.handle == 7 && c.data_size == 3 && !memcmp(c.data, "abc", 3));
    CHECK(called_method == PP_SC_TICKET_WEB_API && !strcmp(called_identity, "rockstar"));
    fresh_call(&c, PP_SC_TICKET_CANCEL);
    c.handle = 7;
    CHECK(call(PP_SC_CALL, &c) == PP_SC_OK && cancelled == 7);
    fresh_call(&c, PP_SC_APP_TICKET);
    CHECK(call(PP_SC_CALL, &c) == PP_SC_NO_MORE_ENTRIES && c.data_size == 0);
    /* A provider that claims more than the block holds is not believed. */
    oversize = 1;
    fresh_call(&c, PP_SC_TICKET_SESSION);
    CHECK(call(PP_SC_CALL, &c) == PP_SC_NOT_SUPPORTED && c.data_size == 0);
    oversize = 0;

    /* POLL. */
    CHECK(call(PP_SC_POLL, &s) == PP_SC_OK && s.state == PP_SC_ACKED);
    s.handle = 8;
    CHECK(call(PP_SC_POLL, &s) == PP_SC_INVALID_HANDLE);

    /* LOG. */
    CHECK(call(PP_SC_LOG, &l) == PP_SC_OK && !strcmp(logged, "ISteamUser022 slot 13 GetAuthSessionTicket"));

    /* Malformed blocks never reach the provider. */
    called_method = 0;
    fresh_call(&c, PP_SC_TICKET_SESSION);
    c.magic = 0;
    CHECK(call(PP_SC_CALL, &c) == PP_SC_INVALID_PARAMETER);
    fresh_call(&c, PP_SC_TICKET_SESSION);
    c.size = sizeof c - 1;
    CHECK(call(PP_SC_CALL, &c) == PP_SC_INVALID_PARAMETER);
    fresh_call(&c, PP_SC_METHODS);
    CHECK(call(PP_SC_CALL, &c) == PP_SC_INVALID_PARAMETER);
    fresh_call(&c, 0);
    CHECK(call(PP_SC_CALL, &c) == PP_SC_INVALID_PARAMETER);
    fresh_call(&c, PP_SC_TICKET_WEB_API);
    memset(c.identity, 'x', sizeof c.identity);
    CHECK(call(PP_SC_CALL, &c) == PP_SC_INVALID_PARAMETER);
    CHECK(called_method == 0);
    memset(l.text, 'x', sizeof l.text);
    logged[0] = 0;
    CHECK(call(PP_SC_LOG, &l) == PP_SC_INVALID_PARAMETER && logged[0] == 0);
    h.size = 8;
    CHECK(call(PP_SC_HELLO, &h) == PP_SC_INVALID_PARAMETER);
    CHECK(call(PP_SC_HELLO, NULL) == PP_SC_INVALID_PARAMETER);

    if (failures) return 1;
    printf("steam_client_test: ok\n");
    return 0;
}
