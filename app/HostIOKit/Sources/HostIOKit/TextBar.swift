// SPDX-License-Identifier: GPL-3.0-or-later
/// The text bar over a running game (PLA-267; docs/plans/2026-10-12-launchers.md,
/// "Signing in on the phone"): a field the iOS keyboard, AutoFill and paste type
/// into, whose edits reach the focused guest window as typing would.
///
/// The field mirrors what was typed into the guest's field since the bar opened
/// or since Tab or Enter moved on: each change of its text (a key, a paste, an
/// AutoFill, a correction) is sent as Backspaces back to where the old and new
/// text differ, then the new characters. A character is one UTF-16 unit each,
/// posted as KEYEVENTF_UNICODE (WM_CHAR through TranslateMessage), so symbols
/// and letters no US layout has type; a character beyond the BMP is its two
/// surrogates and is taken back with one Backspace (one per Unicode scalar).
/// Tab and a line break in pasted text are their keys and, as the bar's own Tab
/// and Enter, start the field again with what follows them; other control
/// characters are dropped and never enter the field. So the field holds only
/// what the guest's field got, and a Backspace never takes back more than that.
/// Backspace on an empty field still reaches the guest.
///
/// Nothing here, nor `summary`, says what was typed or how much.
public struct TextBar: Equatable, Sendable {
    /// What reaches the guest: one UTF-16 unit as a character, or a key (its VK) pressed and let go.
    public enum Input: Equatable, Sendable {
        case char(UInt16)
        case key(Int32)
    }

    /// The bar's own keys (its buttons, and the keyboard's return and delete).
    public enum Key: Sendable {
        case backspace, tab, enter

        var vk: Int32 {
            switch self {
            case .backspace: 0x08
            case .tab: 0x09
            case .enter: 0x0D
            }
        }
    }

    /// The field's text: what was typed into the guest's field since the bar opened, or since Tab or
    /// Enter, and nothing else (no dropped control character).
    public private(set) var text = ""
    /// Password mode: the field draws dots and offers a password's AutoFill.
    public var secure: Bool

    public init(secure: Bool = false) { self.secure = secure }

    /// The field's text is now `new`: what the guest gets so that its field holds the same. The field
    /// then holds what the guest's does (`text`), which the view shows.
    public mutating func change(to new: String) -> [Input] {
        let old = Array(text.unicodeScalars), now = Array(new.unicodeScalars)
        var same = 0
        while same < old.count, same < now.count, old[same] == now[same] { same += 1 }
        var out = Array(repeating: Input.key(Key.backspace.vk), count: old.count - same)
        var field = String.UnicodeScalarView(old[..<same])
        var previous: Unicode.Scalar?
        for s in now[same...] {
            defer { previous = s }
            switch s {
            case "\t":
                out.append(.key(Key.tab.vk))
                field = String.UnicodeScalarView()
            case "\n" where previous == "\r": continue   // \r\n is one line break
            case "\r", "\n":
                out.append(.key(Key.enter.vk))
                field = String.UnicodeScalarView()
            default:
                guard s.value >= 0x20, s.value != 0x7F, !(0x80..<0xA0).contains(s.value) else { continue }
                out += String(s).utf16.map { .char($0) }
                field.append(s)
            }
        }
        text = String(field)
        return out
    }

    /// `s` typed at the end of the field, as the keyboard would type it.
    public mutating func type(_ s: String) -> [Input] { change(to: text + s) }

    /// One of the bar's keys. Tab and Enter move on in the guest, so the field starts empty again.
    public mutating func press(_ k: Key) -> [Input] {
        switch k {
        case .backspace:
            if !text.isEmpty { text.unicodeScalars.removeLast() }
        case .tab, .enter:
            text = ""
        }
        return [.key(k.vk)]
    }

    /// For a log line: the mode only, never the text or its length.
    public var summary: String { secure ? "secret (not logged)" : "plain (not logged)" }
}
