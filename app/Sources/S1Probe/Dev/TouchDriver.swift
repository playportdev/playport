// SPDX-License-Identifier: GPL-3.0-or-later
// The UI driver's `touch:` (Dev/UIDriver.swift), dev builds only (decision
// 0012): fingers on the on-screen controls by id, through the same calls
// TouchControlsView makes for UIKit's touches (OnScreenControls.began, moved,
// ended), so hit-testing, the layout's places and the mixer are all the ones a
// person's fingers go through.
//
//   touch:<control>[+<control>...][@<ms>]
//
// A control is a layout control's id (UI/TouchControlsView.swift,
// PlayportKit ControlLayout: view menu lt lb rt rb leftStick y x b a in the
// Gamepad layout, with dpad and rightStick when the game's options have them;
// look esc tab keyboard 1 2 3 4 move use reload jump fire in Keyboard & mouse);
// a stick or the d-pad takes a direction after
// a dot (`dpad.right`, `leftStick.up`, `move.up`: the stick fully over, the d-pad near
// its edge). A floating stick's finger lands at its home, in its zone. The look
// area takes a direction too: a finger lands in its middle and drags `lookDrag`
// points that way at once (`look.left`: the view turns left), then rests.
// Point & click's ids: pointer mode rightClick hover scroll keyboard esc; the
// pointer surface's finger lands at the safe area's middle, or at a point
// given as fractions of the view, `pointer:0.25:0.6` (as `tap:` gives one); a
// tool's press turns it on or off. With the touch keyboard open (a layout's
// `keyboard` key, `menu:keyboard`), its keys are the controls instead (HostIOKit TouchKeyboard): kb-a, kb-1, kb-f1, kb-shift,
// kb-ctrl, kb-alt, kb-space, kb-enter, kb-backspace, kb-up, ... and kb-close; a
// tapped kb-shift stays down for the next `touch:` key. The
// in-game menu's three-finger tap is the driver's `gesture:three-finger-tap`. Every finger goes down together, stays `ms`
// milliseconds (200 by default, 10000 at most), and lifts together.

#if canImport(UIKit)
import Foundation
import HostIOKit
import PlayportKit
import UIKit

@MainActor
private enum DriverTouches {
    static var held: [Int] = []
}

extension OnScreenControls {
    func cancelDriverTouches() {
        for touch in DriverTouches.held { ended(touch) }
        DriverTouches.held.removeAll()
    }

    /// Presses `spec`; nil when it was pressed, else why not.
    func driverPress(_ spec: String) async throws -> String? {
        try UIDriver.checkpoint()
        defer { cancelDriverTouches() }
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        var ms = 200
        if parts.count == 2 {
            guard let n = Int(parts[1]), (0...10_000).contains(n) else { return "\(parts[1]) is not a hold of 0-10000 ms" }
            ms = n
        }
        guard drawn else { return "the on-screen controls are not shown (\(summary))" }
        var fingers: [(touch: Int, at: CGPoint, to: CGPoint)] = []
        for (i, word) in parts[0].split(separator: "+").map(String.init).enumerated() {
            let point = word.split(separator: ":").map(String.init)
            if point.count == 3 {
                guard let n = controls.targets.firstIndex(where: { $0.id == point[0] }), case .pointer = controls.targets[n].kind else {
                    return "\(point[0]) takes no point: only the pointer surface does (pointer:FX:FY)"
                }
                guard let fx = Double(point[1]), let fy = Double(point[2]), (0...1).contains(fx), (0...1).contains(fy),
                      let size = view?.bounds.size else { return "\(point[1]):\(point[2]) is not a point FX:FY, 0-1 each" }
                let q = CGPoint(x: fx * size.width, y: fy * size.height)
                switch controls.target(at: TouchPoint(x: Double(q.x), y: Double(q.y))) {
                case n?: fingers.append((-1 - i, q, q))
                case let other?: return "\(word) is under \(controls.targets[other].id), not on the pointer surface"
                case nil: return "\(word) is outside the safe area: no control takes it"
                }
                continue
            }
            let w = word.split(separator: ".", maxSplits: 1).map(String.init)
            guard let n = controls.targets.firstIndex(where: { $0.id == w[0] }) else {
                return "\(w[0]) is not a control of this layout (\(controls.targets.map(\.id).joined(separator: " ")))"
            }
            let t = controls.targets[n]
            let c = CGPoint(x: t.frame.center.x, y: t.frame.center.y)
            var to = c
            if w.count == 2 {
                let reach: Double
                switch t.kind {
                case .stick, .keyStick: reach = t.frame.width / 2
                case .dpad: reach = min(t.frame.width, t.frame.height) * 0.4
                case .look: reach = Self.lookDrag
                case .button: return "\(w[0]) is a button: it takes no direction"
                case .pointer, .tool, .key, .modifier: return "\(w[0]) takes no direction"
                }
                let d: (Double, Double)
                switch w[1] {
                case "up": d = (0, -1)
                case "down": d = (0, 1)
                case "left": d = (-1, 0)
                case "right": d = (1, 0)
                default: return "\(w[1]) is not up, down, left or right"
                }
                to = CGPoint(x: c.x + d.0 * reach, y: c.y + d.1 * reach)
            }
            // A d-pad finger lands where it points; a stick's lands at its centre, then moves.
            let at = { if case .dpad = t.kind { return to } else { return c } }()
            fingers.append((-1 - i, at, to))
        }
        for f in fingers {
            try UIDriver.checkpoint()
            DriverTouches.held.append(f.touch)
            guard began(f.touch, at: f.at) else {
                for g in fingers { ended(g.touch) }
                return "nothing took a finger at \(f.at)"
            }
        }
        for f in fingers where f.to != f.at { moved(f.touch, at: f.to) }
        for f in fingers where f.to != f.at {
            guard let n = controls.target(at: TouchPoint(x: Double(f.at.x), y: Double(f.at.y))),
                  case .look = controls.targets[n].kind else { continue }
            let dx = Double(f.to.x - f.at.x), dy = Double(f.to.y - f.at.y)
            HostIO.log("controls: driver drags \(controls.targets[n].id) \(Int(dx)),\(Int(dy)) pt: mouse "
                       + "\(Int(dx * controls.lookScale)),\(Int(dy * controls.lookScale)) counts")
        }
        let pad = PadMapping.values(controls.output.pad)
        HostIO.log("controls: driver holds \(controls.held.sorted().joined(separator: "+")) for \(ms) ms: "
                   + String(format: "buttons=0x%04x lt=%d rt=%d lx=%d ly=%d rx=%d ry=%d", pad.buttons, pad.leftTrigger,
                            pad.rightTrigger, pad.lx, pad.ly, pad.rx, pad.ry))
        try await UIDriver.pause(.milliseconds(ms))
        return nil
    }

    /// How far a driver's `look.<direction>` drags, in points.
    static let lookDrag = 100.0

    /// The driver's summary line.
    var summary: String {
        "drawn=\(drawn) layout=\(state.layout.rawValue) visible=\(state.visible) dpad=\(state.dpad.rawValue) "
            + "rightStick=\(state.rightStick.rawValue) "
            + "opacity=\(ControlsOpacity.label(state.opacity)) keyboard=\(keyboard ? "open" : "closed") "
            + "held=\(controls.held.sorted().joined(separator: "+")) "
            + "trackpad=\(controls.trackpad) tool=\(controls.tool?.rawValue ?? "none")"
    }
}
#endif
