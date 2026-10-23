// SPDX-License-Identifier: GPL-3.0-or-later
#include "device_apps.h"
#include "connection.h"

struct AppListEntryC {
    int is_removable; char *name; int is_first_party; char *path; char *bundle_identifier;
    int is_developer_app; char *bundle_version; int is_internal; int is_hidden; int is_app_clip; char *version;
};
struct IdeviceFfiError *app_service_list_apps(struct AppServiceHandle *, int, int, int, int, int,
                                            struct AppListEntryC **, uintptr_t *);
void app_service_free_app_list(struct AppListEntryC *, uintptr_t);
void app_service_free_launch_response(struct LaunchResponseC *);
void app_service_free(struct AppServiceHandle *);
void rsd_handshake_free(struct RsdHandshakeHandle *);
void adapter_free(struct AdapterHandle *);
void rp_pairing_file_free(struct RpPairingFileHandle *);

static void close_connection(struct playport_app_connection *connection) {
    if (connection->apps) app_service_free(connection->apps);
    if (connection->rsd) rsd_handshake_free(connection->rsd);
    if (connection->adapter) adapter_free(connection->adapter);
    if (connection->pairing) rp_pairing_file_free(connection->pairing);
}

int playport_list_developer_apps(const uint8_t *pairing, size_t pairing_len, const char *host,
    playport_app_entry entry, playport_relaunch_log log, void *ctx) {
    struct playport_app_connection connection = {0};
    struct AppListEntryC *apps = NULL;
    uintptr_t count = 0;
    int result = playport_app_connect(pairing, pairing_len, host, &connection, log, ctx);
    if (!result) result = playport_app_step(app_service_list_apps(connection.apps, 0, 1, 0, 0, 0, &apps, &count),
                                           5, "list applications", log, ctx);
    if (!result) for (uintptr_t i = 0; i < count; i++) {
        struct AppListEntryC *app = &apps[i];
        if (app->is_developer_app && !app->is_hidden && !app->is_internal && !app->is_app_clip && app->bundle_identifier)
            entry(app->name ? app->name : app->bundle_identifier, app->bundle_identifier, ctx);
    }
    if (apps) app_service_free_app_list(apps, count);
    close_connection(&connection);
    return result;
}

uint32_t playport_launch_app(const uint8_t *pairing, size_t pairing_len, const char *host, const char *bundle_id,
    playport_relaunch_log log, void *ctx) {
    struct playport_app_connection connection = {0};
    struct LaunchResponseC *response = NULL;
    int result = playport_app_connect(pairing, pairing_len, host, &connection, log, ctx);
    if (!result) result = playport_app_step(app_service_launch_app(connection.apps, bundle_id, NULL, 0, 0, 0, NULL, &response),
                                           5, "launch application", log, ctx);
    uint32_t pid = !result && response ? response->pid : 0;
    if (response) app_service_free_launch_response(response);
    close_connection(&connection);
    return pid;
}
