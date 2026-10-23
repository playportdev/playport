// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
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
struct playport_app_connection {
    struct RpPairingFileHandle *pairing;
    struct AdapterHandle *adapter;
    struct RsdHandshakeHandle *rsd;
    struct AppServiceHandle *apps;
};
struct IdeviceFfiError *rp_pairing_file_from_bytes(const uint8_t *, uintptr_t, struct RpPairingFileHandle **);
struct IdeviceFfiError *tunnel_create_rppairing(const struct sockaddr *, socklen_t, const char *, struct RpPairingFileHandle *,
    const char *(*)(void *), void *, struct AdapterHandle **, struct RsdHandshakeHandle **);
struct IdeviceFfiError *app_service_connect_rsd(struct AdapterHandle *, struct RsdHandshakeHandle *, struct AppServiceHandle **);
struct IdeviceFfiError *app_service_launch_app(struct AppServiceHandle *, const char *, const char *const *, uintptr_t,
    int, int, const uint8_t *, struct LaunchResponseC **);
void idevice_error_free(struct IdeviceFfiError *);

static inline int playport_app_step(struct IdeviceFfiError *error, int step, const char *name,
                                    playport_relaunch_log log, void *ctx) {
    if (!error) return 0;
    char message[512];
    snprintf(message, sizeof message, "%s failed: [%d/%d] %s", name, error->code, error->sub_code,
             error->message ? error->message : "");
    log(message, ctx);
    idevice_error_free(error);
    return step;
}

static inline int playport_app_connect(const uint8_t *pairing, size_t pairing_len, const char *host,
    struct playport_app_connection *connection, playport_relaunch_log log, void *ctx) {
    struct sockaddr_in address = {0};
    address.sin_len = sizeof address;
    address.sin_family = AF_INET;
    address.sin_port = htons(49152);
    if (inet_pton(AF_INET, host, &address.sin_addr) != 1) { log("bad host address", ctx); return 1; }
    log("RP pairing file", ctx);
    int result = playport_app_step(rp_pairing_file_from_bytes(pairing, pairing_len, &connection->pairing),
                                  2, "RP pairing file", log, ctx);
    if (result) return result;
    log("RemotePairing tunnel and RSD", ctx);
    result = playport_app_step(tunnel_create_rppairing((const struct sockaddr *)&address, sizeof address,
        "Playport", connection->pairing, NULL, NULL, &connection->adapter, &connection->rsd),
        3, "RemotePairing tunnel and RSD", log, ctx);
    if (result) return result;
    log("app service", ctx);
    return playport_app_step(app_service_connect_rsd(connection->adapter, connection->rsd, &connection->apps),
                             4, "app service", log, ctx);
}
