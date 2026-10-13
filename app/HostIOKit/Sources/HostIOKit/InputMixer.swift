// SPDX-License-Identifier: GPL-3.0-or-later
/// What the guest gets from every input source at once
/// (docs/plans/2026-10-09-touch-controls.md, "Output"): the on-screen controls
/// (TouchControls' output), the physical pads and gyro aim (GyroAim's output).
///
/// - Pads: the touch controls are player 1. While they are on, slot 0 has
///   their pad merged with the physical pad in slot 0, if any, by Madeira's
///   rule: buttons combine, each trigger takes the larger value, and a
///   physical stick outside XInput's dead zone (7849 left, 8689 right) wins
///   over a touch stick; otherwise a deflected touch stick wins, and a resting
///   one leaves the physical value. Other slots pass through. Slot 0 is
///   disconnected only when neither a physical pad nor the controls are there.
/// - Gyro aim on the right stick is added to slot 0's right stick after that
///   merge and clamped to XInput's range; it connects no pad by itself. Gyro
///   aim as a mouse is relative motion (`move`).
/// - Keys and mouse buttons: what the controls hold now against what they held,
///   as downs (a chord's modifiers first) and ups (its key first). HostIO sends
///   them through Lifecycle, which releases them on focus loss as it does a
///   hardware keyboard's.
/// - The wheel and Playport's actions happen once, as their control goes down.
///
/// The pad side runs under HostIO's pad lock, beside GuestPadGate; the rest on
/// the main thread.
public enum MixerOutput: Equatable, Sendable {
    /// winios_post_key(vk, down)
    case key(UInt8, down: Bool)
    /// winios_pointer(0, 0, flags, data): a button's MOUSEEVENTF_* or the wheel.
    case pointer(flags: UInt32, data: UInt32)
    /// winios_pointer(dx, dy, MOUSEEVENTF_MOVE, 0): relative motion, +y down.
    case move(dx: Int32, dy: Int32)
    case playport(PlayportAction)
}

/// What a slot gets after a change.
public enum SlotUpdate: Equatable, Sendable {
    case unchanged
    case set(PadValues)
    case disconnect
}

public struct InputMixer: Sendable {
    /// XInput's thumb dead zones (XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE, _RIGHT_).
    public static let leftDeadZone = 7849.0, rightDeadZone = 8689.0

    private var physical0: PadValues?
    private var touchPad: PadValues?
    private var keysDown: [UInt8] = []
    private var mouseDown: Set<MouseAction> = []
    private var playportDown: Set<PlayportAction> = []
    private var gyroStick: (x: Double, y: Double)?

    public init() {}

    /// Whether the touch controls are on (their pad is in slot 0).
    public var touchOn: Bool { touchPad != nil }

    /// Slot 0 as the guest should have it now; nil for disconnected.
    public var slot0: PadValues? {
        let pad: PadValues? = switch (physical0, touchPad) {
        case let (p?, t?): Self.merge(physical: p, touch: t)
        case let (p?, nil): p
        case let (nil, t?): t
        case (nil, nil): nil
        }
        guard let pad, let g = gyroStick else { return pad }
        return Self.add(rightStick: g, to: pad)
    }

    /// A physical pad's new values: what its slot gets.
    public mutating func physical(slot: Int, _ v: PadValues) -> PadValues {
        guard slot == 0 else { return v }
        physical0 = v
        return slot0 ?? v
    }

    /// A physical pad gave up its slot: slot 0 keeps the controls' pad while they are on.
    public mutating func physicalLeft(slot: Int) -> SlotUpdate {
        guard slot == 0 else { return .disconnect }
        physical0 = nil
        return slot0.map { .set($0) } ?? .disconnect
    }

    /// The controls' new state, nil when they are off (hidden): slot 0's
    /// update and the keys, pointer and Playport actions to send.
    public mutating func touch(_ t: TouchOutput?) -> (slot0: SlotUpdate, outputs: [MixerOutput]) {
        let before = slot0
        touchPad = t.map { PadMapping.values($0.pad) }
        let after = slot0
        let slot: SlotUpdate = after == before ? .unchanged : after.map { .set($0) } ?? .disconnect
        var out: [MixerOutput] = []

        let want = Self.virtualKeys(t?.keys ?? [])
        for vk in keysDown.reversed() where !want.contains(vk) { out.append(.key(vk, down: false)) }
        let new = want.filter { !keysDown.contains($0) }
        for vk in new { out.append(.key(vk, down: true)) }
        keysDown = keysDown.filter(want.contains) + new   // in press order: ups go last pressed first

        let mouse = t?.mouse ?? []
        for m in MouseAction.allCases {
            let was = mouseDown.contains(m), now = mouse.contains(m)
            guard was != now else { continue }
            switch m {
            case .left: out.append(.pointer(flags: now ? Pointer.leftDown : Pointer.leftUp, data: 0))
            case .right: out.append(.pointer(flags: now ? Pointer.rightDown : Pointer.rightUp, data: 0))
            case .middle: out.append(.pointer(flags: now ? Pointer.middleDown : Pointer.middleUp, data: 0))
            case .wheelUp: if now { out.append(.pointer(flags: Pointer.wheel, data: 120)) }
            case .wheelDown: if now { out.append(.pointer(flags: Pointer.wheel, data: UInt32(bitPattern: -120))) }
            }
        }
        mouseDown = mouse

        let playport = t?.playport ?? []
        for p in PlayportAction.allCases where playport.contains(p) && !playportDown.contains(p) { out.append(.playport(p)) }
        playportDown = playport
        return (slot, out)
    }

    /// Gyro aim's output for one sample: a right-stick deflection changes slot 0,
    /// mouse motion is sent as it is; any other output takes the gyro off the stick.
    public mutating func gyro(_ o: GyroAimOutput) -> (slot0: SlotUpdate, outputs: [MixerOutput]) {
        let before = slot0
        var out: [MixerOutput] = []
        switch o {
        case .rightStick(let x, let y):
            gyroStick = (x, y)
        case .mouse(let dx, let dy):
            gyroStick = nil
            if dx != 0 || dy != 0 { out.append(.move(dx: dx, dy: dy)) }
        case .none:
            gyroStick = nil
        }
        let after = slot0
        return (after == before ? .unchanged : after.map { .set($0) } ?? .disconnect, out)
    }

    /// A deflection (-1...1, +y up) added to the right stick, clamped to XInput's range.
    static func add(rightStick g: (x: Double, y: Double), to v: PadValues) -> PadValues {
        func sum(_ a: Int16, _ d: Double) -> Int16 {
            guard d.isFinite else { return a }
            return Int16(max(-32768, min(32767, (Double(a) + d * 32767).rounded())))
        }
        var out = v
        out.rx = sum(v.rx, g.x)
        out.ry = sum(v.ry, g.y)
        return out
    }

    /// The VKs a set of key actions holds: every chord's modifiers, then the keys, each once.
    static func virtualKeys(_ keys: Set<InputAction>) -> [UInt8] {
        var mods: [UInt8] = [], main: [UInt8] = []
        for case let .key(vk, m) in keys.sorted(by: { $0.name < $1.name }) {
            for v in m.virtualKeys where !mods.contains(v) { mods.append(v) }
            if !main.contains(vk) { main.append(vk) }
        }
        return mods.sorted() + main.filter { !mods.contains($0) }
    }

    public static func merge(physical p: PadValues, touch t: PadValues) -> PadValues {
        var out = p
        out.buttons |= t.buttons
        out.leftTrigger = max(p.leftTrigger, t.leftTrigger)
        out.rightTrigger = max(p.rightTrigger, t.rightTrigger)
        func length(_ x: Int16, _ y: Int16) -> Double { (Double(x) * Double(x) + Double(y) * Double(y)).squareRoot() }
        if length(p.lx, p.ly) <= leftDeadZone, t.lx != 0 || t.ly != 0 { out.lx = t.lx; out.ly = t.ly }
        if length(p.rx, p.ry) <= rightDeadZone, t.rx != 0 || t.ry != 0 { out.rx = t.rx; out.ry = t.ry }
        return out
    }
}
