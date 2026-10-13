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
/// - Controller maps (phase 3): with a table set (`setMap`; nil is the
///   `controller` mode), every physical pad plays through it (MappedPad): its
///   slot gets only its `pad:` actions (at rest with none, so the game sees no
///   pad input from it), its keys and mouse buttons join the controls' (one
///   key held by both goes up when neither holds it), its sticks bound to
///   `mouse:move` move the mouse on each `tick`. The on-screen controls' pad is
///   never mapped: the map is a physical pad's. While the menu or a dialog is
///   up (`hold`) mapped pads hold nothing (their keys and buttons go up), and
///   an input held through it does nothing until let go.
/// - What the pads, `setMap`, `hold` and `tick` send waits in order until
///   `takeOutputs`; `touch` and `gyro` return theirs.
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

    /// Slot 0's physical pad as the guest gets it (after its map).
    private var physical0: PadValues?
    private var touchPad: PadValues?
    private var keysDown: [UInt8] = []
    private var buttonsDown: Set<MouseAction> = []
    private var touchKeys: Set<InputAction> = []
    private var touchMouse: Set<MouseAction> = []
    private var playportDown: Set<PlayportAction> = []
    private var gyroStick: (x: Double, y: Double)?
    /// The controller map's table; nil for the `controller` mode.
    public private(set) var map: ControllerBindings?
    /// Each physical pad's own values, by slot.
    private var raw: [Int: PadValues] = [:]
    private var mapped: [Int: MappedPad] = [:]
    private var holders: Set<GuestPadGate.Holder> = []
    private var pending: [MixerOutput] = []

    public init() {}

    /// What the pads, `setMap`, `hold` and `tick` have sent since the last call, in order.
    public mutating func takeOutputs() -> [MixerOutput] {
        defer { pending = [] }
        return pending
    }

    /// Slot 0's pad as the player holds it, before a controller map: the
    /// physical pad's own values merged with the controls' (gyro aim's pause button reads it).
    public var slot0Input: PadValues? {
        switch (raw[0], touchPad) {
        case let (p?, t?): Self.merge(physical: p, touch: t)
        case let (p?, nil): p
        case let (nil, t?): t
        case (nil, nil): nil
        }
    }

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

    /// A physical pad's new values: what its slot gets. With a map, its keys,
    /// buttons and Playport's actions wait for `takeOutputs`.
    public mutating func physical(slot: Int, _ v: PadValues) -> PadValues {
        raw[slot] = v
        var out = v
        if let map {
            var m = mapped[slot] ?? MappedPad(bindings: map, held: holders)
            pending += m.update(v)
            mapped[slot] = m
            out = m.pad
            sendEdges()
        }
        guard slot == 0 else { return out }
        physical0 = out
        return slot0 ?? out
    }

    /// A physical pad gave up its slot: slot 0 keeps the controls' pad while
    /// they are on. What its map held goes up.
    public mutating func physicalLeft(slot: Int) -> SlotUpdate {
        raw[slot] = nil
        if mapped.removeValue(forKey: slot) != nil { sendEdges() }
        guard slot == 0 else { return .disconnect }
        physical0 = nil
        return slot0.map { .set($0) } ?? .disconnect
    }

    /// The controller map's table for every physical pad (nil: the
    /// `controller` mode, a pad passes through): each connected pad's slot
    /// again. What the old map held goes up; an input down now does nothing
    /// under the new one until it is let go.
    public mutating func setMap(_ b: ControllerBindings?) -> [(slot: Int, values: PadValues)] {
        guard b != map else { return [] }
        map = b
        mapped = [:]
        var out: [(slot: Int, values: PadValues)] = []
        for slot in raw.keys.sorted() {
            guard let v = raw[slot] else { continue }
            var values = v
            if let b {
                let m = MappedPad(bindings: b, values: v, held: holders)
                mapped[slot] = m
                values = m.pad
            }
            if slot == 0 { physical0 = values; values = slot0 ?? values }
            out.append((slot, values))
        }
        sendEdges()
        return out
    }

    /// The menu opens or a dialog comes (`on`), or it goes: mapped pads hold
    /// nothing while either is up (GuestPadGate holds their slots).
    public mutating func hold(_ by: GuestPadGate.Holder, _ on: Bool) {
        if on { holders.insert(by) } else { holders.remove(by) }
        for slot in mapped.keys { mapped[slot]?.hold(by, on) }
        sendEdges()
    }

    /// A mapped stick moves the mouse, or a mapped wheel repeats: `tick` is due on every frame.
    public var needsClock: Bool { mapped.values.contains { $0.needsClock } }

    /// A clock tick at `time` (seconds): every mapped pad's mouse motion as one move, and wheel notches.
    public mutating func tick(time: Double) {
        var dx: Int32 = 0, dy: Int32 = 0
        for slot in mapped.keys.sorted() {
            guard var m = mapped[slot] else { continue }
            for o in m.tick(time: time) {
                if case .move(let x, let y) = o { dx += x; dy += y } else { pending.append(o) }
            }
            mapped[slot] = m
        }
        if dx != 0 || dy != 0 { pending.append(.move(dx: dx, dy: dy)) }
    }

    /// Keys and mouse buttons held by the controls and the mapped pads together,
    /// against what is down: downs (a chord's modifiers first) and ups (last pressed first).
    private mutating func edges() -> [MixerOutput] {
        var out: [MixerOutput] = []
        var keys = touchKeys, mouse = touchMouse
        for m in mapped.values { keys.formUnion(m.keys); mouse.formUnion(m.buttons) }
        let want = Self.virtualKeys(keys)
        for vk in keysDown.reversed() where !want.contains(vk) { out.append(.key(vk, down: false)) }
        let new = want.filter { !keysDown.contains($0) }
        for vk in new { out.append(.key(vk, down: true)) }
        keysDown = keysDown.filter(want.contains) + new   // in press order: ups go last pressed first
        for m in [MouseAction.left, .right, .middle] {
            let was = buttonsDown.contains(m), now = mouse.contains(m)
            guard was != now else { continue }
            switch m {
            case .left: out.append(.pointer(flags: now ? Pointer.leftDown : Pointer.leftUp, data: 0))
            case .right: out.append(.pointer(flags: now ? Pointer.rightDown : Pointer.rightUp, data: 0))
            default: out.append(.pointer(flags: now ? Pointer.middleDown : Pointer.middleUp, data: 0))
            }
        }
        buttonsDown = mouse.intersection([.left, .right, .middle])
        return out
    }

    private mutating func sendEdges() { pending += edges() }

    /// The controls' new state, nil when they are off (hidden): slot 0's
    /// update and the keys, pointer and Playport actions to send.
    public mutating func touch(_ t: TouchOutput?) -> (slot0: SlotUpdate, outputs: [MixerOutput]) {
        let before = slot0
        touchPad = t.map { PadMapping.values($0.pad) }
        let after = slot0
        let slot: SlotUpdate = after == before ? .unchanged : after.map { .set($0) } ?? .disconnect
        let mouse = t?.mouse ?? []
        let wheel = mouse.subtracting(touchMouse)
        touchKeys = t?.keys ?? []
        touchMouse = mouse
        var out = edges()
        if wheel.contains(.wheelUp) { out.append(.pointer(flags: Pointer.wheel, data: 120)) }
        if wheel.contains(.wheelDown) { out.append(.pointer(flags: Pointer.wheel, data: UInt32(bitPattern: -120))) }

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
