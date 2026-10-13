// SPDX-License-Identifier: GPL-3.0-or-later
/// A point in the on-screen controls' view, in points, +y down.
public struct TouchPoint: Equatable, Sendable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct TouchRect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var center: TouchPoint { TouchPoint(x: x + width / 2, y: y + height / 2) }

    public func contains(_ p: TouchPoint) -> Bool {
        p.x >= x && p.x < x + width && p.y >= y && p.y < y + height
    }
}

public enum TouchBehaviour: String, Codable, CaseIterable, Sendable {
    case hold, toggle, `repeat`
}

/// One control as the touch state sees it: an id, where it is, and what it does.
public struct TouchTarget: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case button(InputAction, TouchBehaviour)
        /// A stick for `stick` (`.leftStick` or `.rightStick`). A floating
        /// stick starts anywhere in `zone`, which its frame need not be in.
        case stick(PadControl, zone: TouchRect?)
        /// Up, down, left, right.
        case dpad([InputAction])
    }

    public var id: String
    public var kind: Kind
    public var frame: TouchRect

    public init(id: String, kind: Kind, frame: TouchRect) {
        self.id = id; self.kind = kind; self.frame = frame
    }

    /// Where a touch starting at p takes this control.
    func takes(_ p: TouchPoint) -> Bool {
        if case .stick(_, let zone?) = kind { return zone.contains(p) }
        return frame.contains(p)
    }

    var floats: Bool {
        if case .stick(_, .some) = kind { return true }
        return false
    }
}

/// What the on-screen controls hold now, for InputMixer.
public struct TouchOutput: Equatable, Sendable {
    /// The pad the controls make (merged into slot 0).
    public var pad = PadInput()
    public var keys: Set<InputAction> = []
    public var mouse: Set<MouseAction> = []
    public var playport: Set<PlayportAction> = []
    public init() {}

    mutating func apply(_ a: InputAction) {
        switch a {
        case .pad(let c): pad.press(c)
        case .key: keys.insert(a)
        case .mouse(let m): mouse.insert(m)
        case .playport(let p): playport.insert(p)
        }
    }
}

extension PadInput {
    /// Presses a pad control fully; a stick's deflection is set apart.
    mutating func press(_ c: PadControl) {
        switch c {
        case .a: a = true
        case .b: b = true
        case .x: x = true
        case .y: y = true
        case .lb: leftShoulder = true
        case .rb: rightShoulder = true
        case .lt: leftTrigger = 1
        case .rt: rightTrigger = 1
        case .start: menu = true
        case .back: options = true
        case .ls: leftThumb = true
        case .rs: rightThumb = true
        case .up: up = true
        case .down: down = true
        case .left: left = true
        case .right: right = true
        case .leftStick, .rightStick: break
        }
    }
}

/// The on-screen controls' touch state: which fingers are on which control,
/// and what that holds (docs/plans/2026-10-09-touch-controls.md, phase 1;
/// S1Probe's UI/TouchControlsView.swift feeds it UIKit's touches). Geometry is
/// in the view's points, +y down; a control's frame comes from its layout
/// (PlayportKit ControlLayout).
///
/// - A button does its action while it is held (`hold`), flips it on each
///   press (`toggle`), or presses it again and again while held (`repeat`,
///   on for the first half of each `repeatInterval`). Two fingers on one
///   button hold it until the last lifts.
/// - A stick starts where the thumb lands: the deflection is the finger's
///   distance from there over the stick's radius, clamped to the unit circle
///   (+y up, as XInput has it). A floating stick starts anywhere in its zone
///   (the Gamepad layout's lower left third); controls inside the zone are hit
///   first. A second touch within `doubleTapWindow` of a short tap on the same
///   stick holds its thumb button (L3, R3) as long as it is down.
/// - A d-pad holds the one or two directions the finger is toward from its
///   centre (8 ways), none inside `dpadDeadZone` of its half size.
/// - `releaseAll` lets go of everything, toggles too: the in-game menu, the
///   app leaving the front, a layout change, the controls hiding.
public struct TouchControls: Sendable {
    public var doubleTapWindow = 0.3
    public var repeatInterval = 0.1
    public var dpadDeadZone = 0.25

    public private(set) var targets: [TouchTarget]

    private struct Finger: Sendable {
        var target: Int
        var origin: TouchPoint
        var at: TouchPoint
        var began: Double
        var thumb = false
    }

    private var fingers: [Int: Finger] = [:]
    private var order: [Int] = []          // fingers in the order they went down
    private var toggled: Set<String> = []
    /// The last short tap on each stick: when it ended.
    private var lastTap: [String: Double] = [:]
    private var now = 0.0

    public init(targets: [TouchTarget] = []) { self.targets = targets }

    /// A new layout, or the same one at a new size: everything held is let go.
    public mutating func setTargets(_ t: [TouchTarget]) {
        releaseAll()
        targets = t
    }

    /// The control a touch at p would take: fixed controls first, then floating sticks' zones.
    public func target(at p: TouchPoint) -> Int? {
        targets.indices.first { !targets[$0].floats && targets[$0].takes(p) }
            ?? targets.indices.first { targets[$0].floats && targets[$0].takes(p) }
    }

    /// A finger went down; false when it is on no control (it is the game's).
    @discardableResult
    public mutating func began(_ touch: Int, at p: TouchPoint, time t: Double) -> Bool {
        now = max(now, t)
        guard fingers[touch] == nil, let i = target(at: p) else { return false }
        var f = Finger(target: i, origin: p, at: p, began: t)
        let id = targets[i].id
        switch targets[i].kind {
        case .button(_, .toggle):
            if toggled.contains(id) { toggled.remove(id) } else { toggled.insert(id) }
        case .stick:
            if let last = lastTap[id], t - last <= doubleTapWindow { f.thumb = true }
            lastTap[id] = nil
        default:
            break
        }
        fingers[touch] = f
        order.append(touch)
        return true
    }

    public mutating func moved(_ touch: Int, at p: TouchPoint, time t: Double) {
        now = max(now, t)
        fingers[touch]?.at = p
    }

    public mutating func ended(_ touch: Int, time t: Double) {
        now = max(now, t)
        guard let f = fingers.removeValue(forKey: touch) else { return }
        order.removeAll { $0 == touch }
        let target = targets[f.target]
        if case .stick = target.kind, !f.thumb, t - f.began <= doubleTapWindow,
           Self.distance(f.origin, f.at) < target.frame.width / 4 {
            lastTap[target.id] = t
        }
    }

    /// Between touches: a repeating button's clock.
    public mutating func tick(time t: Double) { now = max(now, t) }

    public mutating func releaseAll() {
        fingers = [:]
        order = []
        toggled = []
        lastTap = [:]
    }

    /// Whether the caller should call `tick`: a repeating button is held.
    public var needsClock: Bool {
        fingers.values.contains { if case .button(_, .repeat) = targets[$0.target].kind { return true }; return false }
    }

    /// Whether any finger is on a control.
    public var touching: Bool { !fingers.isEmpty }

    /// The controls to draw as held (amber): a finger on them, or toggled on.
    public var held: Set<String> {
        Set(fingers.values.map { targets[$0.target].id }).union(toggled)
    }

    /// A stick's thumb: where it started and its deflection (x right, y up, within the unit circle).
    public func stick(_ id: String) -> (origin: TouchPoint, x: Double, y: Double)? {
        guard let f = strongest(id) else { return nil }
        let d = deflection(f)
        return (f.origin, d.x, d.y)
    }

    public var output: TouchOutput {
        var out = TouchOutput()
        for id in toggled {
            if let t = targets.first(where: { $0.id == id }), case .button(let a, _) = t.kind { out.apply(a) }
        }
        var sticks: [PadControl: (x: Double, y: Double)] = [:]
        for touch in order {
            guard let f = fingers[touch] else { continue }
            switch targets[f.target].kind {
            case .button(let a, .hold):
                out.apply(a)
            case .button(let a, .repeat):
                let phase = (now - f.began).truncatingRemainder(dividingBy: repeatInterval)
                if phase < repeatInterval / 2 { out.apply(a) }
            case .button(_, .toggle):
                break
            case .stick(let s, _):
                let d = deflection(f)
                if let held = sticks[s], held.x * held.x + held.y * held.y >= d.x * d.x + d.y * d.y {} else { sticks[s] = d }
                if f.thumb, let thumb = s.thumb { out.pad.press(thumb) }
            case .dpad(let four):
                for a in dpadActions(f, four) { out.apply(a) }
            }
        }
        if let l = sticks[.leftStick] { out.pad.lx = Float(l.x); out.pad.ly = Float(l.y) }
        if let r = sticks[.rightStick] { out.pad.rx = Float(r.x); out.pad.ry = Float(r.y) }
        return out
    }

    private func strongest(_ id: String) -> Finger? {
        fingers.values.filter { targets[$0.target].id == id }.max { a, b in
            let da = deflection(a), db = deflection(b)
            return da.x * da.x + da.y * da.y < db.x * db.x + db.y * db.y
        }
    }

    private func deflection(_ f: Finger) -> (x: Double, y: Double) {
        let r = max(1, targets[f.target].frame.width / 2)
        var x = (f.at.x - f.origin.x) / r, y = (f.origin.y - f.at.y) / r
        guard x.isFinite, y.isFinite else { return (0, 0) }
        let len = (x * x + y * y).squareRoot()
        if len > 1 { x /= len; y /= len }
        return (x, y)
    }

    private func dpadActions(_ f: Finger, _ four: [InputAction]) -> [InputAction] {
        guard four.count == 4 else { return [] }
        let frame = targets[f.target].frame, c = frame.center
        let half = max(1, min(frame.width, frame.height) / 2)
        let vx = (f.at.x - c.x) / half, vy = (f.at.y - c.y) / half
        let len = (vx * vx + vy * vy).squareRoot()
        guard len >= dpadDeadZone else { return [] }
        // Each direction holds within 67.5° of its axis: 8 ways, the diagonals both.
        let k = 0.3827 * len   // sin 22.5°
        var out: [InputAction] = []
        if vy < -k { out.append(four[0]) }
        if vy > k { out.append(four[1]) }
        if vx < -k { out.append(four[2]) }
        if vx > k { out.append(four[3]) }
        return out
    }

    private static func distance(_ a: TouchPoint, _ b: TouchPoint) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}
