// SPDX-License-Identifier: GPL-3.0-or-later
import GameController
import HostIOKit
import SwiftUI
import UIKit

/// Only the controls intercept touches; the uncovered game keeps tap-to-click.
struct TouchGamepadOverlay: View {
    @AppStorage("touchGamepadEnabled") private var enabled = true
    @ObservedObject private var launch = TitleLaunch.shared
    @ObservedObject private var menu = InGameMenu.shared
    @ObservedObject private var web = GameWebSheet.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var physicalPad = GCController.controllers().contains { $0.extendedGamepad != nil }

    var body: some View {
        ZStack(alignment: .top) {
            TouchGamepadSurface(active: enabled && !physicalPad && scenePhase == .active
                                && !launch.showsSheet && !menu.isOpen && !menu.quitting && !web.isUp)
            if launch.acceptsMenu && !menu.isOpen && !menu.quitting && !web.isUp {
                Button { _ = InGameMenu.shared.open() } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 48, height: 44)
                        .foregroundStyle(.white).background(.black.opacity(0.45), in: Capsule())
                }
                .accessibilityLabel("Open game menu")
                .accessibilityIdentifier("touch-game-menu")
                .padding(.top, 8)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in refresh() }
    }

    private func refresh() {
        physicalPad = GCController.controllers().contains { $0.extendedGamepad != nil }
    }
}

private struct TouchGamepadSurface: UIViewRepresentable {
    var active: Bool
    func makeUIView(context: Context) -> TouchGamepadView { TouchGamepadView() }
    func updateUIView(_ view: TouchGamepadView, context: Context) { view.active = active }
    static func dismantleUIView(_ view: TouchGamepadView, coordinator: ()) { view.reset() }
}

final class TouchGamepadView: UIView {
    #if !PLAYPORT_RELEASE
    static weak var drivenView: TouchGamepadView?

    /// Dev driver enters the same finger state machine as UIKit.
    func drive(_ controls: [(TouchGamepad.Control, Float, Float)]) {
        reset()
        for (id, value) in controls.enumerated() {
            pad.begin(id, control: value.0)
            pad.move(id, x: value.1, y: value.2)
        }
        publish()
    }
    #endif
    private typealias Control = TouchGamepad.Control
    private var pad = TouchGamepad()
    private var lastInput = PadInput()
    private var fingers: [ObjectIdentifier: (id: Int, control: Control)] = [:]
    private var nextID = 0
    private var frames: [(Control, CGRect)] = []
    private var layoutArea = CGRect.null
    private var observers: [NSObjectProtocol] = []
    var active = false {
        didSet {
            isHidden = !active
            if !active { reset() }
        }
    }

    init() {
        super.init(frame: .zero)
        #if !PLAYPORT_RELEASE
        Self.drivenView = self
        #endif
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        accessibilityIdentifier = "touch-gamepad"
        // Clear ownership as well as output: a finger held while switching apps must
        // never resurrect a press, even if UIKit sends a late move after activation.
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reset() }
            })
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.inset(by: safeAreaInsets)
        guard area != layoutArea else { return }
        layoutArea = area
        reset()
        let scale = min(1, min(area.width / 760, area.height / 320))
        let left = area.minX, right = area.maxX, bottom = area.maxY
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 46, _ h: CGFloat = 46) -> CGRect {
            CGRect(x: x - w * scale / 2, y: y - h * scale / 2, width: w * scale, height: h * scale)
        }
        func l(_ x: CGFloat) -> CGFloat { left + x * scale }
        func r(_ x: CGFloat) -> CGFloat { right - x * scale }
        func b(_ y: CGFloat) -> CGFloat { bottom - y * scale }
        frames = [
            (.leftStick, rect(l(90), b(105), 128, 128)),
            (.rightStick, rect(r(220), b(85), 112, 112)),
            (.up, rect(l(218), b(160))), (.down, rect(l(218), b(68))),
            (.left, rect(l(172), b(114))), (.right, rect(l(264), b(114))),
            (.a, rect(r(88), b(62))), (.b, rect(r(42), b(108))),
            (.x, rect(r(134), b(108))), (.y, rect(r(88), b(154))),
            (.lb, rect(l(74), b(215), 64)), (.lt, rect(l(150), b(215), 64)),
            (.rb, rect(r(74), b(215), 64)), (.rt, rect(r(150), b(215), 64)),
            (.l3, rect(l(54), b(27))), (.r3, rect(r(220), b(27))),
            (.back, rect(area.midX - 36 * scale, b(30), 64)),
            (.start, rect(area.midX + 36 * scale, b(30), 64)),
        ]
        setNeedsDisplay()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        active && frames.contains { $0.1.contains(point) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard active else { return }
        for touch in touches where touch.type == .direct {
            guard let (control, _) = frames.last(where: { $0.1.contains(touch.location(in: self)) }) else { continue }
            nextID += 1
            fingers[ObjectIdentifier(touch)] = (nextID, control)
            pad.begin(nextID, control: control)
            move(touch)
        }
        publish()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard active else { return }
        for touch in touches { move(touch) }
        publish()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches) }

    private func move(_ touch: UITouch) {
        guard let finger = fingers[ObjectIdentifier(touch)],
              finger.control == .leftStick || finger.control == .rightStick,
              let frame = frames.first(where: { $0.0 == finger.control })?.1 else { return }
        let point = touch.location(in: self), radius = frame.width / 2
        pad.move(finger.id, x: Float((point.x - frame.midX) / radius), y: Float((frame.midY - point.y) / radius))
    }
    private func end(_ touches: Set<UITouch>) {
        for touch in touches {
            if let finger = fingers.removeValue(forKey: ObjectIdentifier(touch)) { pad.end(finger.id) }
        }
        publish()
    }
    func reset() { fingers.removeAll(); pad.reset(); publish() }
    private func publish() {
        let input = pad.input
        if input != lastInput {
            lastInput = input
            HostIO.shared.touchPadChanged(input)
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let input = pad.input
        for (control, frame) in frames {
            let held = pad.isHeld(control)
            let path = UIBezierPath(roundedRect: frame, cornerRadius: min(frame.width, frame.height) / 2)
            (held ? UIColor(red: 0.96, green: 0.71, blue: 0.27, alpha: 0.45) : UIColor.black.withAlphaComponent(0.3)).setFill()
            path.fill()
            UIColor.white.withAlphaComponent(0.55).setStroke(); path.lineWidth = 1.5; path.stroke()
            if control == .leftStick || control == .rightStick {
                let x = CGFloat(control == .leftStick ? input.lx : input.rx)
                let y = CGFloat(control == .leftStick ? input.ly : input.ry)
                let knob = CGRect(x: frame.midX + x * frame.width * 0.3 - 17,
                                  y: frame.midY - y * frame.height * 0.3 - 17, width: 34, height: 34)
                UIColor.white.withAlphaComponent(0.55).setFill(); UIBezierPath(ovalIn: knob).fill()
            } else {
                let text = control.rawValue as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                                                           .foregroundColor: UIColor.white]
                let size = text.size(withAttributes: attrs)
                text.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2), withAttributes: attrs)
            }
        }
    }
}
