// SPDX-License-Identifier: GPL-3.0-or-later
// See include/relaunch.h. Shared tunnel setup lives in connection.h.
// Nothing is freed: when the request works, the service ends this process, and
// when it fails, the handles are a few kilobytes of a process that stays up.

#include "relaunch.h"

#include "connection.h"

#include <stdio.h>

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
    struct playport_app_connection connection = {0};
    struct LaunchResponseC *resp = NULL;
    int result = playport_app_connect(pairing, pairing_len, host, &connection, log, ctx);
    if (result) return result;
    struct AppServiceHandle *apps = connection.apps;
    say(log, ctx, "launchapplication (this app%s) terminateExisting: sending", "", 0);
    STEP(5, "launchapplication", app_service_launch_app(apps, bundle_id, NULL, 0, 1, 0, NULL, &resp));
    say(log, ctx, "launchapplication replied: pid %s%ld", "", resp ? (long)resp->pid : -1L);
    return 0;
}
