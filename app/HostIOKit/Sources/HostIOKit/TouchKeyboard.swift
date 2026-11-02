// SPDX-License-Identifier: GPL-3.0-or-later
/// The touch keyboard over the running game (PLA-13,
/// phase 4 item 2; docs/design/2026-10-09-touch-controls/TouchKeyboard.dc.html):
/// a US layout's F row, number row, letters, modifiers and arrows, as a panel
/// across the bottom of the safe area, and its close key above the panel's right end.
///
/// It is part of the on-screen controls: while it is open its keys are
/// TouchControls' targets instead of the layout's (S1Probe OnScreenControls), so
/// what they hold reaches the guest through InputMixer and Lifecycle, and is let
/// go with everything else (the menu, the app leaving the front). A key is held
/// while a finger is on it. Shift, Ctrl and Alt are sticky (TouchControls): a
/// tap holds one down until the next key goes up, a double tap until it is
/// tapped again. The close key and a layout's keyboard key both press
/// `playport:keyboard`, which opens or closes it.
///
/// Each key is a US keyboard's (its HID usage), and its VK is the one KeyMap
/// gives a hardware keyboard's key.
public enum TouchKeyboard {
    public struct Key: Equatable, Sendable {
        /// The target's id: `kb-` and the key's name (`kb-a`, `kb-f1`, `kb-shift`), the driver's `touch:` id.
        public let id: String
        public let label: String
        /// The USB HID usage (UIKeyboardHIDUsage) of the key on a US keyboard.
        public let usage: Int
        /// Its width against a letter key's (the board's flex).
        public let weight: Double
        /// Shift, Ctrl or Alt, the hint's name for it: sticky. Nil for any other key.
        public let modifier: String?

        init(_ name: String, _ label: String, _ usage: Int, _ weight: Double = 1, modifier: String? = nil) {
            id = "kb-" + name
            self.label = label
            self.usage = usage
            self.weight = weight
            self.modifier = modifier
        }

        /// The Windows virtual key it presses (KeyMap).
        public var virtualKey: UInt8 { KeyMap.virtualKey(hidUsage: usage)! }

        var kind: TouchTarget.Kind { modifier != nil ? .modifier(virtualKey) : .key(virtualKey) }
    }

    /// A key laid out: what is drawn (`face`) and what a touch hits (`target`,
    /// the face and half the gap round it, out to the panel's edge).
    public struct PlacedKey: Equatable, Sendable {
        public let key: Key
        public let face: TouchRect
        public let target: TouchTarget
    }

    public struct Layout: Equatable, Sendable {
        /// The panel behind the keys.
        public let panel: TouchRect
        public let keys: [PlacedKey]
        /// The close key, above the panel's right end.
        public let close: TouchTarget
        /// TouchControls' targets: every key, then the close key.
        public var targets: [TouchTarget] { keys.map(\.target) + [close] }
    }

    public static let closeID = "kb-close"
    /// The rows' heights (the F row is lower), the gap between keys and rows, the panel's padding.
    static let rowHeights: [Double] = [24, 30, 30, 30, 30, 30]
    static let gap = 4.0, padding = 8.0
    /// The close key's size, and its gap above the panel.
    static let closeWidth = 84.0, closeHeight = 28.0, closeGap = 4.0

    public static var panelHeight: Double {
        rowHeights.reduce(0, +) + gap * Double(rowHeights.count - 1) + 2 * padding
    }

    public static let rows: [[Key]] = [
        [Key("esc", "Esc", 0x29, 1.3)]
            + (1...12).map { Key("f\($0)", "F\($0)", 0x3A + $0 - 1) }
            + [Key("del", "Del", 0x4C, 1.3)],
        [Key("grave", "`", 0x35)]
            + (1...9).map { Key("\($0)", "\($0)", 0x1E + $0 - 1) }
            + [Key("0", "0", 0x27), Key("minus", "-", 0x2D), Key("equals", "=", 0x2E), Key("backspace", "⌫", 0x2A, 1.6)],
        [Key("tab", "Tab", 0x2B, 1.5)] + letters("QWERTYUIOP")
            + [Key("lbracket", "[", 0x2F), Key("rbracket", "]", 0x30), Key("backslash", "\\", 0x31, 1.1)],
        [Key("caps", "Caps", 0x39, 1.8)] + letters("ASDFGHJKL")
            + [Key("semicolon", ";", 0x33), Key("quote", "'", 0x34), Key("enter", "Enter", 0x28, 1.8)],
        [Key("shift", "⇧ Shift", 0xE1, 2.3, modifier: "Shift")] + letters("ZXCVBNM")
            + [Key("comma", ",", 0x36), Key("period", ".", 0x37), Key("slash", "/", 0x38),
               Key("rshift", "⇧", 0xE5, 2.3, modifier: "Shift")],
        [Key("ctrl", "Ctrl", 0xE0, 1.4, modifier: "Ctrl"), Key("win", "Win", 0xE3, 1.2),
         Key("alt", "Alt", 0xE2, 1.2, modifier: "Alt"), Key("space", "Space", 0x2C, 6.4),
         Key("ralt", "Alt", 0xE6, 1.2, modifier: "Alt"),
         Key("left", "◀", 0x50), Key("down", "▼", 0x51), Key("up", "▲", 0x52), Key("right", "▶", 0x4F)],
    ]

    private static func letters(_ s: String) -> [Key] {
        s.map { c in Key(c.lowercased(), String(c), 0x04 + Int(c.asciiValue! - 65)) }
    }

    /// The sticky modifiers by name, in the order the rows first have them (Shift, Ctrl, Alt), with their keys' ids.
    static let modifiers: [(name: String, ids: Set<String>)] = rows.joined().reduce(into: []) { m, k in
        guard let name = k.modifier else { return }
        if let i = m.firstIndex(where: { $0.name == name }) { m[i].ids.insert(k.id) } else { m.append((name, [k.id])) }
    }

    /// The keyboard in `area` (the safe area): the panel across its bottom.
    public static func layout(in area: TouchRect) -> Layout {
        let panel = TouchRect(x: area.x, y: area.y + area.height - panelHeight, width: area.width, height: panelHeight)
        let inner = panel.width - 2 * padding
        var keys: [PlacedKey] = []
        var y = panel.y + padding
        for (r, row) in rows.enumerated() {
            let h = rowHeights[r]
            // What a touch hits: from the middle of the gap above to the middle of the gap below (the panel's edge at the ends).
            let top = r == 0 ? panel.y : y - gap / 2
            let bottom = r == rows.count - 1 ? panel.maxY : y + h + gap / 2
            let unit = (inner - gap * Double(row.count - 1)) / row.map(\.weight).reduce(0, +)
            var faces: [TouchRect] = []
            var x = panel.x + padding
            for k in row {
                faces.append(TouchRect(x: x, y: y, width: k.weight * unit, height: h))
                x += k.weight * unit + gap
            }
            for (i, k) in row.enumerated() {
                let left = i == 0 ? panel.x : (faces[i - 1].maxX + faces[i].x) / 2
                let right = i == row.count - 1 ? panel.maxX : (faces[i].maxX + faces[i + 1].x) / 2
                let hit = TouchRect(x: left, y: top, width: right - left, height: bottom - top)
                keys.append(PlacedKey(key: k, face: faces[i], target: TouchTarget(id: k.id, kind: k.kind, frame: hit)))
            }
            y += h + gap
        }
        let close = TouchTarget(id: closeID, kind: .button(.playport(.keyboard), .hold),
                                frame: TouchRect(x: panel.maxX - closeWidth, y: panel.y - closeGap - closeHeight,
                                                 width: closeWidth, height: closeHeight))
        return Layout(panel: panel, keys: keys, close: close)
    }

    /// The words beside the close key while a modifier is sticky (the board's
    /// "Shift stays down until the next key"); nil while none is.
    public static func hint(_ sticky: [String: TouchControls.Sticky]) -> String? {
        func names(_ s: TouchControls.Sticky) -> [String] {
            let ids = Set(sticky.filter { $0.value == s }.keys)
            return modifiers.filter { !ids.isDisjoint(with: $0.ids) }.map(\.name)
        }
        func list(_ n: [String]) -> String {
            n.count < 2 ? n.joined() : n.dropLast().joined(separator: ", ") + " and " + n.last!
        }
        let latched = names(.latched), locked = names(.locked)
        let next = "until the next key", again = "until you tap it again"
        func clause(_ n: [String], _ until: String) -> String {
            list(n) + (n.count == 1 ? " stays down " : " stay down ") + until
        }
        switch (latched.isEmpty, locked.isEmpty) {
        case (true, true): return nil
        case (false, true): return clause(latched, next)
        case (true, false): return clause(locked, locked.count == 1 ? again : "until you tap them again")
        case (false, false):
            return clause(latched, next) + ", " + list(locked) + " " + (locked.count == 1 ? again : "until you tap them again")
        }
    }
}
