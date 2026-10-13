// SPDX-License-Identifier: GPL-3.0-or-later
/// What one on-screen control (and, later, one controller button) does: the
/// single model every input source is mapped through (docs/plans/2026-10-09-touch-controls.md,
/// "Actions"). InputMixer turns the actions held at a moment into the guest's
/// pad slot, keys and pointer, and Playport's own actions.
///
/// Saved layouts (PlayportKit ControlLayout) keep an action as its `name`:
/// `pad:a`, `pad:leftStick`, `key:0x20`, `key:shift+0x31`, `mouse:left`,
/// `mouse:wheelUp`, `mouse:move`, `playport:menu`.
public enum InputAction: Hashable, Sendable {
    /// A control of the XInput pad in slot 0.
    case pad(PadControl)
    /// A Windows virtual key, with the modifiers held around it.
    case key(UInt8, KeyModifiers)
    /// A mouse button, one notch of the wheel, or a stick's motion.
    case mouse(MouseAction)
    /// Playport's own: the in-game menu.
    case playport(PlayportAction)
}

/// A control of the Xbox pad as XInput reports it. The sticks are analogue:
/// a touch stick gives them their deflection.
public enum PadControl: String, CaseIterable, Sendable {
    case a, b, x, y, lb, rb, lt, rt, start, back, ls, rs, up, down, left, right
    case leftStick, rightStick

    /// The stick's own button (L3, R3), pressed by a double-tap on a touch stick.
    public var thumb: PadControl? {
        switch self {
        case .leftStick: .ls
        case .rightStick: .rs
        default: nil
        }
    }

    public var isStick: Bool { self == .leftStick || self == .rightStick }
}

public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let control = KeyModifiers(rawValue: 2)
    public static let alt = KeyModifiers(rawValue: 4)

    /// The modifiers' left-hand VKs (VK_LSHIFT, VK_LCONTROL, VK_LMENU), in the order they go down.
    public var virtualKeys: [UInt8] {
        [(Self.shift, UInt8(0xA0)), (Self.control, 0xA2), (Self.alt, 0xA4)].compactMap { contains($0.0) ? $0.1 : nil }
    }

    static let names: [(KeyModifiers, String)] = [(.shift, "shift"), (.control, "ctrl"), (.alt, "alt")]
}

public enum MouseAction: String, CaseIterable, Sendable {
    case left, right, middle, wheelUp, wheelDown
    /// Relative motion: a controller's stick bound whole to it moves the mouse
    /// (MappedPad); nothing else takes it (a touch button with it moves nothing).
    case move
}

public enum PlayportAction: String, CaseIterable, Sendable {
    /// Playport's in-game menu (InGameMenu.swift), as holding a controller's Home opens it.
    case menu
}

extension InputAction {
    /// The saved form: `pad:a`, `key:shift+0x31`, `mouse:left`, `playport:menu`.
    public var name: String {
        switch self {
        case .pad(let c): return "pad:" + c.rawValue
        case .key(let vk, let m):
            let mods = KeyModifiers.names.filter { m.contains($0.0) }.map { $0.1 + "+" }.joined()
            let hex = String(vk, radix: 16, uppercase: true)
            return "key:" + mods + "0x" + (hex.count < 2 ? "0" : "") + hex
        case .mouse(let m): return "mouse:" + m.rawValue
        case .playport(let p): return "playport:" + p.rawValue
        }
    }

    /// An action from its saved form; nil for one this build does not know.
    public init?(name: String) {
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "pad":
            guard let c = PadControl(rawValue: parts[1]) else { return nil }
            self = .pad(c)
        case "key":
            var words = parts[1].split(separator: "+").map(String.init)
            guard let last = words.popLast() else { return nil }
            var mods: KeyModifiers = []
            for w in words {
                guard let m = KeyModifiers.names.first(where: { $0.1 == w.lowercased() }) else { return nil }
                mods.insert(m.0)
            }
            let digits = last.lowercased().hasPrefix("0x") ? String(last.dropFirst(2)) : last
            guard let vk = UInt8(digits, radix: last.lowercased().hasPrefix("0x") ? 16 : 10), vk != 0 else { return nil }
            self = .key(vk, mods)
        case "mouse":
            guard let m = MouseAction(rawValue: parts[1]) else { return nil }
            self = .mouse(m)
        case "playport":
            guard let p = PlayportAction(rawValue: parts[1]) else { return nil }
            self = .playport(p)
        default:
            return nil
        }
    }
}

extension InputAction: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let a = InputAction(name: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "\(s) is not an input action")
        }
        self = a
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}
