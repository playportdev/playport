/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * url_opener_test.c — url_opener.c on the Linux host (pp test): the URL
 * opener's unix call table checks its block (magic, size, protocol, a NUL,
 * the scheme, no space or control character) before the provider sees the
 * URL, and answers NOT_SUPPORTED with no provider.
 */
#include "wine_host.h"
#include "url_opener_protocol.h"

#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

extern const void *playport_url_unix_call_funcs[];
typedef unsigned (*call_fn)(void *);
static unsigned call(void *args) { return ((call_fn)playport_url_unix_call_funcs[PP_URL_OPEN])(args); }

static char opened[PP_URL_MAX];
static int opens;
static unsigned p_open(const char *url)
{
    strncpy(opened, url, sizeof(opened) - 1);
    opens++;
    return PP_URL_OK;
}
static const wine_host_url_opener opener = { p_open };

static pp_url_open block(const char *url)
{
    pp_url_open o;
    memset(&o, 0, sizeof o);
    o.magic = PP_URL_MAGIC;
    o.size = sizeof o;
    o.version = PP_URL_PROTOCOL;
    strncpy(o.url, url, sizeof(o.url) - 1);
    return o;
}

int main(void)
{
    /* One layout for every architecture: a fixed size, no pointers. */
    CHECK(sizeof(pp_url_open) == 12 + PP_URL_MAX);

    pp_url_open o = block("https://www.epicgames.com/activate?userCode=ABCD1234");

    /* No provider: the host has nothing to show it in. */
    CHECK(call(&o) == PP_URL_NOT_SUPPORTED);

    wine_host_set_url_opener(&opener);
    CHECK(call(&o) == PP_URL_OK && opens == 1);
    CHECK(strcmp(opened, "https://www.epicgames.com/activate?userCode=ABCD1234") == 0);
    o = block("HTTP://example.com/");
    CHECK(call(&o) == PP_URL_OK && opens == 2);

    /* Refused before the provider sees it. */
    o = block("https://a/"); o.magic = 0;
    CHECK(call(&o) == PP_URL_INVALID_PARAMETER);
    o = block("https://a/"); o.size = 12;
    CHECK(call(&o) == PP_URL_INVALID_PARAMETER);
    o = block("https://a/"); o.version = 2;
    CHECK(call(&o) == PP_URL_INVALID_PARAMETER);
    o = block("https://a/"); memset(o.url, 'a', sizeof o.url);   /* no NUL */
    CHECK(call(&o) == PP_URL_INVALID_PARAMETER);
    o = block("");
    CHECK(call(&o) == PP_URL_INVALID_PARAMETER);
    o = block("file:///c:/windows/system32/cmd.exe");
    CHECK(call(&o) == PP_URL_INVALID_PARAMETER);
    o = block("javascript:alert(1)");
    CHECK(call(&o) == PP_URL_INVALID_PARAMETER);
    o = block("https:/a");
    CHECK(call(&o) == PP_URL_INVALID_PARAMETER);
    o = block("https://a/ b");
    CHECK(call(&o) == PP_URL_INVALID_PARAMETER);
    o = block("https://a/\tb");
    CHECK(call(&o) == PP_URL_INVALID_PARAMETER);
    CHECK(call(NULL) == PP_URL_INVALID_PARAMETER);
    CHECK(opens == 2);

    wine_host_set_url_opener(NULL);
    o = block("https://a/");
    CHECK(call(&o) == PP_URL_NOT_SUPPORTED);

    if (failures) return 1;
    printf("url opener: all passed\n");
    return 0;
}
