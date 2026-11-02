/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * keys_test.c — hio_keys.c on the Linux host (pp test): the scan code
 * winios_drv_post_key gives a posted virtual key before Wine's map. The nav
 * cluster carries E0 on the numpad's scan code (an arrow is not numpad
 * 8/2/4/6 to a scan-code reader, PLA-340), the numpad's own keys do not,
 * and a key whose scan code depends on the layout is left to Wine (0).
 */
#include "host_io.h"

#include <stdio.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

int main(void)
{
    /* Arrows: E0 + the numpad 8/2/4/6 scan code. */
    CHECK(playport_key_scan(0x26) == 0xE048);   /* Up */
    CHECK(playport_key_scan(0x28) == 0xE050);   /* Down */
    CHECK(playport_key_scan(0x25) == 0xE04B);   /* Left */
    CHECK(playport_key_scan(0x27) == 0xE04D);   /* Right */
    /* The nav cluster: E0 + its numpad twin's scan code. */
    CHECK(playport_key_scan(0x2D) == 0xE052);   /* Insert: numpad 0 */
    CHECK(playport_key_scan(0x2E) == 0xE053);   /* Delete: numpad . */
    CHECK(playport_key_scan(0x24) == 0xE047);   /* Home: numpad 7 */
    CHECK(playport_key_scan(0x23) == 0xE04F);   /* End: numpad 1 */
    CHECK(playport_key_scan(0x21) == 0xE049);   /* Page Up: numpad 9 */
    CHECK(playport_key_scan(0x22) == 0xE051);   /* Page Down: numpad 3 */
    /* Print Screen is E0 37, not Wine's first match 0x54 (SysRq). */
    CHECK(playport_key_scan(0x2C) == 0xE037);
    /* Right Ctrl and Alt are E0 + the left key's code; Win, menu, keypad /. */
    CHECK(playport_key_scan(0xA3) == 0xE01D);
    CHECK(playport_key_scan(0xA5) == 0xE038);
    CHECK(playport_key_scan(0x5B) == 0xE05B);
    CHECK(playport_key_scan(0x5C) == 0xE05C);
    CHECK(playport_key_scan(0x5D) == 0xE05D);
    CHECK(playport_key_scan(0x6F) == 0xE035);

    /* The numpad's own keys stay unextended (Wine's map gives 0x48 etc.). */
    for (unsigned vk = 0x60; vk <= 0x69; vk++) CHECK(playport_key_scan(vk) == 0);   /* numpad 0-9 */
    CHECK(playport_key_scan(0x6E) == 0);   /* numpad . */
    /* Left modifiers and Return are not extended; letters and punctuation
     * move with the layout: all left to Wine. */
    CHECK(playport_key_scan(0xA2) == 0);   /* left Ctrl */
    CHECK(playport_key_scan(0xA4) == 0);   /* left Alt */
    CHECK(playport_key_scan(0xA0) == 0);   /* left Shift */
    CHECK(playport_key_scan(0xA1) == 0);   /* right Shift: 0x36, no E0 */
    CHECK(playport_key_scan(0x0D) == 0);   /* Return */
    CHECK(playport_key_scan('W') == 0);
    CHECK(playport_key_scan(0xBA) == 0);   /* ; */
    CHECK(playport_key_scan(0) == 0);
    CHECK(playport_key_scan(0x1FF) == 0);

    /* Every code it gives is E0-prefixed. */
    for (unsigned vk = 0; vk < 0x100; vk++) {
        unsigned s = playport_key_scan(vk);
        CHECK(s == 0 || (s & 0xFF00) == 0xE000);
    }

    if (failures) return 1;
    printf("keys: ok\n");
    return 0;
}
