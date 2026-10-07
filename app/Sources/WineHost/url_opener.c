/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * The unix call table of Playport's URL opener (url_opener_protocol.h,
 * decision 0064). The runtime hands it to the module whose export name is
 * playport-url-opener.exe (patches/madeira-unix). The call checks its block
 * and passes the URL to the provider the app set (wine_host_set_url_opener);
 * with none, it answers NOT_SUPPORTED and the opener exits with an error, as
 * a missing browser would. It logs nothing: the app logs what it shows.
 */

#include "wine_host.h"
#include "url_opener_protocol.h"

#include <stdatomic.h>

static _Atomic(const wine_host_url_opener *) g_opener;

void wine_host_set_url_opener(const wine_host_url_opener *opener)
{
    atomic_store(&g_opener, opener);
}

static unsigned url_open(void *args)
{
    pp_url_open *o = args;
    const wine_host_url_opener *p = atomic_load(&g_opener);
    if (!pp_url_block_valid(args)) return PP_URL_INVALID_PARAMETER;
    if (!p || !p->open) return PP_URL_NOT_SUPPORTED;
    return p->open(o->url);
}

/* Indexed by enum pp_url_call, as Wine's dispatcher indexes every unix table. */
const void *playport_url_unix_call_funcs[PP_URL_CALLS] = {
    (const void *)url_open,
};
