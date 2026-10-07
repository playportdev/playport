/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * The unix call table of the game's Steam API emulator (steam_ticket_protocol.h,
 * decision 0062). The runtime hands it to a module whose export name is a
 * steam_api's (patches/madeira-unix), for x86-64 and, through WoW64, i386 games.
 * Each call checks its block and passes it to the provider the app set
 * (wine_host_set_steam_ticket_provider); with none, it answers NOT_SUPPORTED
 * and the emulator makes up its own tickets.
 */

#include "wine_host.h"
#include "steam_ticket_protocol.h"

#include <stdatomic.h>
#include <string.h>

static _Atomic(const wine_host_steam_ticket_provider *) g_provider;

void wine_host_set_steam_ticket_provider(const wine_host_steam_ticket_provider *provider)
{
    atomic_store(&g_provider, provider);
}

static unsigned steam_hello(void *args)
{
    pp_steam_hello *h = args;
    const wine_host_steam_ticket_provider *p = atomic_load(&g_provider);
    if (!pp_steam_block_valid(PP_STEAM_HELLO, args)) return PP_STEAM_INVALID_PARAMETER;
    unsigned theirs = h->version;
    h->version = PP_STEAM_PROTOCOL;
    h->armed = 0;
    if (!p || !p->hello || theirs != PP_STEAM_PROTOCOL) return PP_STEAM_NOT_SUPPORTED;
    h->armed = p->hello() ? 1 : 0;
    return PP_STEAM_OK;
}

static unsigned steam_create(void *args)
{
    pp_steam_create *c = args;
    const wine_host_steam_ticket_provider *p = atomic_load(&g_provider);
    unsigned handle = 0, size = 0, rc;
    if (!pp_steam_block_valid(PP_STEAM_CREATE, args)) return PP_STEAM_INVALID_PARAMETER;
    c->handle = 0;
    c->ticket_size = 0;
    if (!p || !p->create) return PP_STEAM_NOT_SUPPORTED;
    rc = p->create(c->type, c->identity, &handle, c->ticket, sizeof(c->ticket), &size);
    if (rc != PP_STEAM_OK) return rc;
    if (!handle || size > sizeof(c->ticket)) return PP_STEAM_NOT_SUPPORTED;
    c->handle = handle;
    c->ticket_size = size;
    return PP_STEAM_OK;
}

static unsigned steam_status(void *args)
{
    pp_steam_status *s = args;
    const wine_host_steam_ticket_provider *p = atomic_load(&g_provider);
    unsigned state = PP_STEAM_FAILED, eresult = 0, rc;
    if (!pp_steam_block_valid(PP_STEAM_STATUS, args)) return PP_STEAM_INVALID_PARAMETER;
    if (!p || !p->status) return PP_STEAM_NOT_SUPPORTED;
    rc = p->status(s->handle, &state, &eresult);
    s->state = state;
    s->eresult = eresult;
    return rc;
}

static unsigned steam_cancel(void *args)
{
    pp_steam_cancel *c = args;
    const wine_host_steam_ticket_provider *p = atomic_load(&g_provider);
    if (!pp_steam_block_valid(PP_STEAM_CANCEL, args)) return PP_STEAM_INVALID_PARAMETER;
    if (!p || !p->cancel) return PP_STEAM_NOT_SUPPORTED;
    return p->cancel(c->handle);
}

/* Indexed by enum pp_steam_call, as Wine's dispatcher indexes every unix table. */
const void *playport_steam_unix_call_funcs[PP_STEAM_CALLS] = {
    (const void *)steam_hello,
    (const void *)steam_create,
    (const void *)steam_status,
    (const void *)steam_cancel,
};
