// SPDX-License-Identifier: GPL-3.0-or-later
// The virtual gamepad (a game's option, LaunchSettings.virtualPad): on a
// foldable's inner panel held upright (iPhone Duo), the game in the top half
// and an on-screen controller in the bottom one, laid out by one of the
// player's layouts (PlayportKit PadLayout; Settings › Virtual gamepad and the
// in-game menu change them, PadLayoutEditor.swift). It is an XInput pad like a
// GameController one: a slot of its own from the start of the launch (Unity
// lists controllers only when its input starts), its values through HostIO's
// gate, and Home held opens Playport's in-game menu (HostIO.menuInput). Folded
// or turned sideways the game has the whole panel and the pad rests.

#if canImport(UIKit)
import HostIO
import HostIOKit
import PlayportKit
import SwiftUI
import UIKit

/// The layouts, kept in UserDefaults.
@MainActor
final class PadLayoutStore: ObservableObject {
    static let shared = PadLayoutStore()
    private static let key = "virtualPad.layouts"

    @Published var all: PadLayouts {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: Self.key) }
    }

    private init() {
        all = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(PadLayouts.self, from: $0) }
            ?? PadLayouts()
    }
}

@MainActor
final class VirtualGamepad: ObservableObject {
    static let shared = VirtualGamepad()

    /// The launching game has the option on, on a foldable.
    @Published private(set) var enabled = false
    /// The game's layout; nil, or one deleted since, is the default.
    @Published private(set) var layoutID: String?
    private var titleID: String?
    private var slot: Int?
    private var last = PadInput()

    /// Before the launch: whether this game gets the pad, and in which layout.
    func prepare(_ on: Bool, layout: String? = nil, titleID: String? = nil) {
        enabled = on
        layoutID = layout
        self.titleID = titleID
    }

    var layout: PadLayout { PadLayoutStore.shared.all.layout(layoutID) }

    /// The game's layout from now on, and at its next launch.
    func choose(_ id: String) {
        layoutID = id
        if let titleID { LaunchSettingsStore.shared.binding(for: titleID).wrappedValue.virtualPadLayout = id }
        HostIO.log("virtual gamepad: layout \"\(layout.name)\"")
    }

    /// The in-game menu's row: the next layout.
    func cycle() { choose(PadLayoutStore.shared.all.next(after: layoutID).id) }

    /// As the game's host I/O starts: the pad's slot, at rest.
    func connect() {
        guard enabled, slot == nil else { return }
        guard let s = HostIO.shared.connectSlot(ObjectIdentifier(VirtualGamepad.self)) else {
            HostIO.log("virtual gamepad: no free XInput slot")
            return
        }
        slot = s
        HostIO.publish(PadValues(), slot: s)
        HostIO.log("virtual gamepad: XInput slot \(s), layout \"\(layout.name)\"")
    }

    /// The pad's controls now.
    func send(_ p: PadInput) {
        guard let slot, p != last else { return }
        last = p
        HostIO.shared.menuInput(p)
        HostIO.publish(PadMapping.values(p), slot: slot)
    }
}

/// The game above the pad when the option is on and the panel is upright
/// (only a foldable's inner panel turns to portrait during a game, AppDelegate);
/// the whole screen the game's otherwise.
struct GameArea: View {
    @ObservedObject private var pad = VirtualGamepad.shared
    @ObservedObject private var layouts = PadLayoutStore.shared

    var body: some View {
        GeometryReader { g in
            let split = pad.enabled && g.size.height > g.size.width
            VStack(spacing: 0) {
                GameSurface().frame(height: split ? (g.size.height * 0.5).rounded() : g.size.height)
                if split {
                    VirtualPadControls(layout: layouts.all.layout(pad.layoutID))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.identity)
                }
            }
            .onChange(of: split) { _, on in if !on { VirtualGamepad.shared.send(PadInput()) } }
        }
        .background(Color.black)
    }
}

/// The pad, playing or (the editor's canvas) being laid out.
struct VirtualPadControls: UIViewRepresentable {
    var layout: PadLayout
    var editing = false
    var selected: PadControl?
    var onEdit: ((PadLayout) -> Void)?
    var onSelect: ((PadControl?) -> Void)?

    func makeUIView(context: Context) -> VirtualPadView { VirtualPadView() }

    func updateUIView(_ view: VirtualPadView, context: Context) {
        view.editing = editing
        if view.layout != layout { view.layout = layout }
        if view.selected != selected { view.selected = selected }
        view.onEdit = onEdit
        view.onSelect = onSelect
    }
}

/// The controller's face, drawn and touched in one view so that several fingers
/// work at once and a finger slides from button to button: a stick follows the
/// finger that went down on it; any other finger presses what it is over.
/// A stick pressed again within 0.3 s of letting go is its click (LS, RS) while held.
/// Editing, a finger drags the control it went down on, which becomes the selected one.
final class VirtualPadView: UIView {
    var layout = PadLayouts().defaultLayout { didSet { setNeedsLayout(); setNeedsDisplay() } }
    var editing = false { didSet { if editing != oldValue { reset(); setNeedsDisplay() } } }
    var selected: PadControl? { didSet { setNeedsDisplay() } }
    var onEdit: ((PadLayout) -> Void)?
    var onSelect: ((PadControl?) -> Void)?

    private struct Stick {
        var center = CGPoint.zero, radius: CGFloat = 0
        var value = CGPoint.zero      // -1...1, +y down as on screen
        var touch: UITouch?
        var clicked = false
        var lastUp: TimeInterval = 0
    }

    /// The face buttons, each one offset from their centre (+y down).
    private enum Face { case a, b, x, y }
    private static let face: [(Face, CGPoint)] = [(.a, CGPoint(x: 0, y: 1)), (.b, CGPoint(x: 1, y: 0)),
                                                  (.x, CGPoint(x: -1, y: 0)), (.y, CGPoint(x: 0, y: -1))]

    private var left = Stick(), right = Stick()
    private var unit: CGFloat = 1
    /// Where each control is drawn and touched.
    private var frames: [PadControl: CGRect] = [:]
    /// What each finger not on a stick presses.
    private var fingers: [UITouch: Set<PadControl>] = [:]
    private var pressed: Set<PadControl> = []
    private var facePressed: Set<Face> = []
    /// The d-pad's directions held now.
    private var dpadDirection: (up: Bool, down: Bool, left: Bool, right: Bool) = (false, false, false, false)
    /// Editing: the finger dragging a control, and its offset from the control's centre.
    private var drag: (touch: UITouch, control: PadControl, offset: CGPoint)?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.07, alpha: 1)
        isMultipleTouchEnabled = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("VirtualPadView is created in code") }

    // MARK: geometry

    /// A control's own size is for a 670x470 pt area: shoulders 96x46, Back, Home
    /// and Start 44 across, a stick's radius 78, the d-pad's arm 64, the face
    /// buttons 56 from their centre and 30 in radius.
    private func scale(_ c: PadControl) -> CGFloat { CGFloat(layout[c].scale) * unit }

    private func center(_ c: PadControl) -> CGPoint {
        CGPoint(x: CGFloat(layout[c].x) * bounds.width, y: CGFloat(layout[c].y) * bounds.height)
    }

    private func frame(_ c: PadControl) -> CGRect {
        let p = center(c), s = scale(c)
        func box(_ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h) }
        switch c {
        case .leftTrigger, .leftBumper, .rightBumper, .rightTrigger: return box(96 * s, 46 * s)
        case .back, .home, .start: return box(44 * s, 44 * s)
        case .leftStick, .rightStick: return box(156 * s, 156 * s)
        case .dpad: return box(128 * s, 128 * s)
        case .face: return box(172 * s, 172 * s)
        }
    }

    private func shows(_ c: PadControl) -> Bool { editing || !layout[c].hidden }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        unit = min(bounds.width / 670, bounds.height / 470)
        frames = Dictionary(uniqueKeysWithValues: PadControl.allCases.map { ($0, frame($0)) })
        left.center = center(.leftStick); left.radius = 78 * scale(.leftStick)
        right.center = center(.rightStick); right.radius = 78 * scale(.rightStick)
        setNeedsDisplay()
    }

    // MARK: touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if editing { return editBegan(touches) }
        for t in touches {
            let p = t.location(in: self)
            if left.touch == nil, shows(.leftStick), hits(left, p) {
                grab(&left, t, p)
            } else if right.touch == nil, shows(.rightStick), hits(right, p) {
                grab(&right, t, p)
            } else {
                fingers[t] = controls(at: p)
            }
        }
        update()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if editing { return editMoved(touches) }
        for t in touches {
            let p = t.location(in: self)
            if t === left.touch { move(&left, p) }
            else if t === right.touch { move(&right, p) }
            else if fingers[t] != nil { fingers[t] = controls(at: p) }
        }
        update()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        if editing {
            if let d = drag, touches.contains(d.touch) { drag = nil }
            return
        }
        for t in touches {
            if t === left.touch { release(&left, t) }
            else if t === right.touch { release(&right, t) }
            else { fingers[t] = nil }
        }
        update()
    }

    /// Nothing held: the editor took over, or gave the pad back.
    private func reset() {
        fingers = [:]
        left.touch = nil; left.value = .zero; left.clicked = false
        right.touch = nil; right.value = .zero; right.clicked = false
        pressed = []
        facePressed = []
        dpadDirection = (false, false, false, false)
        drag = nil
    }

    private func hits(_ s: Stick, _ p: CGPoint) -> Bool { hypot(p.x - s.center.x, p.y - s.center.y) <= s.radius * 1.35 }

    private func grab(_ s: inout Stick, _ t: UITouch, _ p: CGPoint) {
        s.touch = t
        s.clicked = t.timestamp - s.lastUp < 0.3
        move(&s, p)
    }

    private func move(_ s: inout Stick, _ p: CGPoint) {
        var v = CGPoint(x: (p.x - s.center.x) / s.radius, y: (p.y - s.center.y) / s.radius)
        let len = hypot(v.x, v.y)
        if len > 1 { v = CGPoint(x: v.x / len, y: v.y / len) }
        // A small dead zone, the rest rescaled so the edge is still full.
        let dead: CGFloat = 0.12
        let l = min(1, len)
        let scaled = l <= dead ? 0 : (l - dead) / (1 - dead)
        s.value = l == 0 ? .zero : CGPoint(x: v.x / max(l, 0.0001) * scaled, y: v.y / max(l, 0.0001) * scaled)
    }

    private func release(_ s: inout Stick, _ t: UITouch) {
        s.touch = nil
        s.value = .zero
        s.clicked = false
        s.lastUp = t.timestamp
    }

    /// What a finger at p presses: a button under it, the d-pad or the face
    /// buttons (which of theirs comes from where the finger is, update()).
    private func controls(at p: CGPoint) -> Set<PadControl> {
        let buttons: [PadControl] = [.leftTrigger, .leftBumper, .rightBumper, .rightTrigger, .back, .home, .start]
        for c in buttons where shows(c) && frames[c, default: .null].insetBy(dx: -8, dy: -8).contains(p) { return [c] }
        if shows(.dpad) {
            let o = center(.dpad), arm = 64 * scale(.dpad)
            let dx = p.x - o.x, dy = p.y - o.y
            if abs(dx) <= arm * 1.5, abs(dy) <= arm * 1.5, hypot(dx, dy) >= arm * 0.2 { return [.dpad] }
        }
        if shows(.face) {
            let o = center(.face), reach = (56 + 30 * 1.6) * scale(.face)
            if abs(p.x - o.x) <= reach, abs(p.y - o.y) <= reach { return [.face] }
        }
        return []
    }

    /// The face button nearest to p.
    private func nearestFace(_ p: CGPoint) -> Face {
        let o = center(.face), offset = 56 * scale(.face)
        func d(_ f: (Face, CGPoint)) -> CGFloat { hypot(p.x - o.x - f.1.x * offset, p.y - o.y - f.1.y * offset) }
        return Self.face.min { d($0) < d($1) }!.0
    }

    private func update() {
        var now: Set<PadControl> = []
        var faces: Set<Face> = []
        var dir = (up: false, down: false, left: false, right: false)
        for (t, cs) in fingers {
            now.formUnion(cs)
            let p = t.location(in: self)
            if cs.contains(.face) { faces.insert(nearestFace(p)) }
            if cs.contains(.dpad) {
                let o = center(.dpad)
                let angle = atan2(p.y - o.y, p.x - o.x)
                // Eight ways: 0 is left, 2 up, 4 right, 6 down (the screen's +y is down).
                switch Int(((angle + .pi) / (.pi / 4)).rounded()) % 8 {
                case 0: dir.left = true
                case 1: dir.left = true; dir.up = true
                case 2: dir.up = true
                case 3: dir.up = true; dir.right = true
                case 4: dir.right = true
                case 5: dir.right = true; dir.down = true
                case 6: dir.down = true
                default: dir.down = true; dir.left = true
                }
            }
        }
        let newPress = !now.subtracting([.dpad, .face]).subtracting(pressed).isEmpty || !faces.subtracting(facePressed).isEmpty
            || dir.up && !dpadDirection.up || dir.down && !dpadDirection.down
            || dir.left && !dpadDirection.left || dir.right && !dpadDirection.right
        if newPress && layout.haptics { haptic.impactOccurred() }
        pressed = now
        facePressed = faces
        dpadDirection = dir
        var p = PadInput()
        p.a = faces.contains(.a); p.b = faces.contains(.b); p.x = faces.contains(.x); p.y = faces.contains(.y)
        p.leftShoulder = now.contains(.leftBumper); p.rightShoulder = now.contains(.rightBumper)
        p.leftTrigger = now.contains(.leftTrigger) ? 1 : 0; p.rightTrigger = now.contains(.rightTrigger) ? 1 : 0
        p.menu = now.contains(.start); p.options = now.contains(.back); p.home = now.contains(.home)
        p.up = dir.up; p.down = dir.down; p.left = dir.left; p.right = dir.right
        // XInput's +y is up, the screen's down.
        p.lx = Float(left.value.x); p.ly = Float(-left.value.y)
        p.rx = Float(right.value.x); p.ry = Float(-right.value.y)
        p.leftThumb = left.clicked; p.rightThumb = right.clicked
        VirtualGamepad.shared.send(p)
        setNeedsDisplay()
    }

    // MARK: editing

    /// The control under p, the smallest first (Home over a stick's square).
    private func control(at p: CGPoint) -> PadControl? {
        func area(_ c: PadControl) -> CGFloat { frames[c].map { $0.width * $0.height } ?? 0 }
        return PadControl.allCases.filter { frames[$0, default: .null].insetBy(dx: -6, dy: -6).contains(p) }
            .min { area($0) < area($1) }
    }

    private func editBegan(_ touches: Set<UITouch>) {
        guard drag == nil, let t = touches.first else { return }
        let p = t.location(in: self)
        guard let c = control(at: p) else {
            selected = nil
            onSelect?(nil)
            return
        }
        let o = center(c)
        drag = (t, c, CGPoint(x: o.x - p.x, y: o.y - p.y))
        selected = c
        onSelect?(c)
    }

    private func editMoved(_ touches: Set<UITouch>) {
        guard let d = drag, touches.contains(d.touch), bounds.width > 0, bounds.height > 0 else { return }
        let p = d.touch.location(in: self)
        var place = layout[d.control]
        place.x = Double((p.x + d.offset.x) / bounds.width)
        place.y = Double((p.y + d.offset.y) / bounds.height)
        layout[d.control] = place
        onEdit?(layout)
    }

    // MARK: drawing

    private static let rim = UIColor(white: 1, alpha: 0.28)
    private static let fill = UIColor(white: 1, alpha: 0.08)
    private static let lit = UIColor(white: 1, alpha: 0.32)
    private static let faceColors: [Face: UIColor] = [
        .a: UIColor(red: 0.42, green: 0.80, blue: 0.27, alpha: 1), .b: UIColor(red: 0.90, green: 0.29, blue: 0.25, alpha: 1),
        .x: UIColor(red: 0.25, green: 0.52, blue: 0.95, alpha: 1), .y: UIColor(red: 0.98, green: 0.78, blue: 0.20, alpha: 1),
    ]
    private static let faceLabels: [Face: String] = [.a: "A", .b: "B", .x: "X", .y: "Y"]
    private static let accent = UIColor(red: 1, green: 0.72, blue: 0.2, alpha: 1)

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        for c in PadControl.allCases where shows(c) {
            ctx.saveGState()
            // Editing, a hidden control is drawn faint so it can be shown again.
            if layout[c].hidden { ctx.setAlpha(0.3) }
            draw(c)
            ctx.restoreGState()
        }
        if editing, let c = selected, let f = frames[c] {
            let path = UIBezierPath(roundedRect: f.insetBy(dx: -6, dy: -6), cornerRadius: 10)
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            Self.accent.setStroke()
            path.stroke()
        }
    }

    private func draw(_ c: PadControl) {
        let s = scale(c), o = center(c)
        switch c {
        case .leftTrigger, .leftBumper, .rightBumper, .rightTrigger:
            let r = frames[c] ?? .null
            shape(UIBezierPath(roundedRect: r, cornerRadius: r.height / 2), on: pressed.contains(c))
            text(c.title, at: o, size: 17 * s)
        case .back, .home, .start:
            shape(UIBezierPath(ovalIn: frames[c] ?? .null), on: pressed.contains(c))
            text(c == .back ? "⧉" : c == .home ? "⌂" : "≡", at: o, size: 20 * s)
        case .leftStick: stick(left, label: "L")
        case .rightStick: stick(right, label: "R")
        case .dpad:
            // A plus, each arm lit when its direction is held.
            let a = 64 * s, half = a * 0.36
            let arms: [(CGRect, Bool)] = [
                (CGRect(x: o.x - half, y: o.y - a, width: 2 * half, height: a - half), dpadDirection.up),
                (CGRect(x: o.x - half, y: o.y + half, width: 2 * half, height: a - half), dpadDirection.down),
                (CGRect(x: o.x - a, y: o.y - half, width: a - half, height: 2 * half), dpadDirection.left),
                (CGRect(x: o.x + half, y: o.y - half, width: a - half, height: 2 * half), dpadDirection.right),
            ]
            shape(UIBezierPath(roundedRect: CGRect(x: o.x - half, y: o.y - half, width: 2 * half, height: 2 * half),
                               cornerRadius: 2), on: false, rim: false)
            for (r, on) in arms { shape(UIBezierPath(roundedRect: r, cornerRadius: 6 * s), on: on) }
        case .face:
            let offset = 56 * s, radius = 30 * s
            for (f, d) in Self.face {
                let center = CGPoint(x: o.x + d.x * offset, y: o.y + d.y * offset)
                let r = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
                let on = facePressed.contains(f)
                let color = Self.faceColors[f]!
                color.withAlphaComponent(on ? 0.85 : 0.22).setFill()
                UIBezierPath(ovalIn: r).fill()
                color.withAlphaComponent(0.9).setStroke()
                let path = UIBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
                path.lineWidth = 2
                path.stroke()
                text(Self.faceLabels[f]!, at: center, size: 22 * s, color: on ? .black : color)
            }
        }
    }

    private func stick(_ s: Stick, label: String) {
        let base = UIBezierPath(ovalIn: CGRect(x: s.center.x - s.radius, y: s.center.y - s.radius,
                                               width: 2 * s.radius, height: 2 * s.radius))
        shape(base, on: false)
        let knob = s.radius * 0.48
        let c = CGPoint(x: s.center.x + s.value.x * (s.radius - knob * 0.6), y: s.center.y + s.value.y * (s.radius - knob * 0.6))
        let k = UIBezierPath(ovalIn: CGRect(x: c.x - knob, y: c.y - knob, width: 2 * knob, height: 2 * knob))
        (s.touch != nil ? Self.lit : UIColor(white: 1, alpha: 0.16)).setFill()
        k.fill()
        (s.clicked ? UIColor.white : Self.rim).setStroke()
        k.lineWidth = s.clicked ? 3 : 1.5
        k.stroke()
        text(label, at: c, size: knob * 0.6)
    }

    private func shape(_ path: UIBezierPath, on: Bool, rim: Bool = true) {
        (on ? Self.lit : Self.fill).setFill()
        path.fill()
        if rim {
            Self.rim.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private func text(_ s: String, at p: CGPoint, size: CGFloat, color: UIColor = UIColor(white: 1, alpha: 0.85)) {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color]
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        str.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
    }
}
#endif
