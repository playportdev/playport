/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Compile wine-unix 0013's five thunks and graph packers (ws2_resolver_api.h),
 * with a mock owner-local window and native resolver entries. No networking. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stddef.h>

typedef uint32_t ULONG;
typedef uint32_t DWORD;
typedef uint64_t ULONGLONG;
typedef uint32_t NTSTATUS;
#define ERROR_INSUFFICIENT_BUFFER 122
#define STATUS_SUCCESS 0
#define WSAENOBUFS 10055
#define WSAEFAULT 10014
#define C_ASSERT(x) _Static_assert(x, #x)
#define ARRAYSIZE(x) (sizeof(x)/sizeof((x)[0]))
#define ws_unix_funcs_count 5
#define ULongToPtr(x) ((void *)(uintptr_t)(x))
#define PtrToUlong(x) ((ULONG)(uintptr_t)(x))
typedef NTSTATUS (*unixlib_entry_t)(void *);

struct WS_addrinfo {
    int ai_flags, ai_family, ai_socktype, ai_protocol;
    size_t ai_addrlen;
    char *ai_canonname;
    void *ai_addr;
    struct WS_addrinfo *ai_next;
};
struct WS_hostent {
    char *h_name;
    char **h_aliases;
    short h_addrtype, h_length;
    char **h_addr_list;
};
struct getaddrinfo_params {
    const char *node, *service;
    const struct WS_addrinfo *hints;
    struct WS_addrinfo *info;
    unsigned int *size;
};
struct gethostbyaddr_params {
    const char *addr;
    int len, family;
    struct WS_hostent *host;
    unsigned int *size;
};
struct gethostbyname_params { const char *name; struct WS_hostent *host; unsigned int *size; };
struct gethostname_params { char *name; unsigned int size; };
struct getnameinfo_params {
    const void *addr; int addr_len;
    char *host; DWORD host_len;
    char *serv; DWORD serv_len;
    unsigned int flags;
};
static uintptr_t base;
uintptr_t ios_wow64_current_base(void) { return base; }
static char addr1[4] = {127, 0, 0, 1}, addr2[4] = {10, 0, 0, 1};
static char *aliases[] = {"one", "two", NULL};
static char *addresses[] = {addr1, addr2, NULL};
static struct WS_hostent host = {"dns", aliases, 2, 4, addresses};
static struct WS_addrinfo second = {2, 2, 1, 6, 4, "two", addr2, NULL};
static struct WS_addrinfo first = {1, 2, 1, 6, 4, "one", addr1, &second};
static int call_status;
static int null_inputs;
static NTSTATUS unix_getaddrinfo(void *args) {
    struct getaddrinfo_params *p = args;
    if (null_inputs) assert(!p->node && !p->service && !p->hints);
    else {
        assert(!strcmp(p->node, "node") && !strcmp(p->service, "80"));
        assert(p->hints && p->hints->ai_flags == 9 && p->hints->ai_family == 2);
    }
    if (call_status) { *p->size = 2048; return call_status; }
    *p->info = first;
    return 0;
}
static NTSTATUS unix_gethostbyaddr(void *args) {
    struct gethostbyaddr_params *p = args;
    assert(!memcmp(p->addr, addr1, 4) && p->len == 4 && p->family == 2);
    *p->host = host;
    return call_status;
}
static NTSTATUS unix_gethostbyname(void *args) {
    struct gethostbyname_params *p = args;
    assert(!strcmp(p->name, "node"));
    *p->host = host;
    return call_status;
}
static NTSTATUS unix_gethostname(void *args) {
    struct gethostname_params *p = args;
    if (null_inputs) assert(!p->name && !p->size);
    else { assert(p->size == 16); strcpy(p->name, "host"); }
    return call_status;
}
static NTSTATUS errno_from_unix(int value) { (void)value; return 77; }
static NTSTATUS unix_getnameinfo(void *args) {
    struct getnameinfo_params *p = args;
    if (null_inputs) assert(!p->addr && !p->host && !p->serv && !p->host_len && !p->serv_len);
    else {
        assert(!memcmp(p->addr, addr1, 4) && p->addr_len == 4 && p->flags == 3);
        assert(p->host_len == 16 && p->serv_len == 8);
        strcpy(p->host, "host"); strcpy(p->serv, "80");
    }
    return call_status;
}
#include "wine/ios_wow64.h"
#include "ws2_resolver_api.h"
static int wow64_call;
static int in_wow64_call(void) { return wow64_call; }
#include "socket_wow64_api.h"

static void *hp(ULONG g) { return ws2_wow64_to_host(g); }
static ULONG gp(void *p) { ULONG g = 0; assert(ws2_wow64_to_guest(p, &g)); return g; }

int main(void) {
    _Alignas(16) unsigned char window[8192];
    base = (uintptr_t)window - 0x10000;
    assert((uintptr_t)socket_wow64_ptr(0x400000) == 0x400000);
    wow64_call = 1;
    assert((uintptr_t)socket_wow64_ptr(0x400000) == base + 0x400000);
    assert(socket_wow64_ptr(0) == NULL);
    assert((uintptr_t)socket_wow64_ptr(UINT64_C(0x7100004000)) == UINT64_C(0x7100004000));
    struct WS_addrinfo32 *ai = (void *)(window + 1024);
    struct WS_hostent32 *he = (void *)(window + 2048);
    unsigned int size;
    ULONG g = 0x12345678;
    assert(hp(0) == NULL);
    assert(ws2_wow64_to_guest(NULL, &g) && g == 0);
    assert(!ws2_wow64_to_guest((void *)(base - 1), &g) && g == 0);
    assert(!ws2_wow64_to_guest((void *)base, &g) && g == 0);
    assert(!ws2_wow64_to_guest((void *)(base + UINT64_C(0x100000000)), &g) && g == 0);
    assert(ws2_wow64_to_guest((void *)(base + UINT32_MAX), &g) && g == UINT32_MAX);
    assert(!ws2_wow64_result_span((void *)(base + UINT32_MAX), 2));
    assert(ws2_wow64_result_span((void *)(base + UINT32_MAX), 1));
    void *heap = malloc(8);
    assert(heap && !ws2_wow64_to_guest(heap, &g));
    free(heap);
    size = 0;
    assert(put_addrinfo32(&first, NULL, &size) == ERROR_INSUFFICIENT_BUFFER && size == 80);
    size = 80;
    assert(put_addrinfo32(&first, ai, &size) == 0);
    assert(ai->ai_flags == 1 && ai->ai_addrlen == 4);
    assert(!strcmp(hp(ai->ai_canonname), "one"));
    assert(!memcmp(hp(ai->ai_addr), addr1, 4));
    struct WS_addrinfo32 *next = hp(ai->ai_next);
    assert(next == (void *)((char *)ai + 40));
    assert(!strcmp(hp(next->ai_canonname), "two") && !memcmp(hp(next->ai_addr), addr2, 4));
    assert(next->ai_next == 0);
    size = 80;
    assert(put_addrinfo32(&first, (void *)(base - 1), &size) == WSAEFAULT && size == 80);
    assert(put_addrinfo32(&first, (void *)(base + UINT32_MAX - 10), &size) == WSAEFAULT);
    memset(ai, 0x5a, 80);
    size = 79;
    assert(put_addrinfo32(&first, ai, &size) == ERROR_INSUFFICIENT_BUFFER && size == 80);
    assert(((unsigned char *)ai)[0] == 0x5a);
    second.ai_canonname = NULL;
    size = 80;
    assert(!put_addrinfo32(&first, ai, &size) && ((struct WS_addrinfo32 *)hp(ai->ai_next))->ai_canonname == 0);
    second.ai_canonname = "two";

    size = 0;
    assert(put_hostent32(&host, NULL, &size) == ERROR_INSUFFICIENT_BUFFER && size == 60);
    size = 60;
    assert(!put_hostent32(&host, he, &size));
    assert(!strcmp(hp(he->h_name), "dns") && he->h_addrtype == 2 && he->h_length == 4);
    ULONG *a = hp(he->h_aliases), *d = hp(he->h_addr_list);
    assert(!strcmp(hp(a[0]), "one") && !strcmp(hp(a[1]), "two") && a[2] == 0);
    assert(!memcmp(hp(d[0]), addr1, 4) && !memcmp(hp(d[1]), addr2, 4) && d[2] == 0);
    assert(put_hostent32(&host, (void *)(base - 1), &size) == WSAEFAULT);
    assert(put_hostent32(&host, (void *)(base + UINT32_MAX - 10), &size) == WSAEFAULT);
    memset(he, 0x5a, 60);
    size = 59;
    assert(put_hostent32(&host, he, &size) == ERROR_INSUFFICIENT_BUFFER && size == 60);
    assert(((unsigned char *)he)[0] == 0x5a);
    char *empty[] = {NULL};
    struct WS_hostent empty_host = {"dns", empty, 2, 4, empty};
    size = 60;
    assert(!put_hostent32(&empty_host, he, &size));
    assert(*(ULONG *)hp(he->h_aliases) == 0 && *(ULONG *)hp(he->h_addr_list) == 0);
    assert(!strcmp(hp(he->h_name), "dns"));
    uintptr_t owner_base = base;
    base += UINT64_C(0x100000000);
    assert((uintptr_t)hp(0x400000) == base + 0x400000);
    assert(!ws2_wow64_to_guest(ai, &g));
    base = owner_base;

    strcpy((char *)window, "node"); strcpy((char *)window + 16, "80");
    memcpy(window + 32, addr1, 4);
    struct WS_addrinfo32 *hints = (void *)(window + 64);
    hints->ai_flags = 9; hints->ai_family = 2;
    unsigned int *sz = (void *)(window + 128);
    ULONG query[] = {gp(window), gp(window + 16), gp(hints), gp(ai), gp(sz)};
    *sz = 1024;
    assert(!wow64_unix_getaddrinfo(query));
    query[3] = 0;
    *sz = 1024;
    assert(wow64_unix_getaddrinfo(query) == WSAEFAULT);
    call_status = 42; *sz = 1024;
    assert(wow64_unix_getaddrinfo(query) == 42 && *sz == 2048);
    call_status = 0; null_inputs = 1;
    memset(query, 0, 3 * sizeof(ULONG)); query[3] = gp(ai); *sz = 1024;
    assert(!wow64_unix_getaddrinfo(query)); null_inputs = 0;
    ULONG byaddr[] = {gp(window + 32), 4, 2, gp(he), gp(sz)};
    *sz = 1024; assert(!wow64_unix_gethostbyaddr(byaddr));
    ULONG byname[] = {gp(window), gp(he), gp(sz)};
    *sz = 1024; assert(!wow64_unix_gethostbyname(byname));
    ULONG hostname[] = {gp(window + 256), 16};
    assert(!wow64_unix_gethostname(hostname) && !strcmp((char *)window + 256, "host"));
    call_status = 42; assert(wow64_unix_gethostname(hostname) == 77); call_status = 0;
    ULONG nameinfo[] = {gp(window + 32), 4, gp(window + 256), 16, gp(window + 288), 8, 3};
    assert(!wow64_unix_getnameinfo(nameinfo) && !strcmp((char *)window + 288, "80"));
    null_inputs = 1; memset(nameinfo, 0, sizeof(nameinfo)); memset(hostname, 0, sizeof(hostname));
    assert(!wow64_unix_getnameinfo(nameinfo)); assert(!wow64_unix_gethostname(hostname));
    base = 0;
    assert((uintptr_t)socket_wow64_ptr(0x400000) == 0x400000);
    assert((uintptr_t)hp(0x400000) == 0x400000);
    assert(ws2_wow64_to_guest((void *)0x400000, &g) && g == 0x400000);
    assert(!ws2_wow64_to_guest((void *)UINT64_C(0x100000000), &g));
    puts("ws2_32: packed addrinfo/hostent round trips, bounds, NULL, sizing, all five thunks");
}
