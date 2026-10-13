// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A physical pad played through a controller map's table (ControllerBindings;
/// docs/plans/2026-10-09-touch-controls.md, phase 3): what InputMixer sends for
/// a pad whose map is not `controller`.
///
/// - Buttons and d-pad directions hold their action while down. A trigger, or
///   a stick's direction, holds it from `Tuning.pressAt` until it falls under
///   `Tuning.releaseAt` (hysteresis, so a value at the threshold does not
///   flicker). A stick's directions are its two axes apart, so a diagonal
///   holds two (W and D).
/// - A stick bound to `mouse:move` moves the mouse at a speed set by its
///   deflection (`Tuning.velocity`), on each clock tick, whole counts out and
///   the rest carried (RelativeMotion).
/// - The wheel turns one notch as its input goes down, then repeats while it
///   is held (`Tuning.wheelDelay`, `Tuning.wheelInterval`); Playport's actions
///   happen once, as their input goes down.
/// - `pad:` actions make the values the pad's slot gets; with none bound the
///   slot is at rest, so the game sees no pad input from this pad. A trigger
///   bound to a trigger, and a stick bound to a stick, keep their analogue value.
/// - Held (the in-game menu or a guest dialog is up): it holds no key or
///   button, moves nothing, and every input down then, or pressed while held,
///   does nothing until it is let go (as GuestPadGate does for a pad's buttons).
///   An input down as the pad starts with a new table does the same.
public struct MappedPad: Sendable {
    /// Every number that shapes a mapped pad, in one place.
    public enum Tuning {
        /// A trigger or a stick's direction is pressed from this value (0...1)...
        public static let pressAt = 0.5
        /// ...and let go under this one.
        public static let releaseAt = 0.4
        /// Stick to mouse: no motion within this deflection (a resting stick drifts)...
        public static let mouseDeadZone = 0.15
        /// ...then speed = maxSpeed × t^curve, t the deflection past the dead zone over what is left (0...1):
        /// fine aim near the centre, a quick turn at the rim.
        public static let mouseCurve = 2.0
        /// Mouse counts a second at full deflection.
        public static let mouseMaxSpeed = 2000.0
        /// The longest gap between two ticks that counts (a stalled clock does not jump the view).
        public static let maxTickGap = 0.05
        /// The wheel repeats this long after its input goes down...
        public static let wheelDelay = 0.35
        /// ...then once every this often.
        public static let wheelInterval = 0.1

        /// A stick's deflection (-1...1, +y up) as mouse counts a second (+y down).
        public static func velocity(x: Double, y: Double) -> (dx: Double, dy: Double) {
            guard x.isFinite, y.isFinite else { return (0, 0) }
            let m = (x * x + y * y).squareRoot()
            guard m > mouseDeadZone else { return (0, 0) }
            let t = min(1, (m - mouseDeadZone) / (1 - mouseDeadZone))
            let speed = mouseMaxSpeed * pow(t, mouseCurve)
            return (speed * x / m, -speed * y / m)
        }
    }

    public let bindings: ControllerBindings
    private var values = PadValues()
    /// The inputs pressed now (by Tuning's hysteresis for triggers and stick directions).
    private var active: Set<ControllerInput> = []
    /// Pressed inputs that do nothing until let go.
    private var latched: Set<ControllerInput> = []
    private var holders: Set<GuestPadGate.Holder> = []
    private var motion = RelativeMotion()
    private var lastTick: Double?
    /// When each held wheel input turns the wheel next; nil until the first tick after its press.
    private var wheelNext: [ControllerInput: Double?] = [:]

    /// A pad with this table; `held` its inputs down now, which do nothing until let go.
    public init(bindings: ControllerBindings, values v: PadValues = PadValues(), held: Set<GuestPadGate.Holder> = []) {
        self.bindings = bindings
        holders = held
        values = v
        active = pressed(v)
        latched = active
    }

    /// Whether this pad holds no key or button now (the menu or a dialog).
    public var isHeld: Bool { !holders.isEmpty }

    /// The pad's new values: Playport's actions and wheel notches due now.
    public mutating func update(_ v: PadValues) -> [MixerOutput] {
        values = v
        let now = pressed(v)
        let down = now.subtracting(active)
        active = now
        latched.formIntersection(now)
        if isHeld { latched.formUnion(now) }
        var out: [MixerOutput] = []
        for input in ControllerInput.all where down.contains(input) && !latched.contains(input) {
            switch bindings[input] {
            case .mouse(.wheelUp)?:
                out.append(.pointer(flags: Pointer.wheel, data: 120))
                wheelNext[input] = .some(nil)
            case .mouse(.wheelDown)?:
                out.append(.pointer(flags: Pointer.wheel, data: UInt32(bitPattern: -120)))
                wheelNext[input] = .some(nil)
            case .playport(let p)?:
                out.append(.playport(p))
            default:
                break
            }
        }
        wheelNext = wheelNext.filter { live.contains($0.key) }
        if velocity == nil { lastTick = nil }
        return out
    }

    /// The menu opens or a dialog comes (`on`), or it goes: held, every input down now does nothing until let go.
    public mutating func hold(_ by: GuestPadGate.Holder, _ on: Bool) {
        if on {
            holders.insert(by)
            latched = active
            wheelNext = [:]
            lastTick = nil
        } else {
            holders.remove(by)
        }
    }

    /// The inputs that act now.
    private var live: Set<ControllerInput> { isHeld ? [] : active.subtracting(latched) }

    /// The key actions held now.
    public var keys: Set<InputAction> {
        Set(live.compactMap { i -> InputAction? in
            guard case .key? = bindings[i] else { return nil }
            return bindings[i]
        })
    }

    /// The mouse buttons held now (left, right, middle).
    public var buttons: Set<MouseAction> {
        Set(live.compactMap { i -> MouseAction? in
            guard case .mouse(let m)? = bindings[i], [.left, .right, .middle].contains(m) else { return nil }
            return m
        })
    }

    /// The values the pad's slot gets: its `pad:` actions, at rest with none.
    public var pad: PadValues {
        var p = PadInput()
        for i in active {
            guard case .pad(let c)? = bindings[i], !Self.analogue(i, c) else { continue }
            p.press(c)
        }
        var out = PadMapping.values(p)
        for (input, action) in bindings.table {
            guard case .pad(let to) = action else { continue }
            switch (input, to) {
            case (.control(.lt), .lt), (.control(.rt), .lt):
                out.leftTrigger = max(out.leftTrigger, input == .control(.lt) ? values.leftTrigger : values.rightTrigger)
            case (.control(.lt), .rt), (.control(.rt), .rt):
                out.rightTrigger = max(out.rightTrigger, input == .control(.lt) ? values.leftTrigger : values.rightTrigger)
            case (.control(let from), _) where from.isStick && to.isStick:
                let (x, y) = from == .leftStick ? (values.lx, values.ly) : (values.rx, values.ry)
                if to == .leftStick { out.lx = x; out.ly = y } else { out.rx = x; out.ry = y }
            default:
                break
            }
        }
        return out
    }

    /// The mouse speed the sticks bound to `mouse:move` give now (counts a second, +y down); nil for none.
    private var velocity: (dx: Double, dy: Double)? {
        guard !isHeld else { return nil }
        var vx = 0.0, vy = 0.0
        for s in [PadControl.leftStick, .rightStick] where bindings[.control(s)] == .mouse(.move) {
            let (x, y) = s == .leftStick ? (values.lx, values.ly) : (values.rx, values.ry)
            let v = Tuning.velocity(x: Self.unit(x), y: Self.unit(y))
            vx += v.dx; vy += v.dy
        }
        return vx == 0 && vy == 0 ? nil : (vx, vy)
    }

    /// The pad needs clock ticks: a stick moves the mouse, or a wheel input is held.
    public var needsClock: Bool { velocity != nil || !wheelNext.isEmpty }

    /// A clock tick at `time` (seconds): the mouse motion and wheel notches due.
    public mutating func tick(time: Double) -> [MixerOutput] {
        var out: [MixerOutput] = []
        if let v = velocity {
            if let last = lastTick, let m = motion.add(dx: v.dx * min(Tuning.maxTickGap, max(0, time - last)),
                                                       dy: v.dy * min(Tuning.maxTickGap, max(0, time - last))) {
                out.append(.move(dx: m.0, dy: m.1))
            }
            lastTick = time
        } else {
            lastTick = nil
        }
        for input in ControllerInput.all {
            guard let next = wheelNext[input] else { continue }
            guard let due = next else { wheelNext[input] = time + Tuning.wheelDelay; continue }
            guard time >= due else { continue }
            let up = bindings[input] == .mouse(.wheelUp)
            out.append(.pointer(flags: Pointer.wheel, data: up ? 120 : UInt32(bitPattern: -120)))
            wheelNext[input] = max(due + Tuning.wheelInterval, time)
        }
        return out
    }

    /// The bound inputs `v` presses, by the hysteresis against what is pressed now.
    private func pressed(_ v: PadValues) -> Set<ControllerInput> {
        var out: Set<ControllerInput> = []
        for input in bindings.table.keys {
            let level: Double
            switch input {
            case .control(.lt): level = Double(v.leftTrigger) / 255
            case .control(.rt): level = Double(v.rightTrigger) / 255
            case .control(let c) where c.isStick: continue
            case .control(let c):
                var p = PadInput()
                p.press(c)
                level = v.buttons & PadMapping.values(p).buttons != 0 ? 1 : 0
            case .stickDirection(let s, let d):
                let (x, y) = s == .leftStick ? (Self.unit(v.lx), Self.unit(v.ly)) : (Self.unit(v.rx), Self.unit(v.ry))
                level = switch d {
                case .up: y
                case .down: -y
                case .right: x
                case .left: -x
                }
            }
            if level >= Tuning.pressAt || (active.contains(input) && level >= Tuning.releaseAt) { out.insert(input) }
        }
        return out
    }

    /// A trigger bound to a trigger: its value passes as it is, not as a press.
    static func analogue(_ input: ControllerInput, _ to: PadControl) -> Bool {
        (input == .control(.lt) || input == .control(.rt)) && (to == .lt || to == .rt)
    }

    /// An XInput axis as -1...1.
    static func unit(_ a: Int16) -> Double { max(-1, Double(a) / 32767) }
}
