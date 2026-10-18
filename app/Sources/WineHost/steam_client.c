/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * The unix call table of Playport's steamclient64.dll (steam_client_protocol.h,
 * decision 0115). The runtime hands it to a module whose export name is a
 * steamclient's (patches/madeira-unix). Each call checks its block and passes
 * it to the provider the app set (wine_host_set_steamclient_provider); with
 * none, it answers NOT_SUPPORTED and the shim answers as Steam's client does
 * when not logged on.
 */

#include "wine_host.h"
#include "steam_client_protocol.h"

#include <stdatomic.h>
#include <string.h>

static _Atomic(const wine_host_steamclient_provider *) g_provider;

void wine_host_set_steamclient_provider(const wine_host_steamclient_provider *provider)
{
    atomic_store(&g_provider, provider);
}

static unsigned sc_hello(void *args)
{
    pp_sc_hello *h = args;
    const wine_host_steamclient_provider *p = atomic_load(&g_provider);
    if (!pp_sc_block_valid(PP_SC_HELLO, args)) return PP_SC_INVALID_PARAMETER;
    unsigned theirs = h->version;
    memset((char *)h + 8, 0, sizeof(*h) - 8);
    h->version = PP_SC_PROTOCOL;
    if (!p || !p->hello || theirs != PP_SC_PROTOCOL) return PP_SC_NOT_SUPPORTED;
    h->armed = p->hello(h) ? 1 : 0;
    /* Whatever the provider wrote, the strings end inside their fields. */
    h->persona[PP_SC_PERSONA_MAX - 1] = 0;
    h->language[PP_SC_LANGUAGE_MAX - 1] = 0;
    h->magic = PP_SC_MAGIC;
    h->size = sizeof(*h);
    h->version = PP_SC_PROTOCOL;
    return PP_SC_OK;
}

static unsigned sc_call(void *args)
{
    pp_sc_call *c = args;
    const wine_host_steamclient_provider *p = atomic_load(&g_provider);
    unsigned rc;
    if (!pp_sc_block_valid(PP_SC_CALL, args)) return PP_SC_INVALID_PARAMETER;
    if (c->method != PP_SC_TICKET_CANCEL) c->handle = 0;
    c->data_size = 0;
    c->reserved = 0;
    if (!p || !p->call) return PP_SC_NOT_SUPPORTED;
    rc = p->call(c);
    if (rc != PP_SC_OK) {
        c->data_size = 0;
        return rc;
    }
    if (c->data_size > sizeof(c->data)) {
        c->data_size = 0;
        return PP_SC_NOT_SUPPORTED;
    }
    if ((c->method == PP_SC_TICKET_SESSION || c->method == PP_SC_TICKET_WEB_API) && !c->handle) return PP_SC_NOT_SUPPORTED;
    return PP_SC_OK;
}

static unsigned sc_poll(void *args)
{
    pp_sc_poll *s = args;
    const wine_host_steamclient_provider *p = atomic_load(&g_provider);
    if (!pp_sc_block_valid(PP_SC_POLL, args)) return PP_SC_INVALID_PARAMETER;
    s->state = PP_SC_FAILED;
    s->eresult = 0;
    s->reserved = 0;
    if (!p || !p->poll) return PP_SC_NOT_SUPPORTED;
    return p->poll(s);
}

static unsigned sc_log(void *args)
{
    pp_sc_log *l = args;
    const wine_host_steamclient_provider *p = atomic_load(&g_provider);
    if (!pp_sc_block_valid(PP_SC_LOG, args)) return PP_SC_INVALID_PARAMETER;
    if (!p || !p->log) return PP_SC_NOT_SUPPORTED;
    p->log(l->text);
    return PP_SC_OK;
}

/* Indexed by enum pp_sc_code, as Wine's dispatcher indexes every unix table. */
const void *playport_steamclient_unix_call_funcs[PP_SC_CALLS] = {
    (const void *)sc_hello,
    (const void *)sc_call,
    (const void *)sc_poll,
    (const void *)sc_log,
};
