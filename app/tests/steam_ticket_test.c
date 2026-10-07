/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * steam_ticket_test.c — steam_ticket.c on the Linux host (pp test): the
 * emulator's unix call table checks every block before the provider sees
 * it, answers NOT_SUPPORTED with no provider, and keeps one layout for
 * x86-64 and i386 (no pointers in a block).
 */
#include "wine_host.h"
#include "steam_ticket_protocol.h"

#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

extern const void *playport_steam_unix_call_funcs[];
typedef unsigned (*call_fn)(void *);
static unsigned call(unsigned code, void *args) { return ((call_fn)playport_steam_unix_call_funcs[code])(args); }

static unsigned created_type, cancelled;
static char created_identity[PP_STEAM_IDENTITY_MAX];
static unsigned p_hello(void) { return 1; }
static unsigned p_create(unsigned type, const char *identity, unsigned *handle, unsigned char *ticket, unsigned cap, unsigned *size)
{
    created_type = type;
    strncpy(created_identity, identity, sizeof(created_identity) - 1);
    if (cap < 3) return PP_STEAM_INVALID_PARAMETER;
    memcpy(ticket, "abc", 3);
    *size = 3;
    *handle = 7;
    return PP_STEAM_OK;
}
static unsigned p_status(unsigned handle, unsigned *state, unsigned *eresult)
{
    if (handle != 7) return PP_STEAM_INVALID_HANDLE;
    *state = PP_STEAM_ACKED;
    *eresult = 0;
    return PP_STEAM_OK;
}
static unsigned p_cancel(unsigned handle) { cancelled = handle; return PP_STEAM_OK; }
static const wine_host_steam_ticket_provider provider = { p_hello, p_create, p_status, p_cancel };

int main(void)
{
    /* One layout for both architectures: fixed sizes, no pointers. */
    CHECK(sizeof(pp_steam_hello) == 16);
    CHECK(sizeof(pp_steam_create) == 2836);
    CHECK(sizeof(pp_steam_status) == 20);
    CHECK(sizeof(pp_steam_cancel) == 12);

    pp_steam_hello h = { PP_STEAM_MAGIC, sizeof h, PP_STEAM_PROTOCOL, 9 };
    pp_steam_create c;
    memset(&c, 0, sizeof c);
    c.magic = PP_STEAM_MAGIC; c.size = sizeof c; c.type = PP_STEAM_TICKET_WEB_API;
    strcpy(c.identity, "epiconlineservices");
    pp_steam_status s = { PP_STEAM_MAGIC, sizeof s, 7, 9, 9 };
    pp_steam_cancel x = { PP_STEAM_MAGIC, sizeof x, 7 };

    /* No provider: every call says the host has nothing, and HELLO still answers its version. */
    CHECK(call(PP_STEAM_HELLO, &h) == PP_STEAM_NOT_SUPPORTED);
    CHECK(h.version == PP_STEAM_PROTOCOL && h.armed == 0);
    CHECK(call(PP_STEAM_CREATE, &c) == PP_STEAM_NOT_SUPPORTED);
    CHECK(c.handle == 0 && c.ticket_size == 0);
    CHECK(call(PP_STEAM_STATUS, &s) == PP_STEAM_NOT_SUPPORTED);
    CHECK(call(PP_STEAM_CANCEL, &x) == PP_STEAM_NOT_SUPPORTED);

    wine_host_set_steam_ticket_provider(&provider);
    h.armed = 9;
    CHECK(call(PP_STEAM_HELLO, &h) == PP_STEAM_OK && h.armed == 1);
    h.version = 2;  /* another protocol: refused, not misread */
    CHECK(call(PP_STEAM_HELLO, &h) == PP_STEAM_NOT_SUPPORTED && h.armed == 0 && h.version == PP_STEAM_PROTOCOL);

    CHECK(call(PP_STEAM_CREATE, &c) == PP_STEAM_OK);
    CHECK(c.handle == 7 && c.ticket_size == 3 && memcmp(c.ticket, "abc", 3) == 0);
    CHECK(created_type == PP_STEAM_TICKET_WEB_API && strcmp(created_identity, "epiconlineservices") == 0);
    CHECK(call(PP_STEAM_STATUS, &s) == PP_STEAM_OK && s.state == PP_STEAM_ACKED && s.eresult == 0);
    s.handle = 8;
    CHECK(call(PP_STEAM_STATUS, &s) == PP_STEAM_INVALID_HANDLE);
    CHECK(call(PP_STEAM_CANCEL, &x) == PP_STEAM_OK && cancelled == 7);

    /* Bad blocks never reach the provider. */
    created_type = 0;
    pp_steam_create bad = c;
    bad.magic = 0;
    CHECK(call(PP_STEAM_CREATE, &bad) == PP_STEAM_INVALID_PARAMETER);
    bad = c; bad.size = sizeof c - 4;
    CHECK(call(PP_STEAM_CREATE, &bad) == PP_STEAM_INVALID_PARAMETER);
    bad = c; bad.type = 3;
    CHECK(call(PP_STEAM_CREATE, &bad) == PP_STEAM_INVALID_PARAMETER);
    bad = c; memset(bad.identity, 'a', sizeof bad.identity);  /* no NUL */
    CHECK(call(PP_STEAM_CREATE, &bad) == PP_STEAM_INVALID_PARAMETER);
    CHECK(created_type == 0);
    pp_steam_status short_status = s;
    short_status.size = 12;
    CHECK(call(PP_STEAM_STATUS, &short_status) == PP_STEAM_INVALID_PARAMETER);
    CHECK(!pp_steam_block_valid(PP_STEAM_CALLS, &h));
    CHECK(!pp_steam_block_valid(PP_STEAM_HELLO, NULL));

    wine_host_set_steam_ticket_provider(NULL);
    CHECK(call(PP_STEAM_CREATE, &c) == PP_STEAM_NOT_SUPPORTED);

    if (failures) return 1;
    printf("steam tickets: all passed\n");
    return 0;
}
