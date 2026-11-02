// SPDX-License-Identifier: GPL-3.0-or-later
// What an on-screen control shows (TouchKeyboardMouse.dc.html, TouchPointer.dc.html;
// S1Probe's UI/TouchControlsView.swift draws it).
//
// - A button whose label names something else than its key shows the key's cap
//   over the label, small: "E" over USE, "␣" over JUMP. A label that is the
//   key's name (Esc, Tab, 1, Shift+1, Space) shows alone.
// - A mouse button shows the mouse over its label (Fire), the touch keyboard's
//   key the keyboard (over its label, Keys, when the label has words).
// - A label with no letter is a glyph, shown alone (Gamepad's ⧉ and ≡, ⌨).
// - Pad buttons and every other kind show their label.
// - A key stick (W A S D) shows its four keys' names, up, down, left, right.

import HostIOKit

public struct ControlFace: Equatable, Sendable {
    public enum Cap: Equatable, Sendable {
        case text(String)
        /// The mouse, this button lit.
        case mouse(MouseAction)
        /// The touch keyboard's key.
        case keyboard
    }

    public var cap: Cap
    /// The label under the cap, nil when the cap says it.
    public var caption: String?

    public init(cap: Cap, caption: String?) { self.cap = cap; self.caption = caption }
}

extension Control {
    public var face: ControlFace {
        let words = label.contains { $0.isLetter }
        guard kind == .button, let a = actions.first else { return ControlFace(cap: .text(label), caption: nil) }
        switch a {
        case .key(let vk, let m):
            let name = ActionText.name(a)
            guard words, label != name else { return ControlFace(cap: .text(label), caption: nil) }
            return ControlFace(cap: .text(vk == 0x20 && m.isEmpty ? "␣" : name), caption: label)
        case .mouse(let b):
            return ControlFace(cap: .mouse(b), caption: words ? label : nil)
        case .playport(.keyboard):
            return ControlFace(cap: .keyboard, caption: words ? label : nil)
        case .pad, .playport(.menu):
            return ControlFace(cap: .text(label), caption: nil)
        }
    }

    /// A key stick's four keys' names (up, down, left, right); nil for any other control.
    public var keyLetters: [String]? {
        guard kind == .stick, actions.count == 4 else { return nil }
        return actions.map {
            switch $0 {
            case .key(let vk, _): ActionText.key(vk)
            case .pad(let c): ActionText.pad(c)
            default: ActionText.name($0)
            }
        }
    }
}
