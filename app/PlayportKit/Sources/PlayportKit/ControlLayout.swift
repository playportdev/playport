// SPDX-License-Identifier: GPL-3.0-or-later
// On-screen control layouts (docs/plans/2026-10-09-touch-controls.md,
// "Touch layouts"; docs/design/2026-10-09-touch-controls/TouchGamepad.dc.html):
// a layout is a list of placed controls, each with an id the dev driver's
// `touch:` names, a kind, its actions (HostIOKit InputAction), a label and a
// behaviour. A control is placed in the view's safe area (the screen less the
// notch or Dynamic Island and the home indicator, on whichever side they are)
// by an anchor (a corner, an edge's middle or the centre), the offset of its
// centre from there and its size, in points, so one layout fits every iPhone
// in either landscape orientation; one that would reach out of the safe area
// is moved back in. A floating stick's zone is a corner of the safe area.
// A saved layout carries `version`; any other than this build's is refused, and
// the caller uses a preset instead (no build saved a version 1 layout).
//
// `targets` turns a layout into what HostIOKit's TouchControls hit-tests, at
// the view's size and safe-area insets.

import Foundation
import HostIOKit

/// The view's safe-area insets, in points.
public struct ControlInsets: Equatable, Sendable {
    public var top: Double, left: Double, bottom: Double, right: Double
    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }

    public static let zero = ControlInsets()

    /// The safe area of a view of width × height.
    public func area(width: Double, height: Double) -> TouchRect {
        TouchRect(x: left, y: top, width: max(0, width - left - right), height: max(0, height - top - bottom))
    }
}

public enum ControlAnchor: String, Codable, CaseIterable, Sendable {
    case topLeading, top, topTrailing, leading, center, trailing, bottomLeading, bottom, bottomTrailing

    /// The anchor's point in `area`.
    public func point(in area: TouchRect) -> (x: Double, y: Double) {
        let x: Double = switch self {
        case .topLeading, .leading, .bottomLeading: area.x
        case .top, .center, .bottom: area.x + area.width / 2
        case .topTrailing, .trailing, .bottomTrailing: area.x + area.width
        }
        let y: Double = switch self {
        case .topLeading, .top, .topTrailing: area.y
        case .leading, .center, .trailing: area.y + area.height / 2
        case .bottomLeading, .bottom, .bottomTrailing: area.y + area.height
        }
        return (x, y)
    }

    /// A width × height rectangle in `area`, its anchor-side edges on the anchor
    /// (a corner's two edges; an edge's middle, centred along it).
    func rect(width: Double, height: Double, in area: TouchRect) -> TouchRect {
        let p = point(in: area)
        let x: Double = switch self {
        case .topLeading, .leading, .bottomLeading: p.x
        case .top, .center, .bottom: p.x - width / 2
        case .topTrailing, .trailing, .bottomTrailing: p.x - width
        }
        let y: Double = switch self {
        case .topLeading, .top, .topTrailing: p.y
        case .leading, .center, .trailing: p.y - height / 2
        case .bottomLeading, .bottom, .bottomTrailing: p.y - height
        }
        return TouchRect(x: x, y: y, width: width, height: height)
    }
}

extension TouchRect {
    /// Moved the least to lie inside `area` (left and top kept when it is the larger).
    func kept(in area: TouchRect) -> TouchRect {
        var r = self
        r.x = max(area.x, min(r.x, area.x + area.width - r.width))
        r.y = max(area.y, min(r.y, area.y + area.height - r.height))
        return r
    }
}

public enum ControlKind: String, Codable, CaseIterable, Sendable {
    /// One action.
    case button
    /// One stick action (`pad:leftStick`, `pad:rightStick`).
    case stick
    /// Four actions: up, down, left, right.
    case dpad
}

/// Where a floating stick starts: a width × height rectangle, in points, in a
/// corner (or at an edge's middle) of the safe area.
public struct ControlZone: Codable, Equatable, Sendable {
    public var anchor: ControlAnchor
    public var width: Double, height: Double
    public init(anchor: ControlAnchor, width: Double, height: Double) {
        self.anchor = anchor; self.width = width; self.height = height
    }

    /// Where it is in `area`, cut to it.
    public func frame(in area: TouchRect) -> TouchRect {
        anchor.rect(width: min(width, area.width), height: min(height, area.height), in: area)
    }
}

public struct Control: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: ControlKind
    public var actions: [InputAction]
    public var label: String
    public var behaviour: TouchBehaviour
    public var anchor: ControlAnchor
    /// The centre's offset from the anchor, in points (+y down).
    public var x: Double, y: Double
    public var width: Double, height: Double
    /// A stick that starts where the thumb lands anywhere in this part of the screen.
    public var floatingZone: ControlZone?

    public init(id: String, kind: ControlKind = .button, actions: [InputAction], label: String,
                behaviour: TouchBehaviour = .hold, anchor: ControlAnchor, x: Double, y: Double,
                width: Double, height: Double, floatingZone: ControlZone? = nil) {
        self.id = id; self.kind = kind; self.actions = actions; self.label = label; self.behaviour = behaviour
        self.anchor = anchor; self.x = x; self.y = y; self.width = width; self.height = height
        self.floatingZone = floatingZone
    }

    enum CodingKeys: String, CodingKey { case id, kind, actions, label, behaviour, anchor, x, y, width, height, floatingZone }

    /// `label` and `behaviour` may be left out (the id, hold).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(ControlKind.self, forKey: .kind) ?? .button
        actions = try c.decode([InputAction].self, forKey: .actions)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        behaviour = try c.decodeIfPresent(TouchBehaviour.self, forKey: .behaviour) ?? .hold
        anchor = try c.decode(ControlAnchor.self, forKey: .anchor)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        floatingZone = try c.decodeIfPresent(ControlZone.self, forKey: .floatingZone)
    }

    /// Where it is in a view of width × height with these safe-area insets: kept inside the safe area.
    public func frame(width w: Double, height h: Double, insets: ControlInsets = .zero) -> TouchRect {
        let area = insets.area(width: w, height: h)
        let a = anchor.point(in: area)
        return TouchRect(x: a.x + x - width / 2, y: a.y + y - height / 2, width: width, height: height).kept(in: area)
    }

    /// Why it cannot be used, nil when it can.
    var problem: String? {
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return "control id \"\(id)\" is not letters, digits, - and _"
        }
        guard width > 0, height > 0, width.isFinite, height.isFinite, x.isFinite, y.isFinite else {
            return "\(id): a size must be more than 0"
        }
        switch kind {
        case .button:
            guard actions.count == 1 else { return "\(id): a button has one action" }
            if case .pad(let p) = actions[0], p.isStick { return "\(id): a stick action needs a stick" }
        case .stick:
            guard actions.count == 1, case .pad(let p) = actions[0], p.isStick else {
                return "\(id): a stick's action is pad:leftStick or pad:rightStick"
            }
        case .dpad:
            guard actions.count == 4 else { return "\(id): a d-pad has four actions: up, down, left, right" }
        }
        if let z = floatingZone {
            guard kind == .stick else { return "\(id): only a stick floats" }
            guard z.width > 0, z.height > 0, z.width.isFinite, z.height.isFinite else { return "\(id): a zone's size must be more than 0" }
        }
        return nil
    }
}

public struct ControlLayout: Codable, Equatable, Sendable {
    /// The layout format this build writes and reads.
    public static let currentVersion = 2

    public var version: Int
    public var controls: [Control]

    public init(controls: [Control]) {
        version = Self.currentVersion
        self.controls = controls
    }

    public struct Unusable: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        // Version 2 placed controls in the safe area and floating zones in points.
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c,
                                                   debugDescription: "layout version \(version); this build reads \(Self.currentVersion)")
        }
        controls = try c.decode([Control].self, forKey: .controls)
        if let p = problem { throw DecodingError.dataCorruptedError(forKey: .controls, in: c, debugDescription: p) }
    }

    /// Why the layout cannot be used: a control's problem, or two controls with one id.
    public var problem: String? {
        if let p = controls.lazy.compactMap(\.problem).first { return p }
        var seen = Set<String>()
        for c in controls where !seen.insert(c.id).inserted { return "two controls are \(c.id)" }
        return nil
    }

    public func control(_ id: String) -> Control? { controls.first { $0.id == id } }

    /// What TouchControls hit-tests in a view of width × height with these
    /// safe-area insets, in the layout's order.
    public func targets(width: Double, height: Double, insets: ControlInsets = .zero) -> [TouchTarget] {
        let area = insets.area(width: width, height: height)
        return controls.map { c in
            let frame = c.frame(width: width, height: height, insets: insets)
            let kind: TouchTarget.Kind
            switch c.kind {
            case .button:
                kind = .button(c.actions[0], c.behaviour)
            case .stick:
                guard case .pad(let stick) = c.actions[0] else { fatalError("checked by problem") }
                kind = .stick(stick, zone: c.floatingZone?.frame(in: area))
            case .dpad:
                kind = .dpad(c.actions)
            }
            return TouchTarget(id: c.id, kind: kind, frame: frame)
        }
    }

    /// The Gamepad layout, in the safe area: LT over LB in the top left corner
    /// with View beside LT, Menu, RT and RB mirrored at the right; a floating
    /// stick in a zone in each lower corner, the left stick at the left, the
    /// right stick at the right; the d-pad above the left zone and A B X Y above
    /// the right one, inward of the corners, with a 12-point gap to the zones so
    /// neither takes the other's touches. The d-pad and the face buttons are hit
    /// over a larger square than they are drawn. Placed for a 750 × 381 safe area
    /// (a 6.3-inch iPhone in landscape); ControlLayoutTests checks it from the
    /// 4.7-inch screen and the 5.4-inch one's 712 × 354 safe area to a 6.9-inch one.
    public static let gamepad = ControlLayout(controls: [
        Control(id: "view", actions: [.pad(.back)], label: "⧉", anchor: .topLeading, x: 98, y: 22, width: 44, height: 30),
        Control(id: "menu", actions: [.pad(.start)], label: "≡", anchor: .topTrailing, x: -98, y: 22, width: 44, height: 30),
        Control(id: "lt", actions: [.pad(.lt)], label: "LT", anchor: .topLeading, x: 38, y: 24, width: 64, height: 40),
        Control(id: "lb", actions: [.pad(.lb)], label: "LB", anchor: .topLeading, x: 38, y: 70, width: 64, height: 40),
        Control(id: "rt", actions: [.pad(.rt)], label: "RT", anchor: .topTrailing, x: -38, y: 24, width: 64, height: 40),
        Control(id: "rb", actions: [.pad(.rb)], label: "RB", anchor: .topTrailing, x: -38, y: 70, width: 64, height: 40),
        Control(id: "dpad", kind: .dpad, actions: [.pad(.up), .pad(.down), .pad(.left), .pad(.right)], label: "D-pad",
                anchor: .bottomLeading, x: 154, y: -210, width: 116, height: 116),
        Control(id: "leftStick", kind: .stick, actions: [.pad(.leftStick)], label: "Left stick", anchor: .bottomLeading,
                x: 105, y: -70, width: 104, height: 104, floatingZone: ControlZone(anchor: .bottomLeading, width: 210, height: 140)),
        Control(id: "rightStick", kind: .stick, actions: [.pad(.rightStick)], label: "Right stick", anchor: .bottomTrailing,
                x: -105, y: -70, width: 104, height: 104, floatingZone: ControlZone(anchor: .bottomTrailing, width: 210, height: 140)),
        Control(id: "y", actions: [.pad(.y)], label: "Y", anchor: .bottomTrailing, x: -156, y: -282, width: 52, height: 52),
        Control(id: "x", actions: [.pad(.x)], label: "X", anchor: .bottomTrailing, x: -208, y: -230, width: 52, height: 52),
        Control(id: "b", actions: [.pad(.b)], label: "B", anchor: .bottomTrailing, x: -104, y: -230, width: 52, height: 52),
        Control(id: "a", actions: [.pad(.a)], label: "A", anchor: .bottomTrailing, x: -156, y: -178, width: 52, height: 52),
    ])
}
