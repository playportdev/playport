// SPDX-License-Identifier: GPL-3.0-or-later
/// Hardware keyboard → Windows virtual-key code.
///
/// UIKit reports a key as its USB HID usage (`UIKey.keyCode`, a
/// `UIKeyboardHIDUsage`); Wine wants the VK the key has on a US layout, and
/// derives the scan code from it (Madeira driver_ios.c winios_drv_post_key).
/// Keys with no VK here (media keys, the globe key, international extras)
/// are not forwarded.
public enum KeyMap {
    public static func virtualKey(hidUsage u: Int) -> UInt8? {
        switch u {
        case 0x04...0x1D: return UInt8(0x41 + u - 0x04)       // A-Z
        case 0x1E...0x26: return UInt8(0x31 + u - 0x1E)       // 1-9
        case 0x27: return 0x30                                // 0
        case 0x3A...0x45: return UInt8(0x70 + u - 0x3A)       // F1-F12
        case 0x68...0x73: return UInt8(0x7C + u - 0x68)       // F13-F24
        case 0x59...0x61: return UInt8(0x61 + u - 0x59)       // keypad 1-9
        default: return table[u]
        }
    }

    static let table: [Int: UInt8] = [
        0x28: 0x0D, // Return
        0x29: 0x1B, // Escape
        0x2A: 0x08, // Backspace
        0x2B: 0x09, // Tab
        0x2C: 0x20, // Space
        0x2D: 0xBD, // - (VK_OEM_MINUS)
        0x2E: 0xBB, // = (VK_OEM_PLUS)
        0x2F: 0xDB, // [
        0x30: 0xDD, // ]
        0x31: 0xDC, // backslash
        0x32: 0xDC, // non-US # (the same key position)
        0x33: 0xBA, // ;
        0x34: 0xDE, // '
        0x35: 0xC0, // `
        0x36: 0xBC, // ,
        0x37: 0xBE, // .
        0x38: 0xBF, // /
        0x39: 0x14, // Caps Lock
        0x46: 0x2C, // Print Screen
        0x47: 0x91, // Scroll Lock
        0x48: 0x13, // Pause
        0x49: 0x2D, // Insert
        0x4A: 0x24, // Home
        0x4B: 0x21, // Page Up
        0x4C: 0x2E, // Delete
        0x4D: 0x23, // End
        0x4E: 0x22, // Page Down
        0x4F: 0x27, // Right
        0x50: 0x25, // Left
        0x51: 0x28, // Down
        0x52: 0x26, // Up
        0x53: 0x90, // Num Lock
        0x54: 0x6F, // keypad /
        0x55: 0x6A, // keypad *
        0x56: 0x6D, // keypad -
        0x57: 0x6B, // keypad +
        0x58: 0x0D, // keypad Enter (Wine marks it extended from the scan code)
        0x62: 0x60, // keypad 0
        0x63: 0x6E, // keypad .
        0x64: 0xE2, // non-US backslash (VK_OEM_102)
        0x65: 0x5D, // Application (menu)
        0xE0: 0xA2, // left Control
        0xE1: 0xA0, // left Shift
        0xE2: 0xA4, // left Alt (Option)
        0xE3: 0x5B, // left GUI (Command) -> left Windows
        0xE4: 0xA3, // right Control
        0xE5: 0xA1, // right Shift
        0xE6: 0xA5, // right Alt
        0xE7: 0x5C, // right GUI
    ]
}
