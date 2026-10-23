// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "relaunch.h"

/// Strings belong to the service and are valid only during the callback; copy them.
typedef void (*playport_app_entry)(const char *name, const char *bundle_id, void *ctx);

/// Lists only visible developer apps. Returns zero on success, or a failed step.
int playport_list_developer_apps(const uint8_t *pairing, size_t pairing_len, const char *host,
    playport_app_entry entry, playport_relaunch_log log, void *ctx);

/// Launches without terminating an existing process. Returns its PID, or zero on failure.
uint32_t playport_launch_app(const uint8_t *pairing, size_t pairing_len, const char *host, const char *bundle_id,
    playport_relaunch_log log, void *ctx);
