// SPDX-License-Identifier: GPL-3.0-or-later
// How Playport restarts itself after a game (decision 0029; docs/ARCHITECTURE.md,
// "Restarting after a game"): it asks the phone's CoreDevice app service, over
// LocalDevVPN, to launch its own bundle with terminateExisting. The service
// ends this process and starts a new one, and finishes the request after its
// sender is gone (docs/evidence/2026-09-29-coredevice-relaunch-without-client.md).
// The calls are idevice's C FFI (MIT), built by build/stages/idevice.sh.
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef void (*playport_relaunch_log)(const char *line, void *ctx);

/// The chain StikJIT's JIT session uses to reach the phone, then one request:
/// the RP pairing file, RemotePairing's tunnel at host:49152 with its RSD
/// handshake, the app service, launchapplication for `bundle_id` with
/// terminateExisting. Returns 0 once the service replied (it does not, when it
/// replaces this process), else the step that failed; `log` gets one line per
/// step and the failure's text.
int playport_relaunch(const uint8_t *pairing, size_t pairing_len, const char *host, const char *bundle_id,
                      playport_relaunch_log log, void *ctx);
