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
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(_ p: TouchPoint) -> Bool {
        p.x >= x && p.x < x + width && p.y >= y && p.y < y + height
    }
}

public enum TouchBehaviour: String, Codable, CaseIterable, Sendable {
    case hold, toggle, `repeat`
}

/// A Point & click side-bar tool: what the pointer surface does while it is on.
/// Right click, hover and scroll take turns (one on at a time, tapped again for
/// off); the trackpad tool switches tap to click and trackpad apart from them.
public enum PointerTool: String, Codable, CaseIterable, Sendable {
    /// The next press on the surface is the right button; then it is off.
    case rightClick
    /// The finger moves the pointer and presses nothing.
    case hover
    /// A drag turns the wheel.
    case scroll
    /// Tap to click (off) or trackpad (on).
    case trackpad
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
        /// A stick that presses four actions (up, down, left, right; W S A D in
        /// the Keyboard & mouse layout) as it leans, a diagonal two. It floats in
        /// `zone` as a stick does; it has no thumb button.
        case keyStick([InputAction], zone: TouchRect?)
        /// A look area: a finger dragged on it moves the mouse (`lookScale`
        /// counts a point). It takes what no other control does.
        case look
        /// A pointer surface (Point & click): with tap to click the pointer goes
        /// where the finger is and the left button is down while it is; as a
        /// trackpad a drag moves the pointer and a short tap clicks. The tools
        /// change both. `view` is the rectangle the game's picture fills (the
        /// whole view from a layout; `setPicture` gives the aspect-fitted picture):
        /// a point's place in it is its place in the client area.
        /// It takes what no other control does.
        case pointer(view: TouchRect)
        /// A side-bar tool: a press turns it on or off.
        case tool(PointerTool)
        /// A touch keyboard's key (TouchKeyboard): its VK is held while a finger is on it.
        case key(UInt8)
        /// A touch keyboard's Shift, Ctrl or Alt (its VK): sticky, as TouchControls has it.
        case modifier(UInt8)
    }

    public var id: String
    public var kind: Kind
    public var frame: TouchRect

    public init(id: String, kind: Kind, frame: TouchRect) {
        self.id = id; self.kind = kind; self.frame = frame
    }

    /// Where a touch starting at p takes this control.
    func takes(_ p: TouchPoint) -> Bool {
        if let zone { return zone.contains(p) }
        return frame.contains(p)
    }

    /// A floating stick's zone.
    var zone: TouchRect? {
        switch kind {
        case .stick(_, let z), .keyStick(_, let z): z
        default: nil
        }
    }

    var floats: Bool { zone != nil }

    /// The order touches find controls in: fixed controls (0), then floating
    /// sticks' zones (1), then the surfaces under everything (2).
    var layer: Int {
        switch kind {
        case .look, .pointer: 2
        default: floats ? 1 : 0
        }
    }
}

/// What a surface sends once rather than holds: InputMixer passes it on in order.
public enum TouchPointerEvent: Equatable, Sendable {
    /// Relative motion in mouse counts, +y down (the look area, the trackpad).
    case move(dx: Int32, dy: Int32)
    /// The pointer to this place in the client area, 0...65535 each way (tap to click, hover).
    case place(x: Int32, y: Int32)
    /// A button pressed and let go where the pointer is (a trackpad tap).
    case click(MouseAction)
    /// Wheel notches, + toward the top (a finger dragging the content down).
    case wheel(Int)
}

/// What the on-screen controls hold now, for InputMixer.
public struct TouchOutput: Equatable, Sendable {
    /// The pad the controls make (merged into slot 0).
    public var pad = PadInput()
    public var keys: Set<InputAction> = []
    public var mouse: Set<MouseAction> = []
    public var playport: Set<PlayportAction> = []
    /// What happened since the last `takeOutput`, in order (empty in `output`).
    public var events: [TouchPointerEvent] = []
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

/// Where a finger that lands on the game goes (touch controls 2e, owner
/// 2026-10-13): while the on-screen controls show, only to them (a control, or
/// a floating stick's zone); one outside them is ignored, as a stray touch
/// would flick the view of a mouse-look game. With no controls shown (the
/// layout Off, a controller connected), it is the game's left mouse button.
public enum TouchRoute: Equatable, Sendable {
    case controls
    case ignored
    case game

    public static func decide(controlsShown: Bool, onControl: Bool) -> TouchRoute {
        guard controlsShown else { return .game }
        return onControl ? .controls : .ignored
    }
}

/// The on-screen controls' touch state: which fingers are on which control,
/// and what that holds (PLA-13, phase 1;
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
///   (the Gamepad layout's lower corners, one for each stick); a control that
///   overlaps a zone is hit first. A second touch within `doubleTapWindow` of a short tap on the same
///   stick holds its thumb button (L3, R3) as long as it is down.
/// - A d-pad holds the one or two directions the finger is toward from its
///   centre (8 ways), none inside `dpadDeadZone` of its half size.
/// - `cancelled` takes a finger back as if it had never come down: a toggle it
///   flipped flips back, and it counts as no tap (the three-finger tap that
///   opens the in-game menu takes its fingers back from the controls).
/// - `releaseAll` lets go of everything, toggles too: the in-game menu, the
///   app leaving the front, a layout change, the controls hiding.
///
/// Phase 4 (the Keyboard & mouse and Point & click layouts):
///
/// - A key stick (W A S D) floats like a stick; each axis apart presses its
///   direction from `keyStickPressAt` of the radius until it falls under
///   `keyStickReleaseAt` (hysteresis), a diagonal two.
/// - A look area is under every other control: a finger dragged on it moves
///   the mouse `lookScale` counts a point; several fingers each move it.
/// - A pointer surface is under every other control, and only the first finger
///   on it points (another does nothing). With tap to click (`trackpad` off)
///   the pointer goes where the finger lands (`place`) and follows it, with the
///   left button down until it lifts, and `magnifier` is the point under it.
///   As a trackpad a drag moves the pointer `trackpadScale` counts a point and
///   a tap (up within `tapTime`, never `tapSlop` from where it landed) clicks.
/// - The tools (PointerTool): with right click on, the next press (or trackpad
///   tap) is the right button, then the tool is off; hover places the pointer
///   (or moves it) and presses nothing; scroll places it where the finger lands
///   and turns the wheel a notch each `scrollStep` points dragged, the content
///   following the finger. The trackpad tool flips `trackpad`.
/// - A cancelled finger on the surface clicks nothing (right click stays on);
///   a cancelled tool press flips the tool back. `releaseAll` lets go of the
///   button and turns the tools off; `trackpad` is kept, a preference.
/// - Motion, places, trackpad clicks and wheel notches are events, handed
///   over once by `takeOutput` (InputMixer sends them before the holds' edges);
///   `output` has the holds alone.
///
/// The touch keyboard (TouchKeyboard; phase 4 item 2):
///
/// - A key holds its VK while a finger is on it.
/// - Shift, Ctrl and Alt are sticky (`sticky`): a tap holds one down until the
///   next key goes up (latched); a second tap within `doubleTapWindow` keeps it
///   down until it is tapped again (locked); a later tap on a latched one lets
///   go. Held under a finger while another key is pressed, it is a chord and
///   goes up with the finger. A cancelled tap leaves it as it was;
///   `releaseAll` lets go of them all.
public struct TouchControls: Sendable {
    /// A sticky modifier that stays down with no finger on it.
    public enum Sticky: Equatable, Sendable {
        /// Until the next key goes up.
        case latched
        /// Until it is tapped again.
        case locked
    }

    public var doubleTapWindow = 0.3
    public var repeatInterval = 0.1
    public var dpadDeadZone = 0.25
    /// A look area's mouse counts for each point a finger moves.
    public var lookScale = 3.0
    /// A key stick holds a direction from this lean (of its radius)...
    public var keyStickPressAt = 0.5
    /// ...until it falls under this one, so a lean at the threshold does not flicker.
    public var keyStickReleaseAt = 0.4
    /// A trackpad's mouse counts for each point a finger moves.
    public var trackpadScale = 2.0
    /// The points a scroll drag goes for one wheel notch.
    public var scrollStep = 20.0
    /// A trackpad tap: up within this many seconds...
    public var tapTime = 0.25
    /// ...never this many points from where it landed.
    public var tapSlop = 10.0
    /// The pointer surface is a trackpad (else tap to click).
    public var trackpad = false
    /// The tool on now: right click, hover or scroll (the trackpad is `trackpad`).
    public private(set) var tool: PointerTool?
    /// The touch keyboard's modifiers down with no finger on them, by target id.
    public private(set) var sticky: [String: Sticky] = [:]

    public private(set) var targets: [TouchTarget]

    private struct Finger: Sendable {
        var target: Int
        var origin: TouchPoint
        var at: TouchPoint
        var began: Double
        var thumb = false
        /// A key stick's directions held now (0 up, 1 down, 2 left, 3 right).
        var keys: Set<Int> = []
        /// The pointer surface's finger that points (the first on it).
        var points = false
        /// The button a tap-to-click finger holds.
        var button: MouseAction?
        /// The farthest it has gone from where it landed.
        var travel = 0.0
        /// A scroll drag's points not yet a notch.
        var scrolled = 0.0
        /// The tool and mode a press on a tool found, for `cancelled`.
        var before: (tool: PointerTool?, trackpad: Bool)?
        /// A modifier's state when the finger came down, for `cancelled`.
        var stickyBefore: Sticky?
        /// Another key was pressed while this modifier's finger was down (a chord).
        var chord = false
    }

    private var fingers: [Int: Finger] = [:]
    private var order: [Int] = []          // fingers in the order they went down
    private var toggled: Set<String> = []
    /// The last short tap on each stick: when it ended.
    private var lastTap: [String: Double] = [:]
    /// When each latched modifier was tapped (a second tap within doubleTapWindow locks it).
    private var latchedAt: [String: Double] = [:]
    private var now = 0.0
    /// The events `takeOutput` hands over next.
    private var events: [TouchPointerEvent] = []
    /// The relative motion's parts under a count, carried to the next move.
    private var motion = RelativeMotion()

    public init(targets: [TouchTarget] = []) { self.targets = targets }

    /// A new layout, or the same one at a new size: everything held is let go.
    public mutating func setTargets(_ t: [TouchTarget]) {
        releaseAll()
        targets = t
    }

    /// Where the game's picture is in the view (the swap chain aspect-fitted, as
    /// GameSurfaceView routes a game touch): the pointer surface places the
    /// pointer through it. Nothing is let go; a finger down maps to it from its next move.
    public mutating func setPicture(_ picture: TouchRect) {
        for i in targets.indices {
            if case .pointer = targets[i].kind { targets[i].kind = .pointer(view: picture) }
        }
    }

    /// The control a touch at p would take: fixed controls first, then floating
    /// sticks' zones, then the surfaces under everything (a look area).
    public func target(at p: TouchPoint) -> Int? {
        for layer in 0...2 {
            if let i = targets.indices.first(where: { targets[$0].layer == layer && targets[$0].takes(p) }) { return i }
        }
        return nil
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
        case .pointer(let view):
            guard !fingers.values.contains(where: \.points) else { break }
            f.points = true
            if !trackpad {
                place(p, in: view)
                f.button = switch tool {
                case nil: .left
                case .rightClick: .right
                default: nil
                }
            }
        case .tool(let x):
            f.before = (tool, trackpad)
            if x == .trackpad { trackpad.toggle() } else { tool = tool == x ? nil : x }
        case .modifier:
            f.stickyBefore = sticky[id]
            switch sticky[id] {
            case nil:
                sticky[id] = .latched
                latchedAt[id] = t
            case .latched?:
                sticky[id] = t - (latchedAt[id] ?? -.infinity) <= doubleTapWindow ? .locked : nil
            case .locked?:
                sticky[id] = nil
            }
        case .key:
            // A modifier under a finger now makes a chord with this key.
            for (n, g) in fingers { if case .modifier = targets[g.target].kind { fingers[n]?.chord = true } }
        default:
            break
        }
        fingers[touch] = f
        order.append(touch)
        return true
    }

    public mutating func moved(_ touch: Int, at p: TouchPoint, time t: Double) {
        now = max(now, t)
        guard var f = fingers[touch] else { return }
        let from = f.at
        f.at = p
        switch targets[f.target].kind {
        case .look:
            move(dx: (p.x - from.x) * lookScale, dy: (p.y - from.y) * lookScale)
        case .keyStick:
            // Each axis apart, +y up: up, down, left, right.
            let d = deflection(f)
            for (i, lean) in [d.y, -d.y, -d.x, d.x].enumerated() {
                if lean >= keyStickPressAt || (f.keys.contains(i) && lean >= keyStickReleaseAt) { f.keys.insert(i) } else { f.keys.remove(i) }
            }
        case .pointer(let view) where f.points:
            f.travel = max(f.travel, Self.distance(f.origin, p))
            if tool == .scroll {
                f.scrolled += p.y - from.y
                let notches = (f.scrolled / scrollStep).rounded(.towardZero)
                if notches != 0 {
                    f.scrolled -= notches * scrollStep
                    events.append(.wheel(Int(notches)))
                }
            } else if trackpad {
                move(dx: (p.x - from.x) * trackpadScale, dy: (p.y - from.y) * trackpadScale)
            } else {
                place(p, in: view)
            }
        default:
            break
        }
        fingers[touch] = f
    }

    /// Relative motion in counts (fractions carried): a move event when a whole count is due.
    private mutating func move(dx: Double, dy: Double) {
        if let d = motion.add(dx: dx, dy: dy) { events.append(.move(dx: d.0, dy: d.1)) }
    }

    /// The pointer to p's place in the client area (the picture fills `view`).
    private mutating func place(_ p: TouchPoint, in view: TouchRect) {
        let x = min(max(p.x - view.x, 0), view.width - 0.001), y = min(max(p.y - view.y, 0), view.height - 0.001)
        guard let f = Pointer.clientFraction(x: x, y: y, width: view.width, height: view.height) else { return }
        events.append(.place(x: f.0, y: f.1))
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
        if case .pointer = target.kind, f.points {
            if f.button == .right { tool = nil }
            if trackpad, tool != .hover, tool != .scroll, t - f.began <= tapTime, f.travel < tapSlop {
                events.append(.click(tool == .rightClick ? .right : .left))
                if tool == .rightClick { tool = nil }
            }
        }
        switch target.kind {
        case .modifier where f.chord:
            sticky[target.id] = nil
        case .key:
            // The key a latched modifier was down for: it goes up, unless a finger still holds it.
            for (id, s) in sticky where s == .latched && !fingers.values.contains(where: { targets[$0.target].id == id }) {
                sticky[id] = nil
            }
        default:
            break
        }
    }

    /// The system took the finger back (a gesture it was part of): what it
    /// held is let go, a toggle it flipped flips back, and no tap is counted.
    public mutating func cancelled(_ touch: Int, time t: Double) {
        now = max(now, t)
        guard let f = fingers.removeValue(forKey: touch) else { return }
        order.removeAll { $0 == touch }
        let target = targets[f.target]
        if case .button(_, .toggle) = target.kind {
            if toggled.contains(target.id) { toggled.remove(target.id) } else { toggled.insert(target.id) }
        }
        if case .tool = target.kind, let b = f.before { tool = b.tool; trackpad = b.trackpad }
        if case .modifier = target.kind { sticky[target.id] = f.stickyBefore }
    }

    /// Between touches: a repeating button's clock.
    public mutating func tick(time t: Double) { now = max(now, t) }

    public mutating func releaseAll() {
        fingers = [:]
        order = []
        toggled = []
        lastTap = [:]
        events = []
        motion.reset()
        tool = nil
        sticky = [:]
        latchedAt = [:]
    }

    /// The output with the events since the last call (`output` has none).
    public mutating func takeOutput() -> TouchOutput {
        var out = output
        out.events = events
        events = []
        return out
    }

    /// Whether the caller should call `tick`: a repeating button is held.
    public var needsClock: Bool {
        fingers.values.contains { if case .button(_, .repeat) = targets[$0.target].kind { return true }; return false }
    }

    /// Whether any finger is on a control.
    public var touching: Bool { !fingers.isEmpty }

    /// The controls to draw as held (amber): a finger on them, toggled on, a tool on, or a sticky modifier down.
    public var held: Set<String> {
        var out = Set(fingers.values.map { targets[$0.target].id }).union(toggled).union(sticky.keys)
        for t in targets {
            if case .tool(let x) = t.kind, x == .trackpad ? trackpad : x == tool { out.insert(t.id) }
        }
        return out
    }

    /// Where a magnifier shows what is under the pointing finger: with tap to
    /// click, while it is down (not scrolling); nil otherwise.
    public var magnifier: TouchPoint? {
        guard !trackpad, tool != .scroll, let f = fingers.values.first(where: \.points) else { return nil }
        return f.at
    }

    /// A stick's thumb: where it started and its deflection (x right, y up, within the unit circle).
    public func stick(_ id: String) -> (origin: TouchPoint, x: Double, y: Double)? {
        guard let f = strongest(id) else { return nil }
        let d = deflection(f)
        return (f.origin, d.x, d.y)
    }

    /// Where the fingers on a control are now, in the order they went down (the look area's rings).
    public func points(on id: String) -> [TouchPoint] {
        order.compactMap { fingers[$0] }.filter { targets[$0.target].id == id }.map(\.at)
    }

    public var output: TouchOutput {
        var out = TouchOutput()
        for id in toggled {
            if let t = targets.first(where: { $0.id == id }), case .button(let a, _) = t.kind { out.apply(a) }
        }
        for t in targets where sticky[t.id] != nil {
            if case .modifier(let vk) = t.kind { out.apply(.key(vk, [])) }
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
            case .keyStick(let four, _):
                for i in f.keys.sorted() where i < four.count { out.apply(four[i]) }
            case .pointer:
                if let b = f.button { out.apply(.mouse(b)) }
            case .look, .tool:
                break
            case .key(let vk), .modifier(let vk):
                out.apply(.key(vk, []))
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
