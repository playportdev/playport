/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Compile the shipped iOS snapshot and NDIS row filler on Linux. */
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <net/if.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include "dlls/nsiproxy.sys/ios_ifaddrs.h"

#define AF_LINK 18
#define IfOperStatusUnknown 4
#define IfOperStatusUp 1
#define IfOperStatusDown 2
#define MediaConnectStateConnected 1
#define MediaConnectStateDisconnected 2

struct if_data
{
    unsigned ifi_mtu, ifi_baudrate, ifi_ibytes, ifi_obytes, ifi_ierrors, ifi_oerrors,
             ifi_iqdrops, ifi_ipackets, ifi_opackets, ifi_imcasts, ifi_omcasts;
};
struct nsi_ndis_ifinfo_dynamic
{
    unsigned oper_status, media_conn_state, mtu;
    uint64_t xmit_speed, rcv_speed, in_octets, out_octets, in_errors, out_errors,
             in_discards, in_ucast_pkts, out_ucast_pkts, in_mcast_pkts, out_mcast_pkts;
};
struct if_entry { char if_unix_name[16]; };
static struct ios_if_snapshot if_snapshot;
#include "ndis_dynamic.h"

#define N 36
static int calls, live, fail, empty, renamed;
static char names[N][16];
static struct sockaddr link_addr = { .sa_family = AF_LINK }, inet_addr = { .sa_family = AF_INET };
static struct if_data info = {1500, 1000000, 42, 73, 1, 2, 3, 4, 5, 6, 7};

/* N interfaces, each with an IP and an AF_LINK entry. No sockets/ioctls. */
int getifaddrs(struct ifaddrs **out)
{
    struct ifaddrs *list = NULL, *e;
    ++calls;
    if (fail) { errno = EIO; return -1; }
    if (!empty)
        for (int i = N - 1; i >= 0; --i)
            for (int k = 0; k < 2; ++k)
            {
                e = calloc(1, sizeof(*e));
                e->ifa_name = renamed && !i ? "new0" : names[i];
                e->ifa_addr = k ? &inet_addr : &link_addr;
                e->ifa_data = &info;
                e->ifa_flags = i ? 0 : IFF_UP | IFF_RUNNING;
                e->ifa_next = list; list = e; ++live;
            }
    *out = list;
    return 0;
}
void freeifaddrs(struct ifaddrs *list)
{
    while (list) { struct ifaddrs *next = list->ifa_next; free(list); --live; list = next; }
}

int main(void)
{
    struct ios_if_snapshot *snap = &if_snapshot;
    struct if_entry entry;
    struct nsi_ndis_ifinfo_dynamic dyn;
    struct ifaddrs *first;
    unsigned long long t = 5000;
    for (int i = 0; i < N; ++i) snprintf(names[i], sizeof(names[i]), "if%d", i);
    /* A whole enumeration, with the actual iOS row filler. */
    ios_if_snapshot_refresh(snap, t);
    first = snap->addrs;
    for (int i = 0; i < N; ++i)
    {
        snprintf(entry.if_unix_name, sizeof(entry.if_unix_name), "if%d", i);
        ifinfo_fill_dynamic(&entry, &dyn);
        assert(dyn.mtu == 1500 && dyn.in_octets == 42 && dyn.out_octets == 73);
        assert(dyn.in_errors == 1 && dyn.out_errors == 2 && dyn.in_discards == 3);
        assert(dyn.in_ucast_pkts == 4 && dyn.out_ucast_pkts == 5);
        assert(dyn.in_mcast_pkts == 6 && dyn.out_mcast_pkts == 7);
        assert(dyn.xmit_speed == 1000000 && dyn.rcv_speed == 1000000);
        assert(dyn.oper_status == (i ? IfOperStatusDown : IfOperStatusUp));
        assert(dyn.media_conn_state == (i ? MediaConnectStateDisconnected : MediaConnectStateConnected));
    }
    assert(calls == 1 && live == 2 * N && snap->addrs == first);
    /* Missing row / AF_LINK data / unrelated address row. */
    snprintf(entry.if_unix_name, sizeof(entry.if_unix_name), "if99");
    ifinfo_fill_dynamic(&entry, &dyn);
    assert(dyn.oper_status == IfOperStatusUnknown && !dyn.mtu && !dyn.in_octets);
    first->ifa_data = NULL; /* head is AF_INET, which must be skipped */
    snprintf(entry.if_unix_name, sizeof(entry.if_unix_name), "if0");
    ifinfo_fill_dynamic(&entry, &dyn); assert(dyn.mtu == 1500);
    first->ifa_next->ifa_data = NULL;
    ifinfo_fill_dynamic(&entry, &dyn); assert(!dyn.mtu && dyn.oper_status == IfOperStatusUp);
    /* Refresh at TTL, not per interface; renamed/removed identities disappear. */
    renamed = 1;
    ios_if_snapshot_refresh(snap, t + IOS_IF_SNAPSHOT_MS - 1); assert(calls == 1);
    assert(ios_if_find(snap->addrs, "if0", AF_LINK));
    ios_if_snapshot_refresh(snap, t + IOS_IF_SNAPSHOT_MS); assert(calls == 2 && live == 2 * N);
    assert(!ios_if_find(snap->addrs, "if0", AF_LINK));
    assert(ios_if_find(snap->addrs, "new0", AF_LINK));
    /* Monotonic clock going backwards expires safely. */
    ios_if_snapshot_refresh(snap, t); assert(calls == 3);
    /* Failure discards stale data and is cached for the TTL, including N rows. */
    fail = 1;
    ios_if_snapshot_refresh(snap, t + IOS_IF_SNAPSHOT_MS);
    assert(!snap->addrs && !live && snap->error == EIO);
    for (int i = 0; i < N; ++i)
    {
        ios_if_snapshot_refresh(snap, t + IOS_IF_SNAPSHOT_MS + i);
        ifinfo_fill_dynamic(&entry, &dyn);
    }
    assert(calls == 4 && !dyn.mtu && dyn.oper_status == IfOperStatusUnknown);
    fail = 0;
    ios_if_snapshot_refresh(snap, t + 2 * IOS_IF_SNAPSHOT_MS); assert(calls == 5 && !snap->error);
    empty = 1;
    ios_if_snapshot_refresh(snap, t + 3 * IOS_IF_SNAPSHOT_MS);
    assert(!snap->addrs && !snap->error && snap->valid && !live);
    ios_if_snapshot_refresh(snap, t + 3 * IOS_IF_SNAPSHOT_MS + 1); assert(calls == 6);
    assert(!ios_if_find(NULL, "if0", AF_LINK));
    assert(ios_if_fresh(1, 10, 10) && !ios_if_fresh(0, 10, 10) && !ios_if_fresh(1, 10, 9));
    assert(ios_if_now_ms() > 0);
    return 0;
}
