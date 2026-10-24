// SPDX-License-Identifier: GPL-3.0-or-later

/// Finger ownership stays fixed until lift, including when a finger leaves a button.
/// Multiple fingers may hold one button; lifting one must not release the other.
public struct TouchGamepad: Sendable {
    public enum Control: String, CaseIterable, Sendable {
        case a = "A", b = "B", x = "X", y = "Y"
        case lb = "LB", rb = "RB", lt = "LT", rt = "RT"
        case l3 = "L3", r3 = "R3", back = "Back", start = "Start"
        case up = "↑", down = "↓", left = "←", right = "→"
        case leftStick, rightStick
    }

    private struct Finger: Sendable {
        var control: Control
        var x: Float = 0, y: Float = 0
    }
    private var fingers: [Int: Finger] = [:]
    public init() {}

    public mutating func begin(_ id: Int, control: Control) {
        guard fingers[id] == nil else { return }
        // A stick has one owner; another finger must not move or release it.
        if control == .leftStick || control == .rightStick {
            guard !fingers.values.contains(where: { $0.control == control }) else { return }
        }
        fingers[id] = Finger(control: control)
    }

    public mutating func move(_ id: Int, x: Float, y: Float) {
        guard var f = fingers[id], x.isFinite, y.isFinite else { return }
        let radius = max(1, (x * x + y * y).squareRoot())
        f.x = x / radius; f.y = y / radius
        fingers[id] = f
    }

    public mutating func end(_ id: Int) { fingers[id] = nil }
    public mutating func reset() { fingers.removeAll() }
    public func isHeld(_ control: Control) -> Bool { fingers.values.contains { $0.control == control } }

    public var input: PadInput {
        var p = PadInput()
        for f in fingers.values {
            switch f.control {
            case .a: p.a = true
            case .b: p.b = true
            case .x: p.x = true
            case .y: p.y = true
            case .lb: p.leftShoulder = true
            case .rb: p.rightShoulder = true
            case .lt: p.leftTrigger = 1
            case .rt: p.rightTrigger = 1
            case .l3: p.leftThumb = true
            case .r3: p.rightThumb = true
            case .back: p.options = true
            case .start: p.menu = true
            case .up: p.up = true
            case .down: p.down = true
            case .left: p.left = true
            case .right: p.right = true
            case .leftStick: p.lx = f.x; p.ly = f.y
            case .rightStick: p.rx = f.x; p.ry = f.y
            }
        }
        return p
    }
}

/// Touch shares player one's XInput slot. Physical sticks outside their dead zone
/// win; buttons combine and triggers take the greater value. Other slots pass through.
/// Called under HostIO's existing lock, before its menu/dialog gate.
public struct TouchPadMixer: Sendable {
    private var physical = PadValues(), touch = PadValues()
    public init() {}

    public mutating func input(slot: Int, _ value: PadValues) -> PadValues {
        guard slot == 0 else { return value }
        physical = value
        return combined
    }

    public mutating func input(touch value: PadValues) -> PadValues {
        touch = value
        return combined
    }

    public mutating func disconnect(slot: Int) {
        if slot == 0 { physical = PadValues() }
    }

    public var combined: PadValues {
        var v = physical
        v.buttons |= touch.buttons
        v.leftTrigger = max(v.leftTrigger, touch.leftTrigger)
        v.rightTrigger = max(v.rightTrigger, touch.rightTrigger)
        if (touch.lx != 0 || touch.ly != 0) && Self.resting(v.lx, v.ly, deadZone: 7849) {
            v.lx = touch.lx; v.ly = touch.ly
        }
        if (touch.rx != 0 || touch.ry != 0) && Self.resting(v.rx, v.ry, deadZone: 8689) {
            v.rx = touch.rx; v.ry = touch.ry
        }
        return v
    }

    private static func resting(_ x: Int16, _ y: Int16, deadZone: Int64) -> Bool {
        Int64(x) * Int64(x) + Int64(y) * Int64(y) <= deadZone * deadZone
    }
}
