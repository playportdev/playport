/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * url_opener_protocol.h — the unix call table through which Playport's URL
 * opener (app/UrlOpener/playport-url-opener.c, the prefix's http and https
 * handler) hands a web page a game opens to the host app during a play
 * (decision 0064). The opener reaches it as the game's Steam API emulator
 * reaches its table: NtQueryVirtualMemory(MemoryWineLoadUnixLib) on its own
 * module, which the runtime answers with playport_url_unix_call_funcs for the
 * export name playport-url-opener.exe (patches/madeira-unix), then
 * __wine_unix_call(handle, PP_URL_OPEN, block).
 *
 * The block is fixed-size with no pointers, starts with PP_URL_MAGIC and its
 * own size, and is refused, not read, when it does not match. What crosses is
 * the URL only; the host decides what to show and answers at once (it never
 * waits for the page). The opener includes this file.
 */

#ifndef URL_OPENER_PROTOCOL_H
#define URL_OPENER_PROTOCOL_H

#include <stdint.h>

#define PP_URL_MAGIC 0x52555050u /* "PPUR" */
#define PP_URL_PROTOCOL 1u
#define PP_URL_MAX 2048          /* the URL with its NUL */

enum pp_url_call {
    PP_URL_OPEN = 0,   /* pp_url_open: show this page */
    PP_URL_CALLS = 1
};

/* NTSTATUS values the call returns. NOT_SUPPORTED: no play is armed (or no
 * host at all); QUOTA_EXCEEDED: a page is already up, or the game asked too
 * often. */
#define PP_URL_OK 0x00000000u
#define PP_URL_NOT_SUPPORTED 0xC00000BBu
#define PP_URL_INVALID_PARAMETER 0xC000000Du
#define PP_URL_QUOTA_EXCEEDED 0xC0000044u

typedef struct {
    uint32_t magic, size;
    uint32_t version;       /* in: the opener's PP_URL_PROTOCOL */
    char url[PP_URL_MAX];   /* in: NUL-terminated, http:// or https:// */
} pp_url_open;

/* Whether the URL starts with http:// or https://, in any case. */
static inline int pp_url_scheme_ok(const char *url)
{
    static const char http[] = "http://", https[] = "https://";
    int i;
    for (i = 0; i < 7; i++) {
        char c = url[i];
        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
        if (c != http[i]) break;
    }
    if (i == 7) return 1;
    for (i = 0; i < 8; i++) {
        char c = url[i];
        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
        if (c != https[i]) return 0;
    }
    return 1;
}

/* Whether a block is what PP_URL_OPEN expects: its magic, its size, the
 * protocol, a NUL inside url, an http(s) scheme, and no control character or
 * space before the NUL. */
static inline int pp_url_block_valid(const void *args)
{
    const pp_url_open *o = (const pp_url_open *)args;
    int n;
    if (!o || o->magic != PP_URL_MAGIC || o->size != sizeof(pp_url_open) || o->version != PP_URL_PROTOCOL) return 0;
    for (n = 0; n < PP_URL_MAX && o->url[n]; n++)
        if ((unsigned char)o->url[n] <= ' ' || (unsigned char)o->url[n] == 0x7f) return 0;
    if (n == 0 || n == PP_URL_MAX) return 0;
    return pp_url_scheme_ok(o->url);
}

#endif /* URL_OPENER_PROTOCOL_H */
