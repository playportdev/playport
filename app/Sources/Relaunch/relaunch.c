// SPDX-License-Identifier: GPL-3.0-or-later
// See include/relaunch.h. The four idevice calls are declared here rather than
// taken from its generated header: build/stages/idevice.sh exports these alone.
// Nothing is freed: when the request works, the service ends this process, and
// when it fails, the handles are a few kilobytes of a process that stays up.

#include "relaunch.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>

struct IdeviceFfiError { int32_t code; int32_t sub_code; const char *message; };
struct RpPairingFileHandle;
struct AdapterHandle;
struct RsdHandshakeHandle;
struct AppServiceHandle;
struct LaunchResponseC { uint32_t version; uint32_t pid; char *executable_url; uint32_t *audit_token; uintptr_t audit_token_len; };

struct IdeviceFfiError *rp_pairing_file_from_bytes(const uint8_t *, uintptr_t, struct RpPairingFileHandle **);
struct IdeviceFfiError *tunnel_create_rppairing(const struct sockaddr *, socklen_t, const char *, struct RpPairingFileHandle *,
                                                const char *(*)(void *), void *,
                                                struct AdapterHandle **, struct RsdHandshakeHandle **);
struct IdeviceFfiError *app_service_connect_rsd(struct AdapterHandle *, struct RsdHandshakeHandle *, struct AppServiceHandle **);
struct IdeviceFfiError *app_service_launch_app(struct AppServiceHandle *, const char *, const char *const *, uintptr_t,
                                               int, int, const uint8_t *, struct LaunchResponseC **);

static void say(playport_relaunch_log log, void *ctx, const char *fmt, const char *a, long n) {
    char line[512];
    snprintf(line, sizeof line, fmt, a, n);
    log(line, ctx);
}

#define STEP(n, name, call)                                                              \
    do {                                                                                 \
        say(log, ctx, "%s", name, 0);                                                    \
        struct IdeviceFfiError *e = (call);                                              \
        if (e) {                                                                         \
            char m[400];                                                                 \
            snprintf(m, sizeof m, "%s failed: [%d/%d] %s", name, e->code, e->sub_code,   \
                     e->message ? e->message : "");                                      \
            log(m, ctx);                                                                 \
            return n;                                                                    \
        }                                                                                \
    } while (0)

int playport_relaunch(const uint8_t *pairing, size_t pairing_len, const char *host, const char *bundle_id,
                      playport_relaunch_log log, void *ctx) {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_len = sizeof addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(49152);   // RemotePairing's tunnel port, as StikJIT's default
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) { log("bad host address", ctx); return 1; }

    struct RpPairingFileHandle *pf = NULL;
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *rsd = NULL;
    struct AppServiceHandle *apps = NULL;
    struct LaunchResponseC *resp = NULL;

    STEP(2, "RP pairing file", rp_pairing_file_from_bytes(pairing, pairing_len, &pf));
    STEP(3, "RemotePairing tunnel and RSD", tunnel_create_rppairing((const struct sockaddr *)&addr, sizeof addr, "Playport",
                                                                    pf, NULL, NULL, &adapter, &rsd));
    STEP(4, "app service", app_service_connect_rsd(adapter, rsd, &apps));
    say(log, ctx, "launchapplication (this app%s) terminateExisting: sending", "", 0);
    STEP(5, "launchapplication", app_service_launch_app(apps, bundle_id, NULL, 0, 1, 0, NULL, &resp));
    say(log, ctx, "launchapplication replied: pid %s%ld", "", resp ? (long)resp->pid : -1L);
    return 0;
}
