// SPDX-License-Identifier: GPL-3.0-or-later
/// A game controller as XInput sees it.
///
/// GameController's extended gamepad maps onto the Xbox layout by position:
/// the bottom face button is A, the menu button is START, the options button
/// BACK. Sticks keep +y up, as XInput does. The Home button is Playport's
/// (the in-game menu, InGameMenu.swift): PadMapping gives the guest nothing for it.
public struct PadInput: Equatable, Sendable {
    public var a = false, b = false, x = false, y = false
    public var leftShoulder = false, rightShoulder = false
    public var menu = false, options = false, home = false
    public var leftThumb = false, rightThumb = false
    public var up = false, down = false, left = false, right = false
    public var leftTrigger: Float = 0, rightTrigger: Float = 0            // 0...1
    public var lx: Float = 0, ly: Float = 0, rx: Float = 0, ry: Float = 0 // -1...1
    public init() {}
}

/// hio_pad_state's values (app/Sources/HostIO/include/hio_pads.h).
public struct PadValues: Equatable, Sendable {
    public var buttons: UInt16 = 0
    public var leftTrigger: UInt8 = 0, rightTrigger: UInt8 = 0
    public var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0
    public init() {}
}

public enum PadMapping {
    // XINPUT_GAMEPAD_* (xinput.h)
    public static let dpadUp: UInt16 = 0x0001, dpadDown: UInt16 = 0x0002, dpadLeft: UInt16 = 0x0004, dpadRight: UInt16 = 0x0008
    public static let start: UInt16 = 0x0010, back: UInt16 = 0x0020, leftThumb: UInt16 = 0x0040, rightThumb: UInt16 = 0x0080
    public static let leftShoulder: UInt16 = 0x0100, rightShoulder: UInt16 = 0x0200
    public static let a: UInt16 = 0x1000, b: UInt16 = 0x2000, x: UInt16 = 0x4000, y: UInt16 = 0x8000

    public static func values(_ p: PadInput) -> PadValues {
        var v = PadValues()
        let bits: [(Bool, UInt16)] = [
            (p.up, dpadUp), (p.down, dpadDown), (p.left, dpadLeft), (p.right, dpadRight),
            (p.menu, start), (p.options, back), (p.leftThumb, leftThumb), (p.rightThumb, rightThumb),
            (p.leftShoulder, leftShoulder), (p.rightShoulder, rightShoulder), (p.a, a), (p.b, b), (p.x, x), (p.y, y),
        ]
        for (on, bit) in bits where on { v.buttons |= bit }
        v.leftTrigger = trigger(p.leftTrigger)
        v.rightTrigger = trigger(p.rightTrigger)
        v.lx = thumb(p.lx); v.ly = thumb(p.ly); v.rx = thumb(p.rx); v.ry = thumb(p.ry)
        return v
    }

    static func trigger(_ f: Float) -> UInt8 {
        guard f.isFinite else { return 0 }
        return UInt8(max(0, min(255, (f * 255).rounded())))
    }

    /// -1 → -32768, 1 → 32767, 0 → 0.
    static func thumb(_ f: Float) -> Int16 {
        guard f.isFinite else { return 0 }
        let c = max(-1, min(1, f))
        return Int16(c < 0 ? (c * 32768).rounded() : (c * 32767).rounded())
    }
}

/// XInput has four slots; controllers take the lowest free one when they
/// connect and give it up when they disconnect, so a reconnecting pad does not
/// shift the others.
public struct PadSlots<Key: Hashable> {
    private var slots: [Key?] = [nil, nil, nil, nil]
    public init() {}

    /// The slot for key, assigning one if it has none; nil when all four are taken.
    public mutating func connect(_ key: Key) -> Int? {
        if let i = slots.firstIndex(of: key) { return i }
        guard let i = slots.firstIndex(where: { $0 == nil }) else { return nil }
        slots[i] = key
        return i
    }

    /// The slot key held, now free.
    public mutating func disconnect(_ key: Key) -> Int? {
        guard let i = slots.firstIndex(of: key) else { return nil }
        slots[i] = nil
        return i
    }

    public func slot(of key: Key) -> Int? { slots.firstIndex(of: key) }
}
