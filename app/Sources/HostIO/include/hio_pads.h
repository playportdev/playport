/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * hio_pads.h — the controller state the host app hands the runtime.
 *
 * The app's writers (host_io.h: host_pad_set, host_pad_disconnect,
 * host_pads_release_all) put it into Madeira's in-process controller snapshot
 * (Winios/WiniosGamepad.c), which libwin32u_unix.a reads for Wine's own
 * xinput1_*.dll (NtUserGetGamepadState). Design: docs/ARCHITECTURE.md (HostIO).
 */
#ifndef HIO_PADS_H
#define HIO_PADS_H

#include <stdint.h>

#define HIO_PAD_SLOTS 4

/* The XInput gamepad, value for value: buttons are XINPUT_GAMEPAD_* bits,
 * triggers 0..255, thumbs -32768..32767 with +y up. */
typedef struct {
    uint16_t buttons;
    uint8_t left_trigger, right_trigger;
    int16_t thumb_lx, thumb_ly, thumb_rx, thumb_ry;
} hio_pad_state;

#endif
