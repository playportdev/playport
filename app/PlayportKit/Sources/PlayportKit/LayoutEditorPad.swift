// SPDX-License-Identifier: GPL-3.0-or-later
// The layout editor by controller (LayoutEditor.dc.html; PLA-13,
// phase 5): what each press does to the LayoutEditor, and what the view does with the rest.
//
// - On the canvas the selection is the ring: LB and RB ring the controls in
//   turn (round at the ends), the directions move the ringed control one grid
//   step (each press one undo step, snapped as a drag is), A on it opens the
//   panel (the bar and the inspector), B is Done.
// - In the panel the directions and A are the focus ring's (PadFocus in the
//   app, FocusMove), B back to the canvas; LB and RB still ring another control.
// - Anywhere: X Add, Y Reset, View undo, ≡ redo.
//
// A handle at the selected control's corner resizes it as a pinch does, by its
// distance from the centre (`handleScale`).

import Foundation
import HostIOKit

/// Where the controller's presses go in the layout editor.
public enum LayoutEditorFocus: Equatable, Sendable {
    /// The controls: the ringed one is the selection.
    case canvas
    /// The bar and the inspector, through the focus ring.
    case panel
}

/// What the view does after a press (the editor itself already changed).
public enum LayoutEditorPadEffect: Equatable, Sendable {
    case none
    /// The panel opened: ring its first item.
    case openPanel
    /// Move the focus ring.
    case moveRing(FocusDirection)
    /// The ringed item's action.
    case activate
    /// Add's list.
    case add
    /// Save and close.
    case done
}

public struct LayoutEditorPad: Equatable, Sendable {
    public var focus: LayoutEditorFocus

    public init(focus: LayoutEditorFocus = .canvas) { self.focus = focus }

    public mutating func press(_ b: NavButton, editor e: inout LayoutEditor) -> LayoutEditorPadEffect {
        switch b {
        case .lb, .rb:
            Self.ring(&e, by: b == .lb ? -1 : 1)
            return .none
        case .x:
            return .add
        case .y:
            e.reset()
            return .none
        case .view:
            e.undo()
            return .none
        case .menu:
            e.redo()
            return .none
        default:
            break
        }
        if focus == .panel {
            switch b {
            case .up: return .moveRing(.up)
            case .down: return .moveRing(.down)
            case .left: return .moveRing(.left)
            case .right: return .moveRing(.right)
            case .a: return .activate
            case .b:
                focus = .canvas
                return .none
            default: return .none
            }
        }
        if b == .b { return .done }
        guard let id = e.selection else {
            // Nothing ringed: a direction or A rings the first control.
            Self.ring(&e, by: 1)
            return .none
        }
        switch b {
        case .a:
            focus = .panel
            return .openPanel
        case .up: Self.nudge(&e, id, dx: 0, dy: -LayoutEditor.grid)
        case .down: Self.nudge(&e, id, dx: 0, dy: LayoutEditor.grid)
        case .left: Self.nudge(&e, id, dx: -LayoutEditor.grid, dy: 0)
        case .right: Self.nudge(&e, id, dx: LayoutEditor.grid, dy: 0)
        default: break
        }
        return .none
    }

    /// The control `by` places from the selection, in the layout's order, going round; with
    /// nothing selected the first (RB) or the last (LB).
    static func ring(_ e: inout LayoutEditor, by: Int) {
        let ids = e.layout.controls.map(\.id)
        guard !ids.isEmpty else { return }
        guard let now = e.selection.flatMap(ids.firstIndex(of:)) else { return e.select(by < 0 ? ids.last : ids.first) }
        e.select(ids[((now + by) % ids.count + ids.count) % ids.count])
    }

    /// One grid step as a whole drag (snapped as one, one undo step).
    static func nudge(_ e: inout LayoutEditor, _ id: String, dx: Double, dy: Double) {
        e.drag(id, dx: dx, dy: dy)
        e.endGesture()
    }

    /// A corner handle dragged from `from` to `to`: the pinch scale, the distance from the
    /// control's centre now over the distance when it was grabbed (1 for a grab on the centre).
    public static func handleScale(centre c: TouchPoint, from: TouchPoint, to: TouchPoint) -> Double {
        let d0 = hypot(from.x - c.x, from.y - c.y)
        guard d0 > 0 else { return 1 }
        return hypot(to.x - c.x, to.y - c.y) / d0
    }
}
