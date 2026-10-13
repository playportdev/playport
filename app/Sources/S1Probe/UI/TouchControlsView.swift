// SPDX-License-Identifier: GPL-3.0-or-later
// The on-screen controls over a running game (docs/plans/2026-10-09-touch-controls.md,
// phase 1; docs/design/2026-10-09-touch-controls/TouchGamepad.dc.html).
//
// OnScreenControls decides, and moves events; HostIOKit's TouchControls holds
// the touch state and InputMixer (through HostIO.touchControls) turns it into
// the guest's slot 0, keys and pointer (a three-finger tap anywhere on the
// game opens the in-game menu: GameSurfaceView, HostIO.menuGesture):
//
// - Automatic display (PlayportKit ControlsState): with the game's layout on
//   and no extended controller connected (the dev build's scripted pad counts),
//   they are drawn and take touches once the game draws its first frame. A
//   controller connecting hides them, its going brings them back. The first
//   time they show on their own, a toast says why and teaches the three-finger tap.
// - The controls' pad is player 1 from the runtime's start whenever no
//   controller is connected, at rest while the layout is Off
//   (ControlsState.padConnected): a game that looks for pads only at its start
//   or now and then already has it, so turning the controls on in-game only
//   draws them (touch controls 1c evidence).
// - Nothing stays held: the in-game menu or a web page over the game
//   (HostIO.holdGuest), a guest dialog over the game, the app leaving the
//   front, a new layout or size, and the controls hiding all let go of every
//   touch.
// - TouchControlsView, a subview of GameSurfaceView, lays the controls out in
//   its safe area (the notch or Dynamic Island on either side, the home
//   indicator) and again when that changes, and hit-tests only the controls
//   and the floating sticks' zones (not drawn): every other touch
//   falls through to the game as a click, as before. A flat translucent fill,
//   amber while held, a light haptic tick on each press (Settings › Controls).
//   No backdrop blur: with one, pink glitches flickered over the game (phase 1
//   on the phone), most likely the blur sampling the game's Metal layer.
// - The fingers of a three-finger tap are cancelled (UIKit's touchesCancelled):
//   whatever they held is let go, as if they had never come down.
//
// A dev build logs `controls:` lines: shown and hidden, and each press.

#if canImport(UIKit)
import Combine
import HostIOKit
import PlayportKit
import QuartzCore
import UIKit

@MainActor
final class OnScreenControls: ObservableObject {
    static let shared = OnScreenControls()

    /// The game's controls as resolved now.
    @Published private(set) var state = ControlsState(layout: .gamepad, visible: false, opacity: ControlsOpacity.defaultValue)
    /// Drawn and taking touches.
    @Published private(set) var drawn = false
    private(set) var layout: ControlLayout?
    private(set) var controls = TouchControls()
    /// The controls' pad is in slot 0 (HostIO.touchControls).
    private var padOn = false
    /// padOn as last logged.
    private var loggedPad = false
    private var started = false
    private var controllers = 0
    private var guestHeld = false
    private var dialog = false
    private var size = CGSize.zero
    private var insets = ControlInsets.zero
    private var subscriptions: Set<AnyCancellable> = []
    private var clock: CADisplayLink?
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    weak var view: TouchControlsView?

    /// Set once the first-time toast (which teaches the three-finger tap) has shown.
    static let toastKey = "controls.menuGestureToastShown"

    private static func log(_ line: String) {
        #if !PLAYPORT_RELEASE
        HostIO.log("controls: " + line)
        #endif
    }

    /// HostIO.start, once the controllers already connected are counted.
    func start(controllers n: Int) {
        guard !started else { return }
        started = true
        controllers = n
        let later = { DispatchQueue.main.async { MainActor.assumeIsolated { OnScreenControls.shared.update() } } }
        // objectWillChange and @Published fire before the change: read it on the next turn.
        ControlsStore.shared.objectWillChange.sink { _ in later() }.store(in: &subscriptions)
        TitleLaunch.shared.objectWillChange.sink { _ in later() }.store(in: &subscriptions)
        update()
        Self.log("start: \(n) controller(s) connected; \(state.summary), " + (padOn ? "player 1 is the controls' pad" : "no controls' pad"))
    }

    func controllersChanged(_ n: Int) {
        guard n != controllers else { return }
        controllers = n
        update()
    }

    /// The in-game menu or a web page holds the game's input (HostIO.holdGuest), or let it go.
    func guestHeld(_ held: Bool) {
        guestHeld = held
        update()
    }

    /// A guest dialog came over the game, or the last one went (HostIO.dialogOverGame).
    func dialogOverGame(_ up: Bool) {
        dialog = up
        update()
    }

    /// The app leaves the front: every touch let go.
    func releaseAll() {
        guard controls.touching || !controls.held.isEmpty else { return }
        controls.releaseAll()
        publish()
    }

    /// The view's size and safe area: the controls placed again.
    func layout(in s: CGSize, insets i: ControlInsets) {
        guard s != size || i != insets else { return }
        size = s
        insets = i
        Self.log("placed in \(Int(s.width))x\(Int(s.height)), safe area insets top=\(Int(i.top)) left=\(Int(i.left)) "
                 + "bottom=\(Int(i.bottom)) right=\(Int(i.right))")
        place()
    }

    private func update() {
        guard started else { return }
        let launch = TitleLaunch.shared
        let game = launch.titleID.map { ControlsStore.shared.game($0) }
        let defaults = ControlsStore.shared.defaults
        let s = ControlsState.resolve(game: game, defaults: defaults, controllerConnected: controllers > 0)
        let newLayout = s.drawnLayout
        let drawNow = newLayout != nil && launch.running && launch.step == .drawing && !launch.quitting && !guestHeld && !dialog
        let changed = s != state || drawNow != drawn || newLayout != layout
        guard changed || padOn != (s.padConnected && launch.running) else { return }
        let layoutChanged = newLayout != layout
        if drawNow != drawn || (drawNow && layoutChanged) {
            Self.log(drawNow ? "shown (\(s.layout.title), \(ControlsOpacity.label(s.opacity)), d-pad \(s.dpad.rawValue), "
                     + "right stick \(s.rightStick.rawValue))"
                     : "hidden (" + (newLayout == nil ? "controller connected" : guestHeld ? "menu" : dialog ? "dialog"
                                     : "game not drawing") + ")")
        }
        if drawNow, !drawn, s.visible, defaults.show == .automatic, !UserDefaults.standard.bool(forKey: Self.toastKey) {
            UserDefaults.standard.set(true, forKey: Self.toastKey)
            view?.showToast("Tap with three fingers for the menu. The controls hide when a controller connects.")
        }
        state = s
        drawn = drawNow
        layout = newLayout
        padOn = s.padConnected && launch.running
        if padOn != loggedPad {
            loggedPad = padOn
            Self.log(padOn ? "player 1 is the controls' pad (\(s.layout.title))" : "the controls' pad left player 1")
        }
        if layoutChanged { place() }
        if !drawn { controls.releaseAll() }
        publish()
    }

    private func place() {
        controls.setTargets(layout?.targets(width: Double(size.width), height: Double(size.height), insets: insets) ?? [])
        view?.rebuild()
        publish()
    }

    /// The touch state to the guest, and the view redrawn.
    private func publish() {
        HostIO.shared.touchControls(padOn ? controls.output : nil)
        view?.refresh()
        if controls.needsClock, clock == nil {
            let link = CADisplayLink(target: ClockTarget.shared, selector: #selector(ClockTarget.tick))
            link.add(to: .main, forMode: .common)
            clock = link
        } else if !controls.needsClock, let link = clock {
            link.invalidate()
            clock = nil
        }
    }

    fileprivate func tick() {
        controls.tick(time: CACurrentMediaTime())
        publish()
    }

    // MARK: touches (TouchControlsView, and a dev build's `touch:`)

    func takes(_ p: CGPoint) -> Bool {
        drawn && controls.target(at: TouchPoint(x: Double(p.x), y: Double(p.y))) != nil
    }

    @discardableResult
    func began(_ touch: Int, at p: CGPoint) -> Bool {
        guard drawn else { return false }
        let point = TouchPoint(x: Double(p.x), y: Double(p.y))
        guard let i = controls.target(at: point), controls.began(touch, at: point, time: CACurrentMediaTime()) else { return false }
        if ControlsStore.shared.defaults.haptics { haptic.impactOccurred() }
        Self.log("\(controls.targets[i].id) down")
        publish()
        return true
    }

    func moved(_ touch: Int, at p: CGPoint) {
        controls.moved(touch, at: TouchPoint(x: Double(p.x), y: Double(p.y)), time: CACurrentMediaTime())
        publish()
    }

    func ended(_ touch: Int) {
        controls.ended(touch, time: CACurrentMediaTime())
        publish()
    }

    /// UIKit took the finger back (the three-finger tap it was part of): as if it never came down.
    func cancelled(_ touch: Int) {
        let held = controls.held
        controls.cancelled(touch, time: CACurrentMediaTime())
        if controls.held != held { Self.log("finger cancelled; held=\(controls.held.sorted().joined(separator: "+"))") }
        publish()
    }
}

/// CADisplayLink holds its target strongly; this one lives for the app.
@MainActor
private final class ClockTarget: NSObject {
    static let shared = ClockTarget()
    @objc func tick() { OnScreenControls.shared.tick() }
}

/// The controls, drawn over GameSurfaceView and taking only the touches on them.
final class TouchControlsView: UIView {
    private var views: [String: ControlView] = [:]
    private let toast = ToastView()
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouch = 1

    init() {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isHidden = true
        addSubview(toast)
        accessibilityIdentifier = "touch-controls"
        OnScreenControls.shared.view = self
    }

    required init?(coder: NSCoder) { fatalError("TouchControlsView is created in code") }

    /// The safe area to lay the controls out in. The game view ignores the safe
    /// area, and fills the window: the window's insets are taken too, whichever is larger.
    private var controlInsets: UIEdgeInsets {
        let own = safeAreaInsets, w = window?.safeAreaInsets ?? .zero
        return UIEdgeInsets(top: max(own.top, w.top), left: max(own.left, w.left),
                            bottom: max(own.bottom, w.bottom), right: max(own.right, w.right))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let i = controlInsets
        OnScreenControls.shared.layout(in: bounds.size, insets: ControlInsets(top: Double(i.top), left: Double(i.left),
                                                                              bottom: Double(i.bottom), right: Double(i.right)))
        toast.place(in: bounds.inset(by: i))
    }

    /// The phone turned (the island to the other side) or the insets otherwise changed: laid out again.
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        OnScreenControls.shared.takes(point)
    }

    /// The layout changed: one view per control. A floating stick's zone is not drawn.
    func rebuild() {
        views.values.forEach { $0.removeFromSuperview() }
        views = [:]
        let model = OnScreenControls.shared
        for (c, t) in zip(model.layout?.controls ?? [], model.controls.targets) {
            let v = ControlView(control: c, frame: CGRect(x: t.frame.x, y: t.frame.y, width: t.frame.width, height: t.frame.height))
            insertSubview(v, belowSubview: toast)
            views[c.id] = v
        }
    }

    /// What is held now, and whether the controls are shown.
    func refresh() {
        let model = OnScreenControls.shared
        isHidden = !model.drawn
        alpha = CGFloat(model.state.opacity)
        guard model.drawn else { return }
        let held = model.controls.held, pad = model.controls.output.pad
        for (id, v) in views {
            v.show(held: held.contains(id), pad: pad, stick: model.controls.stick(id))
        }
    }

    func showToast(_ text: String) { toast.show(text, seconds: 6) }

    private func id(_ t: UITouch) -> Int {
        if let n = touchIDs[ObjectIdentifier(t)] { return n }
        nextTouch += 1
        touchIDs[ObjectIdentifier(t)] = nextTouch
        return nextTouch
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .direct { OnScreenControls.shared.began(id(t), at: t.location(in: self)) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .direct { OnScreenControls.shared.moved(id(t), at: t.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches, cancelled: true) }

    private func end(_ touches: Set<UITouch>, cancelled: Bool) {
        for t in touches {
            guard let n = touchIDs.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            if cancelled { OnScreenControls.shared.cancelled(n) } else { OnScreenControls.shared.ended(n) }
        }
    }
}

/// The design's colours (TouchGamepad.dc.html).
private enum Glass {
    /// Flat, with no blur behind it: a little darker than the board's glass tint to read as well.
    static let fill = UIColor(red: 12 / 255, green: 16 / 255, blue: 24 / 255, alpha: 0.38)
    static let edge = UIColor(red: 238 / 255, green: 241 / 255, blue: 245 / 255, alpha: 0.40)
    static let text = UIColor(red: 238 / 255, green: 241 / 255, blue: 245 / 255, alpha: 0.94)
    static let amber = UIColor(red: 245 / 255, green: 181 / 255, blue: 68 / 255, alpha: 0.92)
    static let amberEdge = UIColor(red: 1, green: 208 / 255, blue: 138 / 255, alpha: 1)
    static let onAmber = UIColor(red: 26 / 255, green: 18 / 255, blue: 4 / 255, alpha: 1)
    static let nub = UIColor(red: 232 / 255, green: 237 / 255, blue: 244 / 255, alpha: 0.85)
    static let faces: [String: UIColor] = [
        "A": UIColor(red: 134 / 255, green: 222 / 255, blue: 147 / 255, alpha: 1),
        "B": UIColor(red: 1, green: 142 / 255, blue: 128 / 255, alpha: 1),
        "X": UIColor(red: 134 / 255, green: 185 / 255, blue: 1, alpha: 1),
        "Y": UIColor(red: 247 / 255, green: 215 / 255, blue: 102 / 255, alpha: 1),
    ]
}

/// One control shape: a flat translucent fill (amber while held), the edge and a label.
private final class GlassView: UIView {
    let label = UILabel()
    private let labelColor: UIColor

    init(frame: CGRect, radius: CGFloat, text: String, font: UIFont, labelColor: UIColor = Glass.text) {
        self.labelColor = labelColor
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = radius
        layer.borderWidth = 1.5
        layer.borderColor = Glass.edge.cgColor
        backgroundColor = Glass.fill
        label.frame = bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.text = text
        label.font = font
        label.textAlignment = .center
        label.textColor = labelColor
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("GlassView is created in code") }

    func lit(_ on: Bool) {
        backgroundColor = on ? Glass.amber : Glass.fill
        layer.borderColor = (on ? Glass.amberEdge : Glass.edge).cgColor
        label.textColor = on ? Glass.onAmber : labelColor
    }
}

/// A control as TouchGamepad.dc.html draws it. The d-pad and the face buttons
/// are drawn 2 points inside their frame, which is what a touch hits: the
/// d-pad's arms and a face button come out the same size, and so do the two
/// clusters (ControlLayout.gamepad).
private final class ControlView: UIView {
    private let control: Control
    private var parts: [GlassView] = []
    private var base: GlassView?
    private var nub: UIView?
    private let home: CGRect

    init(control: Control, frame: CGRect) {
        self.control = control
        home = frame
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let w = frame.width, h = frame.height
        switch control.kind {
        case .button:
            let round = Glass.faces[control.label] != nil
            let font = UIFont.systemFont(ofSize: round ? 18 : 13, weight: .semibold)
            let drawn = round ? bounds.insetBy(dx: 2, dy: 2) : bounds
            let g = GlassView(frame: drawn, radius: round ? drawn.width / 2 : h / 2, text: control.label, font: font,
                              labelColor: Glass.faces[control.label] ?? Glass.text)
            addSubview(g)
            parts = [g]
        case .dpad:
            let side = min(w, h) - 4, o = 2.0
            let s = side * 30 / 92, mid = o + (side - s) / 2, far = o + side - s
            for (x, y, glyph) in [(mid, o, "▲"), (mid, far, "▼"), (o, mid, "◀"), (far, mid, "▶")] {
                let g = GlassView(frame: CGRect(x: x, y: y, width: s, height: s), radius: 8, text: glyph,
                                  font: .systemFont(ofSize: 10, weight: .semibold))
                addSubview(g)
                parts.append(g)
            }
        case .stick:
            let g = GlassView(frame: bounds, radius: w / 2, text: "", font: .systemFont(ofSize: 10))
            g.layer.borderColor = Glass.edge.withAlphaComponent(0.34).cgColor
            addSubview(g)
            base = g
            let n = UIView(frame: CGRect(x: w / 2 - 25, y: h / 2 - 25, width: 50, height: 50))
            n.backgroundColor = Glass.nub
            n.layer.cornerRadius = 25
            n.layer.shadowColor = UIColor.black.cgColor
            n.layer.shadowOpacity = 0.35
            n.layer.shadowRadius = 8
            n.layer.shadowOffset = CGSize(width: 0, height: 6)
            addSubview(n)
            nub = n
        }
    }

    required init?(coder: NSCoder) { fatalError("ControlView is created in code") }

    func show(held: Bool, pad: PadInput, stick: (origin: TouchPoint, x: Double, y: Double)?) {
        switch control.kind {
        case .button:
            parts.first?.lit(held)
        case .dpad:
            for (g, on) in zip(parts, [pad.up, pad.down, pad.left, pad.right]) { g.lit(on) }
        case .stick:
            let r = home.width / 2
            // A floating stick moves to where the thumb landed; a fixed one keeps its place.
            if let s = stick, control.floatingZone != nil {
                frame = CGRect(x: s.origin.x - r, y: s.origin.y - r, width: home.width, height: home.height)
            } else if stick == nil {
                frame = home
            }
            base?.layer.borderColor = held ? Glass.amberEdge.cgColor : Glass.edge.withAlphaComponent(0.34).cgColor
            nub?.backgroundColor = held ? Glass.amber : Glass.nub
            let dx = CGFloat(stick?.x ?? 0) * r, dy = -CGFloat(stick?.y ?? 0) * r
            nub?.center = CGPoint(x: bounds.midX + dx, y: bounds.midY + dy)
        }
    }
}

/// The first-time note at the top of the screen.
private final class ToastView: UIView {
    private let label = UILabel()
    private var hide: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(red: 21 / 255, green: 26 / 255, blue: 33 / 255, alpha: 0.86)
        layer.cornerRadius = 16
        layer.borderWidth = 1
        layer.borderColor = UIColor(red: 42 / 255, green: 51 / 255, blue: 64 / 255, alpha: 1).cgColor
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = UIColor(red: 201 / 255, green: 209 / 255, blue: 220 / 255, alpha: 1)
        label.textAlignment = .center
        addSubview(label)
        alpha = 0
    }

    required init?(coder: NSCoder) { fatalError("ToastView is created in code") }

    /// Centred in `area` (the safe area), under the top row of controls.
    func place(in area: CGRect) {
        self.area = area
        let size = label.sizeThatFits(CGSize(width: area.width - 120, height: 40))
        frame = CGRect(x: area.midX - (size.width + 28) / 2, y: area.minY + 52, width: size.width + 28, height: 32)
        label.frame = self.bounds
    }

    private var area = CGRect.zero

    func show(_ text: String, seconds: Double) {
        label.text = text
        place(in: area)
        UIView.animate(withDuration: 0.25) { self.alpha = 1 }
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { UIView.animate(withDuration: 0.4) { self?.alpha = 0 } }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
#endif
