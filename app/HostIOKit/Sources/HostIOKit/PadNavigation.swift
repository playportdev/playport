// SPDX-License-Identifier: GPL-3.0-or-later
/// A controller as Playport's own screens read it, not the guest: the buttons
/// the footer names, and four directions from the D-pad or the left stick.
/// `view` is the button left of ≡ (Xbox View, DualSense Create: GameController's buttonOptions).
public enum NavButton: String, CaseIterable, Sendable {
    case a, b, x, y, lb, rb, menu, view, up, down, left, right

    public var isDirection: Bool { self == .up || self == .down || self == .left || self == .right }
}

/// Turns pad snapshots into presses for the app's screens (UI/Pad/PadRouter.swift).
///
/// A button counts once, as it goes down. A direction (the D-pad, or the left
/// stick past `stickOn` on its larger axis, let go below `stickOff`) counts as
/// it goes down and then again every `repeatInterval` seconds once it has been
/// held `repeatDelay` seconds. Only the direction pressed last repeats.
public struct PadNavigation: Sendable {
    public var repeatDelay = 0.4, repeatInterval = 0.12
    public var stickOn: Float = 0.5, stickOff: Float = 0.3

    private var held: Set<NavButton> = []
    private var stick: NavButton?
    private var repeating: (button: NavButton, next: Double)?

    public init() {}

    /// The presses a new snapshot at time `t` (seconds) makes.
    public mutating func update(_ p: PadInput, at t: Double) -> [NavButton] {
        stick = Self.stickDirection(p, current: stick, on: stickOn, off: stickOff)
        var now: Set<NavButton> = []
        let buttons: [(Bool, NavButton)] = [
            (p.a, .a), (p.b, .b), (p.x, .x), (p.y, .y), (p.leftShoulder, .lb), (p.rightShoulder, .rb), (p.menu, .menu),
            (p.options, .view),
            (p.up, .up), (p.down, .down), (p.left, .left), (p.right, .right),
        ]
        for (on, b) in buttons where on { now.insert(b) }
        if let stick { now.insert(stick) }
        let pressed = NavButton.allCases.filter { now.contains($0) && !held.contains($0) }
        held = now
        if let d = pressed.last(where: \.isDirection) {
            repeating = (d, t + repeatDelay)
        } else if let r = repeating, !held.contains(r.button) {
            repeating = nil
        }
        return pressed
    }

    /// The repeats due by time `t`: at most one, so a stalled clock does not burst.
    public mutating func tick(at t: Double) -> [NavButton] {
        guard let r = repeating, held.contains(r.button), t >= r.next else { return [] }
        repeating = (r.button, max(r.next, t) + repeatInterval)
        return [r.button]
    }

    /// Whether a direction is held, so the caller keeps its clock running.
    public var isRepeating: Bool { repeating != nil }

    /// Everything let go: the pad was handed on or disconnected.
    public mutating func reset() {
        held = []
        stick = nil
        repeating = nil
    }

    static func stickDirection(_ p: PadInput, current: NavButton?, on: Float, off: Float) -> NavButton? {
        let x = p.lx.isFinite ? p.lx : 0, y = p.ly.isFinite ? p.ly : 0
        if let current {
            let along: Float = switch current {
            case .up: y
            case .down: -y
            case .left: -x
            case .right: x
            default: 0
            }
            if along >= off { return current }
        }
        guard max(abs(x), abs(y)) >= on else { return nil }
        if abs(x) > abs(y) { return x > 0 ? .right : .left }
        return y > 0 ? .up : .down   // +y is up, as GameController reports it
    }
}
