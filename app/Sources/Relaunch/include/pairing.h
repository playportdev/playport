// SPDX-License-Identifier: GPL-3.0-or-later
// idevice's device-initiated pairing FFI. Product caller: OnDevicePairing.swift.
#pragma once
#include <stddef.h>
#include <stdint.h>

struct PairableHostCancel;
struct IdeviceFfiError { int32_t code; int32_t sub_code; const char *message; };
struct PairableHostCancel *pairable_host_cancel_new(void);
void pairable_host_cancel_signal(const struct PairableHostCancel *);
void pairable_host_cancel_free(struct PairableHostCancel *);
struct IdeviceFfiError *pairable_host_accept_bonjour(
    const char *name, const char *pin,
    void (*advertise)(const char *identifier, const char *txt_json, uint16_t port, void *context),
    void (*paired)(const uint8_t *data, size_t len, void *context),
    void *context, const struct PairableHostCancel *cancel);
void idevice_error_free(struct IdeviceFfiError *);
