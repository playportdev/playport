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

/* The game's XInput requests (hio_pads.c). win32u's ios_gamepad_query calls
 * playport_gamepad_query for each request after reading the slot
 * (patches/madeira-unix 0247 and 0273, a weak reference: a runtime without
 * them never calls it): op 0 is a state request (XInputGetState and
 * GetStateEx; xinput's SetState, Enable and battery query ask for one too),
 * op 1 a capability request; connected, packet and buttons are what the slot
 * answered (0 for an empty slot, which XInput reports as
 * ERROR_DEVICE_NOT_CONNECTED). The app's own snapshot reads do not come here.
 * host_pad_state_reads is the state requests' total since the process
 * started, i.e. this game's (decision 0029): the suggested layout (PlayportKit
 * LayoutSuggestion) offers Keyboard & mouse to a game on Gamepad that made
 * none. host_pad_xinput_summary writes the dev log's line about the requests
 * since the last line it wrote into buf (reads, from which slots, the last
 * answer, packet changes seen, the buttons seen, capability requests) and
 * returns its length, or 0 and writes nothing (taking nothing) when the game
 * made no state request since.
 * Lock-free; the summary's counters are taken one by one, so a request racing
 * it lands in this line or the next. */
void playport_gamepad_query(unsigned int index, unsigned int op, int connected, uint32_t packet,
                            uint16_t buttons);
uint64_t host_pad_state_reads(void);
int host_pad_xinput_summary(char *buf, unsigned int size);

/* The scan code of a posted virtual key (hio_keys.c): 0xE0xx for the keys a
 * real keyboard sends with the E0 prefix and whose scan code is the same on
 * every layout (arrows, Insert/Delete/Home/End/PgUp/PgDn, Print Screen, right
 * Ctrl and Alt, the Windows and menu keys, keypad /), else 0. win32u's
 * winios_drv_post_key asks it first and marks the key extended
 * (patches/madeira-unix 0248, a weak reference), falling back to Wine's
 * MapVirtualKeyEx, which gives the arrows the numpad's scan codes. */
unsigned int playport_key_scan(unsigned int vk);

/* The guest window Winios activates when the app is back in the foreground, or
 * when input arrives while no guest window is the foreground (hio_focus.c;
 * Winios.m + patches/madeira-winios 0010). wins: the desktop's top-level
 * windows in z-order, topmost first, with their Wine process and their
 * GWL_STYLE/GWL_EXSTYLE; saved and saved_pid: the window the last focus loss
 * deactivated and its process (NULL, 0: none). Returns the index of saved if it
 * can still be activated (visible, enabled, not minimized, not a child, not
 * WS_EX_NOACTIVATE), else of the topmost such window of saved_pid's process,
 * else of the topmost such window, else -1. */
typedef struct {
    const void *hwnd;
    unsigned int pid;
    unsigned int style;
    unsigned int exstyle;
} host_focus_window;
int host_focus_pick(const host_focus_window *wins, int n, const void *saved, unsigned int saved_pid);

/* Winios.m + patches/madeira-winios/0002-Winios-accept-pointer-and-focus-events-posted-by-the.patch.
 * fx, fy: 0..65535 across the foreground window's client area; flags are
 * MOUSEEVENTF_* (ABSOLUTE is implied). active: 0 when the app leaves the
 * foreground, 1 when it is back. Both are queued in order with winios_post_key. */
void winios_post_client_pointer(int fx, int fy, unsigned int flags, unsigned int data);
void winios_post_focus(int active);
/* Winios.m + patches/madeira-winios/0006: winios_post_key with
 * KEYEVENTF_EXTENDEDKEY, for a key its VK cannot tell from another (keypad
 * Enter is VK_RETURN with E0; KeyMap.postsExtended). Queued in order with
 * winios_post_key. */
void winios_post_key_extended(int vk, int down);
/* Winios.m + patches/madeira-winios/0008 (and madeira-unix 0251): one UTF-16
 * code unit typed (the text bar, HostIOKit TextBar), pressed and let go as
 * KEYEVENTF_UNICODE, which TranslateMessage turns into WM_CHAR for the focused
 * window. Queued in order with winios_post_key. Nothing logs it, nor a key. */
void winios_post_char(unsigned int unit);
/* Winios.m + patches/madeira-winios/0009: how many queued events (keys,
 * characters, pointer, focus) the drain has not handed to win32u yet; 0 once
 * all are in the server's queue, in order. The text bar waits for 0 before a
 * key that follows characters and before a batch the ring could not hold. */
unsigned int winios_input_pending(void);

/* Winios.m + patches/madeira-winios/0004-Winios-show-a-game-s-GDI-windows-until-its-swap-chai.patch
 * and 0005 (decisions 0075, 0076): the guest's GDI windows (a launcher, a
 * dialog) over the game layer until the game's swap chain presents, and after
 * it the windows the game makes since (its dialogs). layer: a CALayer the host
 * adds to the game view's layer, its frame the view's bounds. on_first: the
 * handler runs once, on the main thread, when the first window is on screen.
 * on_dialog: the handler runs on the main thread when, after the first frame,
 * a dialog comes over the game (1) and when the last one goes (0).
 * game_presenting: the swap chain presents (any thread). shown: 1 while a
 * window is on screen. point: while one is, the desktop pixel under a point of
 * the layer, and 1; else 0. layer, shown and point: main thread only. */
void *winios_windows_layer(void);
void winios_windows_on_first(void (*handler)(void));
void winios_windows_on_dialog(void (*handler)(int shown));
void winios_windows_game_presenting(void);
int winios_windows_shown(void);
int winios_windows_point(double x, double y, int *dx, int *dy);
/* Winios.m + patches/madeira-winios/0011 (PLA-479): a touch on the windows at
 * desktop pixel (x, y) from winios_windows_point, MOUSEEVENTF_* with ABSOLUTE,
 * posted to the window drawn there (not one transparent at that pixel); main
 * thread only. */
void winios_window_pointer(int x, int y, unsigned int flags);

/* host_log.c: one line into the log at path; through stderr once
 * wine_host_init has made fd 2 that file, appended directly before. */
void host_log(const char *path, const char *line);
/* A release build's limit (AppLog.swift): with a nonzero limit, host_log
 * drops a line once the file has reached it. 0, the default, is no limit. */
void host_log_set_limit(long bytes);
/* AppLog.swift's rotation at launch: a log at path over `over` bytes becomes
 * previous, replacing it; a log at or under it stays. */
void host_log_rotate(const char *path, const char *previous, long over);

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
