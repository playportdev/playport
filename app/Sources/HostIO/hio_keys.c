/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * hio_keys.c — the scan code of a key the app posts by its virtual key
 * (winios_post_key: the hardware keyboard, mapped buttons, the touch
 * keyboard). win32u's winios_drv_post_key asks here first
 * (patches/madeira-unix 0248) and falls back to Wine's
 * MapVirtualKeyEx(MAPVK_VK_TO_VSC_EX).
 *
 * That fallback is wrong for the nav cluster: Wine's kbdus table lists the
 * arrows, Insert/Delete/Home/End/PgUp/PgDn and Print Screen on the numpad's
 * scan codes first (T48 is VK_UP), so it answers 0x48 for VK_UP with no E0,
 * and a game reading scan codes (raw input, DirectInput) sees numpad 8. A
 * real keyboard sends these keys with the E0 prefix. Their scan codes are the
 * same on every layout, so a fixed table is right where Wine's is not.
 * Plain C11 so tests/keys_test.c runs it on the Linux host.
 */

#include "host_io.h"

unsigned int playport_key_scan(unsigned int vk)
{
    switch (vk)
    {
    case 0x21: return 0xE049;   /* VK_PRIOR (Page Up) */
    case 0x22: return 0xE051;   /* VK_NEXT (Page Down) */
    case 0x23: return 0xE04F;   /* VK_END */
    case 0x24: return 0xE047;   /* VK_HOME */
    case 0x25: return 0xE04B;   /* VK_LEFT */
    case 0x26: return 0xE048;   /* VK_UP */
    case 0x27: return 0xE04D;   /* VK_RIGHT */
    case 0x28: return 0xE050;   /* VK_DOWN */
    case 0x2C: return 0xE037;   /* VK_SNAPSHOT (Print Screen) */
    case 0x2D: return 0xE052;   /* VK_INSERT */
    case 0x2E: return 0xE053;   /* VK_DELETE */
    case 0x5B: return 0xE05B;   /* VK_LWIN */
    case 0x5C: return 0xE05C;   /* VK_RWIN */
    case 0x5D: return 0xE05D;   /* VK_APPS */
    case 0x6F: return 0xE035;   /* VK_DIVIDE (keypad /) */
    case 0xA3: return 0xE01D;   /* VK_RCONTROL */
    case 0xA5: return 0xE038;   /* VK_RMENU (right Alt) */
    default:   return 0;
    }
}
