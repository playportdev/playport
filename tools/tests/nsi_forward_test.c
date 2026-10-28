/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The exact iOS forwarding enumerator, with fake sysctl and time. */
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>

typedef unsigned UINT;
typedef uintptr_t UINT_PTR;
typedef int NTSTATUS, BOOL;
typedef unsigned char BYTE;
typedef union { uint64_t Value; struct { unsigned Index, IfType; } Info; } NET_LUID;
#define TRUE 1
#define STATUS_SUCCESS 0
#define STATUS_NOT_SUPPORTED 1
#define STATUS_NO_MEMORY 2
#define STATUS_INVALID_PARAMETER 3
#define STATUS_BUFFER_OVERFLOW 4
#define CTL_NET 4
#define MIB_IPPROTO_NETMGMT 3
#define MIB_IPPROTO_LOCAL 2
#define IF_TYPE_SOFTWARE_LOOPBACK 24
#define NlroManual 0
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define ERR(...) ((void)0)
struct nsi_ipv4_forward_key { NET_LUID luid, luid2; BYTE prefix[4], next_hop[4]; UINT prefix_len; };
struct nsi_ipv6_forward_key { NET_LUID luid, luid2; BYTE prefix[16], next_hop[16]; UINT prefix_len; };
struct nsi_ip_forward_rw
{
    UINT site_prefix_len, valid_lifetime, preferred_lifetime, metric, protocol;
    BOOL immortal, loopback;
};
struct nsi_ipv4_forward_dynamic { BYTE addr2[4]; };
struct nsi_ipv6_forward_dynamic { BYTE addr2[16]; };
struct nsi_ip_forward_static { UINT origin, if_index; };

static uint64_t now = 10000;
static int calls, error, race, empty, malformed, visible = 1;
static int fake_clock_gettime(clockid_t clock, struct timespec *ts)
{
    assert(clock == CLOCK_MONOTONIC);
    ts->tv_sec = now / 1000; ts->tv_nsec = now % 1000 * 1000000;
    return 0;
}
static int convert_index_to_luid(UINT index, NET_LUID *luid)
{
    assert(index == 7);
    luid->Info.Index = index; luid->Info.IfType = 6;
    return visible;
}
static int sysctl(const int *, unsigned, void *, size_t *, void *, size_t);
#define clock_gettime fake_clock_gettime
#include "dlls/nsiproxy.sys/ios_forward.h"
#undef clock_gettime

static int sysctl(const int *mib, unsigned n, void *out, size_t *size, void *in, size_t insize)
{
    BYTE bytes[256] = {0};
    struct ios_route_header h = {0};
    unsigned len = mib[3] == AF_INET ? 16 : 28, off = mib[3] == AF_INET ? 4 : 8;
    BYTE *dst = bytes + sizeof(h), *gw = dst + len, *mask = gw + len;
    ++calls;
    assert(n == 6 && mib[0] == CTL_NET && mib[1] == PF_ROUTE && mib[4] == 1 && !in && !insize);
    if (error) { errno = error; return -1; }
    if (empty) { *size = 0; return 0; }
    h.length = sizeof(h) + 3 * len;
    h.version = 5; h.type = 4; h.index = 7; h.flags = 3; h.addrs = 7; h.metrics[2] = 11;
    memcpy(bytes, &h, sizeof(h));
    dst[0] = gw[0] = mask[0] = len;
    dst[1] = gw[1] = mib[3] == AF_INET ? 2 : 30;
    dst[off] = 10; gw[off] = 10; gw[off + 3] = 1; mask[off] = 255;
    if (malformed) memset(bytes, 0, sizeof(h));
    if (out)
    {
        if (race) { --race; errno = ENOMEM; return -1; }
        assert(*size >= h.length); memcpy(out, bytes, h.length);
    }
    *size = h.length;
    return 0;
}
static NTSTATUS count_rows(int family, UINT_PTR *count)
{
    return ios_forward_enumerate_all(family, NULL, 0, NULL, 0, NULL, 0, NULL, 0, count);
}
static NTSTATUS rows(int family, void *keys, unsigned size, UINT_PTR *count)
{
    return ios_forward_enumerate_all(family, keys, size, NULL, 0, NULL, 0, NULL, 0, count);
}
static void *reader(void *arg)
{
    (void)arg;
    for (int i = 0; i < 100; ++i)
    {
        UINT_PTR n = 0;
        assert(!count_rows(AF_INET, &n) && n == 1);
    }
    return NULL;
}
int main(void)
{
    UINT_PTR n = 0;
    struct nsi_ipv4_forward_key key4;
    struct nsi_ipv6_forward_key key6;
    struct nsi_ip_forward_rw rw;
    struct nsi_ipv4_forward_dynamic dyn;
    struct nsi_ip_forward_static stat;
    pthread_t threads[4];
    assert(!count_rows(AF_INET, &n) && n == 1 && calls == 2);
    n = 0; memset(&key4, 0xcc, sizeof(key4));
    assert(rows(AF_INET, &key4, sizeof(key4), &n) == STATUS_BUFFER_OVERFLOW);
    assert(((BYTE *)&key4)[0] == 0xcc && !n && calls == 2);
    n = 1;
    assert(!ios_forward_enumerate_all(AF_INET, &key4, sizeof(key4), &rw, sizeof(rw),
                                     &dyn, sizeof(dyn), &stat, sizeof(stat), &n));
    assert(n == 1 && key4.luid.Info.Index == 7 && key4.luid.Value == key4.luid2.Value);
    assert(key4.prefix[0] == 10 && key4.next_hop[3] == 1 && key4.prefix_len == 8);
    assert(rw.metric == 11 && rw.site_prefix_len == 8 && rw.immortal && !rw.loopback);
    assert(stat.if_index == 7 && dyn.addr2[0] == 10 && calls == 2);
    n = 1; assert(!rows(AF_INET6, &key6, sizeof(key6), &n) && n == 1 && calls == 4);
    /* Per-family cache, and concurrent readers share the same dump. */
    for (unsigned i = 0; i < ARRAY_SIZE(threads); ++i) assert(!pthread_create(&threads[i], NULL, reader, NULL));
    for (unsigned i = 0; i < ARRAY_SIZE(threads); ++i) assert(!pthread_join(threads[i], NULL));
    assert(calls == 4);
    now += IOS_IF_SNAPSHOT_MS - 1;
    assert(!count_rows(AF_INET, &n) && calls == 4);
    ++now; assert(!count_rows(AF_INET, &n) && calls == 6);
    /* Interface mapping stays live even while its route dump is cached. */
    visible = 0; assert(!count_rows(AF_INET, &n) && !n && calls == 6); visible = 1;
    /* Empty and sandbox-denied snapshots are cached, but only for the TTL. */
    now += IOS_IF_SNAPSHOT_MS; empty = 1;
    assert(!count_rows(AF_INET, &n) && !n && calls == 7);
    assert(!count_rows(AF_INET, &n) && !n && calls == 7);
    empty = 0; error = EPERM; now += IOS_IF_SNAPSHOT_MS;
    assert(!count_rows(AF_INET, &n) && !n && calls == 8);
    assert(!count_rows(AF_INET, &n) && !n && calls == 8);
    error = EACCES; now += IOS_IF_SNAPSHOT_MS;
    assert(!count_rows(AF_INET, &n) && !n && calls == 9);
    error = EIO; now += IOS_IF_SNAPSHOT_MS;
    assert(count_rows(AF_INET, &n) == STATUS_NOT_SUPPORTED && calls == 10);
    assert(count_rows(AF_INET, &n) == STATUS_NOT_SUPPORTED && calls == 10);
    /* Failed size races do not leak; retry a growing table at most 3 times. */
    error = 0; race = 1; now += IOS_IF_SNAPSHOT_MS;
    assert(!count_rows(AF_INET, &n) && n == 1 && calls == 14);
    race = 3; now += IOS_IF_SNAPSHOT_MS;
    assert(count_rows(AF_INET, &n) == STATUS_NOT_SUPPORTED && calls == 20);
    assert(count_rows(AF_INET, &n) == STATUS_NOT_SUPPORTED && calls == 20);
    malformed = 1; now += IOS_IF_SNAPSHOT_MS;
    assert(count_rows(AF_INET, &n) == STATUS_INVALID_PARAMETER && calls == 22);
    malformed = 0; now += IOS_IF_SNAPSHOT_MS;
    assert(!count_rows(AF_INET, &n) && n == 1 && calls == 24);
    /* A successful dump replaced the malformed/failed one, no stale replay. */
    free(ios_route_cache[0].buffer); free(ios_route_cache[1].buffer);
    return 0;
}
