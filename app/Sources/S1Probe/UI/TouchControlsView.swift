// SPDX-License-Identifier: GPL-3.0-or-later
// The on-screen controls over a running game (docs/plans/2026-10-09-touch-controls.md,
// phases 1 and 4; docs/design/2026-10-09-touch-controls/TouchGamepad.dc.html,
// TouchKeyboardMouse.dc.html).
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
//   indicator) and again when that changes, and hit-tests only the controls,
//   the floating sticks' zones (not drawn) and a look area (Keyboard & mouse:
//   the whole safe area under the rest, a faint hint and a ring under each
//   finger looking; its drags and the pointer's are events, taken with the
//   holds each time they are published). Every other touch falls
//   through to GameSurfaceView, which ignores it while the controls show
//   (HostIOKit TouchRoute; owner, 2026-10-13: a stray touch flicked the view):
//   no cursor, no click. Its three-finger tap still sees every finger. A flat translucent fill,
//   amber while held, a light haptic tick on each press (Settings › Controls).
//   No backdrop blur: with one, pink glitches flickered over the game (phase 1
//   on the phone), most likely the blur sampling the game's Metal layer.
// - The fingers of a three-finger tap are cancelled (UIKit's touchesCancelled):
//   whatever they held is let go, as if they had never come down.
//
// - The "Gyro aim" chip (TouchKeyboardMouse.dc.html's lit chip): a small chip
//   at the top middle of the safe area, between View and Menu, that fades in
//   as gyro aim starts for the game, stays `GyroChipCue.seconds` and fades out
//   (PlayportKit GyroChipCue decides when: GyroSensors). Drawn in its own view
//   over the game (GyroChipOverlay, which takes no touch), not with the
//   controls: it shows with the layout Off or a controller connected too, at
//   its own opacity; gone at once when gyro aim stops.
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
    /// Gyro aim runs for the game.
    private(set) var gyroAiming = false
    /// A touch outside the shown controls was logged (once per game: the app restarts after each).
    private var loggedIgnored = false
    private(set) var layout: ControlLayout?
    private(set) var controls = TouchControls()
    /// The controls' pad is in slot 0 (HostIO.touchControls).
    private var padOn = false
    /// padOn as last logged.
    private var loggedPad = false
    private var started = false
    /// The extended controllers connected (the dev build's scripted pad too); the in-game
    /// menu's Controls panel shows its Controller row while there is one.
    @Published private(set) var controllers = 0
    private var guestHeld = false
    private var dialog = false
    private var size = CGSize.zero
    private var insets = ControlInsets.zero
    private var subscriptions: Set<AnyCancellable> = []
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    weak var view: TouchControlsView?
    weak var chipView: GyroChipOverlay?

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

    /// GyroSensors: gyro aim started or stopped for the game.
    func gyroAiming(_ on: Bool) {
        guard on != gyroAiming else { return }
        gyroAiming = on
        if !on { chipView?.hideNow() }
    }

    /// GyroSensors: gyro aim started for the game (GyroChipCue): the chip, briefly,
    /// whether the controls are shown or not.
    func showGyroChip() {
        chipView?.show(seconds: GyroChipCue.seconds)
    }

    /// Where a finger at p (in the controls' view) goes: to them, nowhere while they show, else to the game.
    func route(_ p: CGPoint) -> TouchRoute {
        let to = TouchRoute.decide(controlsShown: drawn, onControl: takes(p))
        if to == .ignored, !loggedIgnored {
            loggedIgnored = true
            Self.log("touches outside the controls are ignored")
        }
        return to
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

    /// The touch state to the guest (with the look area's and pointer's events since the last
    /// time, taken every time so none waits for a later one), and the view redrawn.
    private func publish() {
        let out = controls.takeOutput()
        HostIO.shared.touchControls(padOn ? out : nil)
        view?.refresh()
        InputClock.shared.need(.touchControls, controls.needsClock)
    }

    /// InputClock's tick while the controls need it.
    func tick() {
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

    override func layoutSubviews() {
        super.layoutSubviews()
        let i = gameSafeInsets
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
        let held = model.controls.held, out = model.controls.output
        for (id, v) in views {
            v.show(held: held.contains(id), pad: out.pad, keys: out.keys, stick: model.controls.stick(id))
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

/// The "Gyro aim" chip's own view over the game (GameSurfaceView, above the
/// controls), apart from them: it shows whether they are drawn or not, and
/// takes no touch.
final class GyroChipOverlay: UIView {
    private let chip = GyroChipView()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        addSubview(chip)
        OnScreenControls.shared.chipView = self
    }

    required init?(coder: NSCoder) { fatalError("GyroChipOverlay is created in code") }

    override func layoutSubviews() {
        super.layoutSubviews()
        chip.place(in: bounds.inset(by: gameSafeInsets))
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    func show(seconds: Double) { chip.show(seconds: seconds) }

    /// Gyro aim stopped: gone now.
    func hideNow() { chip.hideNow() }
}

private extension UIView {
    /// The safe area over the game. The game view ignores the safe area and
    /// fills the window: the window's insets are taken too, whichever is larger.
    var gameSafeInsets: UIEdgeInsets {
        let own = safeAreaInsets, w = window?.safeAreaInsets ?? .zero
        return UIEdgeInsets(top: max(own.top, w.top), left: max(own.left, w.left),
                            bottom: max(own.bottom, w.bottom), right: max(own.right, w.right))
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
    /// A caption under or beside a key's cap (USE, JUMP), and a W A S D stick's letters.
    static let caption = UIColor(red: 238 / 255, green: 241 / 255, blue: 245 / 255, alpha: 0.62)
    static let keyLetter = UIColor(red: 238 / 255, green: 241 / 255, blue: 245 / 255, alpha: 0.55)
    /// The look area's ring under each finger looking (TouchKeyboardMouse.dc.html's drag).
    static let ringFill = UIColor(red: 238 / 255, green: 241 / 255, blue: 245 / 255, alpha: 0.16)
    static let ringEdge = UIColor(red: 238 / 255, green: 241 / 255, blue: 245 / 255, alpha: 0.6)
    static let faces: [String: UIColor] = [
        "A": UIColor(red: 134 / 255, green: 222 / 255, blue: 147 / 255, alpha: 1),
        "B": UIColor(red: 1, green: 142 / 255, blue: 128 / 255, alpha: 1),
        "X": UIColor(red: 134 / 255, green: 185 / 255, blue: 1, alpha: 1),
        "Y": UIColor(red: 247 / 255, green: 215 / 255, blue: 102 / 255, alpha: 1),
    ]
}

/// One control shape: a flat translucent fill (amber while held), the edge and a label,
/// or an SF Symbol instead of it; with a caption, small and in capitals, under them on a
/// round control and beside them on a pill (TouchKeyboardMouse.dc.html: "E" over USE).
private final class GlassView: UIView {
    let label = UILabel()
    private let labelColor: UIColor
    private var icon: UIImageView?
    private var caption: UILabel?
    private let column: Bool

    init(frame: CGRect, radius: CGFloat, text: String, font: UIFont, labelColor: UIColor = Glass.text,
         symbol: String? = nil, caption text2: String? = nil) {
        self.labelColor = labelColor
        column = frame.width == frame.height
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = radius
        layer.borderWidth = 1.5
        layer.borderColor = Glass.edge.cgColor
        backgroundColor = Glass.fill
        label.text = text
        label.font = font
        label.textAlignment = .center
        label.textColor = labelColor
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        addSubview(label)
        if let symbol {
            let i = UIImageView(image: UIImage(systemName: symbol,
                                               withConfiguration: UIImage.SymbolConfiguration(pointSize: font.pointSize - 2, weight: .semibold)))
            i.tintColor = labelColor
            i.contentMode = .center
            label.isHidden = true
            addSubview(i)
            icon = i
        }
        if let text2 {
            let c = UILabel()
            c.attributedText = NSAttributedString(string: text2.uppercased(), attributes: [
                .font: UIFont.systemFont(ofSize: 8, weight: .bold), .kern: 0.7, .foregroundColor: Glass.caption,
            ])
            c.textAlignment = .center
            c.adjustsFontSizeToFitWidth = true
            c.minimumScaleFactor = 0.6
            addSubview(c)
            caption = c
        }
    }

    required init?(coder: NSCoder) { fatalError("GlassView is created in code") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let cap: UIView = icon ?? label
        guard let caption else { cap.frame = bounds; return }
        let room = CGSize(width: bounds.width - 8, height: bounds.height)
        let a = cap.sizeThatFits(room), b = caption.sizeThatFits(room)
        if column {
            let capH = min(a.height, bounds.height / 2), top = (bounds.height - capH - 3 - b.height) / 2
            cap.frame = CGRect(x: 4, y: top, width: room.width, height: capH)
            caption.frame = CGRect(x: 4, y: top + capH + 3, width: room.width, height: b.height)
        } else {
            let capW = min(a.width, room.width / 2), bw = min(b.width, room.width - capW - 6)
            let left = (bounds.width - capW - 6 - bw) / 2
            cap.frame = CGRect(x: left, y: 0, width: capW, height: bounds.height)
            caption.frame = CGRect(x: left + capW + 6, y: 0, width: bw, height: bounds.height)
        }
    }

    func lit(_ on: Bool) {
        backgroundColor = on ? Glass.amber : Glass.fill
        layer.borderColor = (on ? Glass.amberEdge : Glass.edge).cgColor
        label.textColor = on ? Glass.onAmber : labelColor
        icon?.tintColor = on ? Glass.onAmber : labelColor
        caption?.textColor = on ? Glass.onAmber.withAlphaComponent(0.72) : Glass.caption
    }
}

/// A control as TouchGamepad.dc.html and TouchKeyboardMouse.dc.html draw it.
/// The d-pad and the round buttons (a square frame: A/B/X/Y, Fire, Use) are
/// drawn 1 point inside their frame, which is what a touch hits: the d-pad's
/// arms and a face button come out the same size, and so do the two clusters
/// (ControlLayout.gamepad). A button shows its PlayportKit ControlFace: a key's
/// cap over its label, the mouse, the keyboard. A W A S D stick is a stick with
/// its keys' letters inside the ring, each amber while it is pressed. The look
/// area draws a faint hint and a ring under each finger looking.
private final class ControlView: UIView {
    private let control: Control
    private var parts: [GlassView] = []
    private var base: GlassView?
    private var nub: UIView?
    /// A W A S D stick's letters, up, down, left, right.
    private var letters: [UILabel] = []
    /// The look area's rings, one for each finger on it.
    private var rings: [UIView] = []
    private let home: CGRect

    init(control: Control, frame: CGRect) {
        self.control = control
        home = frame
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let w = frame.width, h = frame.height
        switch control.kind {
        case .button:
            let round = w == h, face = control.face
            let font = UIFont.systemFont(ofSize: round ? 18 : 13, weight: .semibold)
            let drawn = round ? bounds.insetBy(dx: 1, dy: 1) : bounds
            let text: String, symbol: String?
            switch face.cap {
            case .text(let t): text = t; symbol = nil
            case .mouse: text = ""; symbol = "computermouse"
            case .keyboard: text = ""; symbol = "keyboard"
            }
            let g = GlassView(frame: drawn, radius: round ? drawn.width / 2 : h / 2, text: text, font: font,
                              labelColor: Glass.faces[control.label] ?? Glass.text, symbol: symbol, caption: face.caption)
            addSubview(g)
            parts = [g]
        case .dpad:
            let side = min(w, h) - 2, o = 1.0
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
            // A key stick's letters: up at the top, down at the bottom, left and right at the sides,
            // over the nub so the one it leans to stays readable.
            for (i, letter) in (control.keyLetters ?? []).enumerated() {
                let l = UILabel()
                l.text = letter
                l.font = .systemFont(ofSize: 10, weight: .bold)
                l.textColor = Glass.keyLetter
                l.textAlignment = .center
                l.adjustsFontSizeToFitWidth = true
                l.minimumScaleFactor = 0.6
                let c = [CGPoint(x: w / 2, y: 13), CGPoint(x: w / 2, y: h - 13), CGPoint(x: 13, y: h / 2),
                         CGPoint(x: w - 13, y: h / 2)][i]
                l.frame = CGRect(x: c.x - 13, y: c.y - 8, width: 26, height: 16)
                addSubview(l)
                letters.append(l)
            }
        case .lookArea:
            // The board's "drag anywhere free to look", in the free space left of Jump and above Reload.
            let hint = UILabel()
            hint.attributedText = NSAttributedString(string: "DRAG ANYWHERE FREE TO LOOK", attributes: [
                .font: UIFont.systemFont(ofSize: 9.5, weight: .semibold), .kern: 0.85, .foregroundColor: Glass.caption,
            ])
            hint.numberOfLines = 2
            hint.frame = CGRect(x: max(0, w - 212), y: max(0, h - 231), width: 110, height: 28)
            addSubview(hint)
        case .pointer, .tool:
            break   // drawn by PLA-531
        }
    }

    required init?(coder: NSCoder) { fatalError("ControlView is created in code") }

    func show(held: Bool, pad: PadInput, keys: Set<InputAction>, stick: (origin: TouchPoint, x: Double, y: Double)?) {
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
            for (l, a) in zip(letters, control.actions) { l.textColor = keys.contains(a) ? Glass.amber : Glass.keyLetter }
        case .lookArea:
            let points = OnScreenControls.shared.controls.points(on: control.id)
            while rings.count < points.count {
                let r = UIView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
                r.backgroundColor = Glass.ringFill
                r.layer.cornerRadius = 15
                r.layer.borderWidth = 1.5
                r.layer.borderColor = Glass.ringEdge.cgColor
                addSubview(r)
                rings.append(r)
            }
            for (i, r) in rings.enumerated() {
                r.isHidden = i >= points.count
                if i < points.count { r.center = CGPoint(x: CGFloat(points[i].x) - home.minX, y: CGFloat(points[i].y) - home.minY) }
            }
        case .pointer, .tool:
            break
        }
    }
}

/// "Gyro aim", lit, at the top middle of the safe area: in line with View and
/// Menu (ControlLayout.gamepad's top row, 98 pt in from each side), clear of
/// them on the narrowest screen, and of the first-time note below it.
private final class GyroChipView: UIView {
    private let label = UILabel()
    private var hide: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        alpha = 0
        backgroundColor = Glass.fill
        layer.borderWidth = 1
        layer.borderColor = Glass.amberEdge.cgColor
        label.text = "Gyro aim"
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Glass.amber
        label.textAlignment = .center
        addSubview(label)
        accessibilityIdentifier = "gyro-chip"
    }

    required init?(coder: NSCoder) { fatalError("GyroChipView is created in code") }

    func place(in area: CGRect) {
        let w = label.sizeThatFits(CGSize(width: 200, height: 20)).width + 20, h = 22.0
        frame = CGRect(x: area.midX - w / 2, y: area.minY + 26, width: w, height: h)
        layer.cornerRadius = h / 2
        label.frame = bounds
    }

    /// Fades in, stays `seconds`, fades out.
    func show(seconds: Double) {
        hide?.cancel()
        UIView.animate(withDuration: 0.25, delay: 0, options: .beginFromCurrentState) { self.alpha = 1 }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                UIView.animate(withDuration: 0.5, delay: 0, options: .beginFromCurrentState) { self?.alpha = 0 }
            }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + seconds, execute: work)
    }

    /// Gyro aim stopped: gone now.
    func hideNow() {
        hide?.cancel()
        hide = nil
        layer.removeAllAnimations()
        alpha = 0
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
