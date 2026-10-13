// SPDX-License-Identifier: GPL-3.0-or-later
/// A controller map's table (docs/plans/2026-10-09-touch-controls.md,
/// "Controller maps"): what each physical input of a controller does, as an
/// InputAction. PlayportKit ControllerMap holds the mode and the
/// `keyboardMouse` preset; MappedPad plays a physical pad through a table.
///
/// - A button, a trigger or a d-pad direction does any action but a stick's
///   (`pad:leftStick`, `pad:rightStick`, `mouse:move`).
/// - A stick is bound whole, to mouse motion (`mouse:move`) or to a pad stick,
///   or by its four directions (`leftStick.up` ...), each like a button; not both.
/// - Home is never an input here: it stays Playport's (QuickMenuControl).
///
/// Saved as a JSON object from input name to action name:
/// `{"a":"key:0x20","rt":"mouse:left","leftStick.up":"key:0x57","rightStick":"mouse:move"}`.
public enum ControllerInput: Hashable, Sendable {
    /// A button, a trigger, a d-pad direction, or a whole stick.
    case control(PadControl)
    /// One direction of a stick, pressed past MappedPad's threshold.
    case stickDirection(PadControl, StickDirection)

    /// `a`, `lt`, `leftStick`, `leftStick.up`.
    public var name: String {
        switch self {
        case .control(let c): c.rawValue
        case .stickDirection(let s, let d): s.rawValue + "." + d.rawValue
        }
    }

    public init?(name: String) {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            guard let c = PadControl(rawValue: parts[0]) else { return nil }
            self = .control(c)
        case 2:
            guard let s = PadControl(rawValue: parts[0]), s.isStick, let d = StickDirection(rawValue: parts[1]) else { return nil }
            self = .stickDirection(s, d)
        default:
            return nil
        }
    }

    /// Every input a table can bind, in the pad's order.
    public static let all: [ControllerInput] = PadControl.allCases.map { .control($0) }
        + [PadControl.leftStick, .rightStick].flatMap { s in StickDirection.allCases.map { .stickDirection(s, $0) } }

    /// Whether `action` may be bound to this input.
    public func accepts(_ action: InputAction) -> Bool {
        let stickAction: Bool = switch action {
        case .pad(let c): c.isStick
        case .mouse(.move): true
        default: false
        }
        if case .control(let c) = self, c.isStick { return stickAction }
        return !stickAction
    }

    /// The stick this input belongs to, nil for a button, trigger or d-pad direction.
    public var stick: PadControl? {
        switch self {
        case .control(let c): c.isStick ? c : nil
        case .stickDirection(let s, _): s
        }
    }
}

public enum StickDirection: String, CaseIterable, Sendable {
    case up, down, left, right
}

public struct ControllerBindings: Hashable, Sendable {
    public private(set) var table: [ControllerInput: InputAction]

    /// The table, nil when it binds an action an input does not take, or a stick both whole and by direction.
    public init?(_ table: [ControllerInput: InputAction]) {
        guard table.allSatisfy({ $0.key.accepts($0.value) }) else { return nil }
        for s in [PadControl.leftStick, .rightStick] where table[.control(s)] != nil {
            if StickDirection.allCases.contains(where: { table[.stickDirection(s, $0)] != nil }) { return nil }
        }
        self.table = table
    }

    public subscript(_ input: ControllerInput) -> InputAction? { table[input] }

    /// The table by name, as it is saved.
    public var names: [String: String] {
        Dictionary(uniqueKeysWithValues: table.map { ($0.key.name, $0.value.name) })
    }
}

extension ControllerBindings: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let names = try c.decode([String: InputAction].self)
        var table: [ControllerInput: InputAction] = [:]
        for (k, a) in names {
            guard let input = ControllerInput(name: k) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "\(k) is not a controller input")
            }
            table[input] = a
        }
        guard let b = ControllerBindings(table) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "a stick's action on a button, or a stick bound twice")
        }
        self = b
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(table.reduce(into: [String: InputAction]()) { $0[$1.key.name] = $1.value })
    }
}
