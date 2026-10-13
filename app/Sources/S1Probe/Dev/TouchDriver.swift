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
// PlayportKit ControlLayout: playport view menu lt lb rt rb dpad leftStick
// rightStick y x b a in the Gamepad layout); a stick or the d-pad takes a
// direction after a dot (`dpad.right`, `leftStick.up`: the stick fully over,
// the d-pad near its edge). Every finger goes down together, stays `ms`
// milliseconds (200 by default, 10000 at most), and lifts together.

#if canImport(UIKit)
import Foundation
import HostIOKit
import PlayportKit
import UIKit

extension OnScreenControls {
    /// Presses `spec`; nil when it was pressed, else why not.
    func driverPress(_ spec: String) async -> String? {
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        var ms = 200
        if parts.count == 2 {
            guard let n = Int(parts[1]), (0...10_000).contains(n) else { return "\(parts[1]) is not a hold of 0-10000 ms" }
            ms = n
        }
        guard drawn else { return "the on-screen controls are not shown (\(summary))" }
        var fingers: [(touch: Int, at: CGPoint, to: CGPoint)] = []
        for (i, word) in parts[0].split(separator: "+").map(String.init).enumerated() {
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
                case .stick: reach = t.frame.width / 2
                case .dpad: reach = min(t.frame.width, t.frame.height) * 0.4
                case .button: return "\(w[0]) is a button: it takes no direction"
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
            guard began(f.touch, at: f.at) else {
                for g in fingers { ended(g.touch) }
                return "nothing took a finger at \(f.at)"
            }
        }
        for f in fingers where f.to != f.at { moved(f.touch, at: f.to) }
        let pad = PadMapping.values(controls.output.pad)
        HostIO.log("controls: driver holds \(controls.held.sorted().joined(separator: "+")) for \(ms) ms: "
                   + String(format: "buttons=0x%04x lt=%d rt=%d lx=%d ly=%d rx=%d ry=%d", pad.buttons, pad.leftTrigger,
                            pad.rightTrigger, pad.lx, pad.ly, pad.rx, pad.ry))
        try? await Task.sleep(for: .milliseconds(ms))
        for f in fingers { ended(f.touch) }
        return nil
    }

    /// The driver's summary line.
    var summary: String {
        "drawn=\(drawn) layout=\(state.layout.rawValue) visible=\(state.visible) "
            + "menuButtonOnly=\(state.menuButtonOnly) opacity=\(ControlsOpacity.label(state.opacity)) "
            + "held=\(controls.held.sorted().joined(separator: "+"))"
    }
}
#endif
