/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * host_io.h — the C entry points the app's host I/O layer (S1Probe
 * HostIO.swift) calls: controller state for Wine's XInput, and the
 * two host-app extensions of the adopted runtime that are not in its own
 * headers. Design: docs/ARCHITECTURE.md (HostIO, Winios hooks).
 *
 * Every function here is cheap and does not wait on the runtime (a ring push,
 * a lock held for a 20-byte copy, or an AudioOutputUnit start/stop), so the
 * main thread may call it.
 */
#ifndef HOST_IO_H
#define HOST_IO_H

#include <stdint.h>

#include "hio_pads.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Controllers (hio_pads.c), into Madeira's controller snapshot, which Wine's
 * xinput1_*.dll reads through win32u. The writers take a lock: the main thread
 * sets and disconnects, and Winios's drain releases held buttons after a focus
 * loss has reached the game. release_all returns how many slots it released. */
void host_pad_set(int slot, const hio_pad_state *st);
void host_pad_disconnect(int slot);
int host_pads_release_all(void);

/* Winios.m + patches/madeira-winios/0002-Winios-accept-pointer-and-focus-events-posted-by-the.patch.
 * fx, fy: 0..65535 across the foreground window's client area; flags are
 * MOUSEEVENTF_* (ABSOLUTE is implied). active: 0 when the app leaves the
 * foreground, 1 when it is back. Both are queued in order with winios_post_key. */
void winios_post_client_pointer(int fx, int fy, unsigned int flags, unsigned int data);
void winios_post_focus(int active);

/* host_log.c: one line into the log at path; through stderr once
 * wine_host_init has made fd 2 that file, appended directly before. */
void host_log(const char *path, const char *line);
/* A release build's limit (AppLog.swift): with a nonzero limit, host_log
 * drops a line once the file has reached it. 0, the default, is no limit. */
void host_log_set_limit(long bytes);

/* host_memory.c: the app's memory, in bytes. available is what
 * os_proc_available_memory() reports left before iOS ends the process (0: no
 * limit reported); footprint the phys footprint now. The limit is available +
 * footprint.
 * Returns 0, or -1 when task_info fails (available is still set). */
typedef struct {
    uint64_t available, footprint;
} host_memory;
int host_memory_read(host_memory *out);
/* host_memory.c: 1 when the signature's entitlement name is true, 0 when it is
 * absent or not true, -1 when the entitlements cannot be read. It dlopens
 * Security each call: MemoryLimit.swift asks once. */
int host_entitlement(const char *name);

/* libntdll_unix.a audio_null_ios.c + patches/madeira-unix/0012-audio-let-the-host-app-suspend-and-resume-the-proces.patch:
 * nonzero stops every running RemoteIO unit, zero restarts the ones the game
 * still has started. Returns how many units it touched. */
int ios_audio_host_suspend(int suspend);

/* libdxmt_combined.a winemetal_unix.c + patches/dxmt/0002-winemetal-hold-Metal-commits-while-the-app-is-in-the.patch:
 * 0 from didEnterBackground closes the gate every Metal commit passes (iOS
 * refuses GPU work from the background; a refused buffer runs nothing), then
 * waits up to 100 ms for committed buffers to be scheduled and returns how
 * many were not; 1 from willEnterForeground opens it and returns 0. */
int winemetal_host_gpu_gate(int open);

/* libdxmt_combined.a winemetal_unix.c: how presents are paced. 1 (the
 * default) presents afterMinimumDuration(1/60); 0 presents every frame at
 * once, so the panel's refresh (120 Hz on ProMotion) sets the rate. A title
 * picks one at start (TitleScreen.swift). */
void madeira_set_vsync_locked(int mode);

#ifdef __cplusplus
}
#endif

#endif /* HOST_IO_H */
