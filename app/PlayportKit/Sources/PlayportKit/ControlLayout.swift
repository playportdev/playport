// SPDX-License-Identifier: GPL-3.0-or-later
// On-screen control layouts (docs/plans/2026-10-09-touch-controls.md,
// "Touch layouts"; docs/design/2026-10-09-touch-controls/TouchGamepad.dc.html):
// a layout is a list of placed controls, each with an id the dev driver's
// `touch:` names, a kind, its actions (HostIOKit InputAction), a label and a
// behaviour. A control is placed by an anchor (a screen corner, an edge's
// middle or the centre), the offset of its centre from there and its size, in
// points, so one layout fits every iPhone. A saved layout carries `version`;
// one newer than this build reads is refused, not guessed at.
//
// `targets` turns a layout into what HostIOKit's TouchControls hit-tests, at
// the view's size.

import Foundation
import HostIOKit

public enum ControlAnchor: String, Codable, CaseIterable, Sendable {
    case topLeading, top, topTrailing, leading, center, trailing, bottomLeading, bottom, bottomTrailing

    /// The anchor's point in a view of width × height.
    public func point(width: Double, height: Double) -> (x: Double, y: Double) {
        let x: Double = switch self {
        case .topLeading, .leading, .bottomLeading: 0
        case .top, .center, .bottom: width / 2
        case .topTrailing, .trailing, .bottomTrailing: width
        }
        let y: Double = switch self {
        case .topLeading, .top, .topTrailing: 0
        case .leading, .center, .trailing: height / 2
        case .bottomLeading, .bottom, .bottomTrailing: height
        }
        return (x, y)
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

/// A rectangle as fractions of the view (0...1).
public struct ControlZone: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// The Gamepad layout's floating-stick zone.
    public static let lowerLeftThird = ControlZone(x: 0, y: 1.0 / 3, width: 1.0 / 3, height: 2.0 / 3)
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

    /// Where it is in a view of width × height.
    public func frame(width w: Double, height h: Double) -> TouchRect {
        let a = anchor.point(width: w, height: h)
        return TouchRect(x: a.x + x - width / 2, y: a.y + y - height / 2, width: width, height: height)
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
        if floatingZone != nil, kind != .stick { return "\(id): only a stick floats" }
        return nil
    }
}

public struct ControlLayout: Codable, Equatable, Sendable {
    /// The layout format this build writes and reads.
    public static let currentVersion = 1

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
        guard (1...Self.currentVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c,
                                                   debugDescription: "layout version \(version); this build reads 1...\(Self.currentVersion)")
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

    /// What TouchControls hit-tests in a view of width × height, in the layout's order.
    public func targets(width: Double, height: Double) -> [TouchTarget] {
        controls.map { c in
            let frame = c.frame(width: width, height: height)
            let kind: TouchTarget.Kind
            switch c.kind {
            case .button:
                kind = .button(c.actions[0], c.behaviour)
            case .stick:
                guard case .pad(let stick) = c.actions[0] else { fatalError("checked by problem") }
                let zone = c.floatingZone.map {
                    TouchRect(x: $0.x * width, y: $0.y * height, width: $0.width * width, height: $0.height * height)
                }
                kind = .stick(stick, zone: zone)
            case .dpad:
                kind = .dpad(c.actions)
            }
            return TouchTarget(id: c.id, kind: kind, frame: frame)
        }
    }

    /// The Gamepad layout (TouchGamepad.dc.html, drawn at 874 × 402 points): the
    /// Playport button at the top centre between View and Menu, the triggers
    /// and shoulders at the top corners, the d-pad at the left, a floating left
    /// stick in the lower left third, the right stick and A B X Y at the lower right.
    public static let gamepad = ControlLayout(controls: [
        Control(id: "playport", actions: [.playport(.menu)], label: "Playport", anchor: .top, x: 0, y: 21, width: 100, height: 26),
        Control(id: "view", actions: [.pad(.back)], label: "⧉", anchor: .top, x: -83, y: 21, width: 48, height: 26),
        Control(id: "menu", actions: [.pad(.start)], label: "≡", anchor: .top, x: 83, y: 21, width: 48, height: 26),
        Control(id: "lt", actions: [.pad(.lt)], label: "LT", anchor: .topLeading, x: 77, y: 99, width: 66, height: 34),
        Control(id: "lb", actions: [.pad(.lb)], label: "LB", anchor: .topLeading, x: 77, y: 141, width: 66, height: 34),
        Control(id: "rt", actions: [.pad(.rt)], label: "RT", anchor: .topTrailing, x: -77, y: 99, width: 66, height: 34),
        Control(id: "rb", actions: [.pad(.rb)], label: "RB", anchor: .topTrailing, x: -77, y: 141, width: 66, height: 34),
        Control(id: "dpad", kind: .dpad, actions: [.pad(.up), .pad(.down), .pad(.left), .pad(.right)], label: "D-pad",
                anchor: .leading, x: 178, y: 13, width: 92, height: 92),
        Control(id: "leftStick", kind: .stick, actions: [.pad(.leftStick)], label: "Left stick", anchor: .bottomLeading,
                x: 110, y: -88, width: 116, height: 116, floatingZone: .lowerLeftThird),
        Control(id: "rightStick", kind: .stick, actions: [.pad(.rightStick)], label: "Right stick", anchor: .bottomTrailing,
                x: -276, y: -72, width: 92, height: 92),
        Control(id: "y", actions: [.pad(.y)], label: "Y", anchor: .bottomTrailing, x: -126, y: -164, width: 50, height: 50),
        Control(id: "x", actions: [.pad(.x)], label: "X", anchor: .bottomTrailing, x: -178, y: -112, width: 50, height: 50),
        Control(id: "b", actions: [.pad(.b)], label: "B", anchor: .bottomTrailing, x: -74, y: -112, width: 50, height: 50),
        Control(id: "a", actions: [.pad(.a)], label: "A", anchor: .bottomTrailing, x: -126, y: -60, width: 50, height: 50),
    ])

    /// The Playport button alone (the Gamepad layout's): what shows with no
    /// controller when a game's layout is Off, so the in-game menu stays in reach.
    public static let menuButton = ControlLayout(controls: gamepad.controls.filter { $0.id == "playport" })
}
