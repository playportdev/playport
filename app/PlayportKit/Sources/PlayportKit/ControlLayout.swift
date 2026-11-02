// SPDX-License-Identifier: GPL-3.0-or-later
// On-screen control layouts (PLA-13,
// "Touch layouts"; docs/design/2026-10-09-touch-controls/TouchGamepad.dc.html,
// TouchKeyboardMouse.dc.html, TouchPointer.dc.html): a layout is a list of
// placed controls, each with an id the dev driver's `touch:` names, a kind,
// its actions (HostIOKit InputAction), a label and a behaviour. A control is
// placed in the view's safe area (the screen less the notch or Dynamic Island
// and the home indicator, on whichever side they are) by an anchor (a corner,
// an edge's middle or the centre), the offset of its centre from there and its
// size, in points, so one layout fits every iPhone in either landscape
// orientation; one larger than the safe area is cut to it, and one that would
// reach out of it is moved back in. A floating stick's zone is a corner of the
// safe area, moved by an offset (0 when left out, so a layout saved without one
// reads the same).
//
// The kinds (ControlKind) and what TouchControls makes of them:
//
// - `button`: one action, held, toggled or repeated (`behaviour`).
// - `stick`: `pad:leftStick` or `pad:rightStick`, or four actions (up, down,
//   left, right) pressed as it leans: the Keyboard & mouse layout's W A S D
//   (TouchTarget.Kind.keyStick). Either may float in a zone.
// - `dpad`: four actions, up, down, left, right.
// - `lookArea`: `mouse:move`; a drag on it moves the mouse. Under every other
//   control, so with the size of the screen it is "anywhere free".
// - `pointer`: `mouse:left`; Point & click's surface, tap to click or a
//   trackpad, with a magnifier while a finger is down. Under every other control.
// - `tool`: no action; a side-bar tool (`tool`, HostIOKit PointerTool) that
//   changes what the pointer surface does: right click, hover, scroll, or the
//   trackpad mode.
//
// The touch keyboard is a button with `playport:keyboard`. The presets:
// `gamepad(dpad:rightStick:)`, `keyboardMouse()` and `pointClick()`
// (OnScreenLayout, Controls.swift).
//
// A saved layout carries `version`; any other than this build's is refused, and
// the caller uses a preset instead (no build saved a version 1 or 2 layout:
// 2 placed controls in the safe area, 3 added phase 4's kinds).
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
    /// One stick action (`pad:leftStick`, `pad:rightStick`), or four actions
    /// pressed as it leans: up, down, left, right (W S A D).
    case stick
    /// Four actions: up, down, left, right.
    case dpad
    /// `mouse:move`: a finger dragged on it moves the mouse (Keyboard & mouse's look area).
    case lookArea
    /// `mouse:left`: Point & click's pointer surface.
    case pointer
    /// No action: a side-bar tool for the pointer surface (`Control.tool`).
    case tool
}

/// Where a floating stick starts: a width × height rectangle, in points, in a
/// corner (or at an edge's middle) of the safe area, moved by the offset `x`, `y`
/// (+y down; 0 when left out) and kept inside the safe area.
public struct ControlZone: Codable, Equatable, Sendable {
    public var anchor: ControlAnchor
    public var x: Double, y: Double
    public var width: Double, height: Double
    public init(anchor: ControlAnchor, x: Double = 0, y: Double = 0, width: Double, height: Double) {
        self.anchor = anchor; self.x = x; self.y = y; self.width = width; self.height = height
    }

    enum CodingKeys: String, CodingKey { case anchor, x, y, width, height }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anchor = try c.decode(ControlAnchor.self, forKey: .anchor)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
    }

    /// Where it is in `area`, cut to it.
    public func frame(in area: TouchRect) -> TouchRect {
        var r = anchor.rect(width: min(width, area.width), height: min(height, area.height), in: area)
        r.x += x
        r.y += y
        return r.kept(in: area)
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
    /// A `tool` control's tool.
    public var tool: PointerTool?

    public init(id: String, kind: ControlKind = .button, actions: [InputAction], label: String,
                behaviour: TouchBehaviour = .hold, anchor: ControlAnchor, x: Double, y: Double,
                width: Double, height: Double, floatingZone: ControlZone? = nil, tool: PointerTool? = nil) {
        self.id = id; self.kind = kind; self.actions = actions; self.label = label; self.behaviour = behaviour
        self.anchor = anchor; self.x = x; self.y = y; self.width = width; self.height = height
        self.floatingZone = floatingZone; self.tool = tool
    }

    enum CodingKeys: String, CodingKey { case id, kind, actions, label, behaviour, anchor, x, y, width, height, floatingZone, tool }

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
        tool = try c.decodeIfPresent(PointerTool.self, forKey: .tool)
    }

    /// Where it is in a view of width × height with these safe-area insets: cut
    /// to the safe area and kept inside it.
    public func frame(width w: Double, height h: Double, insets: ControlInsets = .zero) -> TouchRect {
        let area = insets.area(width: w, height: h)
        let a = anchor.point(in: area)
        let cw = min(width, area.width), ch = min(height, area.height)
        return TouchRect(x: a.x + x - cw / 2, y: a.y + y - ch / 2, width: cw, height: ch).kept(in: area)
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
            let pad = actions.count == 1 && { if case .pad(let p) = actions[0] { p.isStick } else { false } }()
            let four = actions.count == 4 && !actions.contains { if case .pad(let p) = $0 { p.isStick } else { false } }
            guard pad || four else {
                return "\(id): a stick's action is pad:leftStick or pad:rightStick, or four: up, down, left, right"
            }
        case .dpad:
            guard actions.count == 4 else { return "\(id): a d-pad has four actions: up, down, left, right" }
        case .lookArea:
            guard actions == [.mouse(.move)] else { return "\(id): a look area's action is mouse:move" }
        case .pointer:
            guard actions == [.mouse(.left)] else { return "\(id): a pointer surface's action is mouse:left" }
        case .tool:
            guard tool != nil, actions.isEmpty else { return "\(id): a tool has a tool and no action" }
        }
        if tool != nil, kind != .tool { return "\(id): only a tool has a tool" }
        if let z = floatingZone {
            guard kind == .stick else { return "\(id): only a stick floats" }
            guard z.width > 0, z.height > 0, z.width.isFinite, z.height.isFinite, z.x.isFinite, z.y.isFinite else {
                return "\(id): a zone's size must be more than 0"
            }
        }
        return nil
    }
}

public struct ControlLayout: Codable, Equatable, Sendable {
    /// The layout format this build writes and reads.
    public static let currentVersion = 3

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
        // Version 2 placed controls in the safe area and floating zones in points; 3 added phase 4's kinds.
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
                let zone = c.floatingZone?.frame(in: area)
                if case .pad(let stick) = c.actions[0] { kind = .stick(stick, zone: zone) } else { kind = .keyStick(c.actions, zone: zone) }
            case .dpad:
                kind = .dpad(c.actions)
            case .lookArea:
                kind = .look
            case .pointer:
                kind = .pointer(view: TouchRect(x: 0, y: 0, width: width, height: height))
            case .tool:
                guard let tool = c.tool else { fatalError("checked by problem") }
                kind = .tool(tool)
            }
            return TouchTarget(id: c.id, kind: kind, frame: frame)
        }
    }

    /// The Gamepad layout, in the safe area, placed for every iPhone from the
    /// 4.7-inch screen and the 5.4-inch one's 712 × 354 safe area to a 6.9-inch
    /// one (ControlLayoutTests checks each with every option):
    ///
    /// - LT over LB in the top left corner with View beside LT; Menu, RT and RB
    ///   mirrored at the right.
    /// - The left stick floats in a zone in the lower left corner; the d-pad
    ///   (`dpad` On) is centred above it.
    /// - A/B/X/Y in the lower right corner, centred where the right zone's middle
    ///   is. The right stick (`rightStick`) floats in a zone centred on them: with
    ///   Below the zone takes the corner and A/B/X/Y move up over it; with Above
    ///   the zone is over them.
    /// - Each zone is clear of every other control by `gap`, so no touch near a
    ///   zone's edge is both's.
    /// - The d-pad and A/B/X/Y are the same size (`cluster` square): the d-pad's
    ///   arms and each face button are drawn alike (TouchControlsView), and the
    ///   four face buttons tile the cluster's middle row and column, each hit
    ///   over its own `cluster / 3` square. 126 is the largest cluster the
    ///   5.4-inch safe height leaves between the left zone and LB with the d-pad on;
    ///   there the Above zone, 114 tall, keeps its gap to RB.
    public static func gamepad(dpad: OnScreenDpad = .off, rightStick: OnScreenRightStick = .off) -> ControlLayout {
        let zoneWidth = 210.0, zoneHeight = 126.0, aboveZoneHeight = 114.0, gap = 12.0, cluster = 126.0
        let face = cluster / 3
        let middle = zoneWidth / 2
        // A/B/X/Y's centre, from the lower right corner.
        let faceY = rightStick == .below ? -(zoneHeight + gap + cluster / 2) : -cluster / 2
        var controls = [
            Control(id: "view", actions: [.pad(.back)], label: "⧉", anchor: .topLeading, x: 98, y: 22, width: 44, height: 30),
            Control(id: "menu", actions: [.pad(.start)], label: "≡", anchor: .topTrailing, x: -98, y: 22, width: 44, height: 30),
            Control(id: "lt", actions: [.pad(.lt)], label: "LT", anchor: .topLeading, x: 38, y: 24, width: 64, height: 40),
            Control(id: "lb", actions: [.pad(.lb)], label: "LB", anchor: .topLeading, x: 38, y: 70, width: 64, height: 40),
            Control(id: "rt", actions: [.pad(.rt)], label: "RT", anchor: .topTrailing, x: -38, y: 24, width: 64, height: 40),
            Control(id: "rb", actions: [.pad(.rb)], label: "RB", anchor: .topTrailing, x: -38, y: 70, width: 64, height: 40),
        ]
        if dpad == .on {
            controls.append(Control(id: "dpad", kind: .dpad, actions: [.pad(.up), .pad(.down), .pad(.left), .pad(.right)],
                                    label: "D-pad", anchor: .bottomLeading, x: middle, y: -(zoneHeight + gap + cluster / 2),
                                    width: cluster, height: cluster))
        }
        controls.append(Control(id: "leftStick", kind: .stick, actions: [.pad(.leftStick)], label: "Left stick",
                                anchor: .bottomLeading, x: middle, y: -zoneHeight / 2, width: 104, height: 104,
                                floatingZone: ControlZone(anchor: .bottomLeading, width: zoneWidth, height: zoneHeight)))
        switch rightStick {
        case .off:
            break
        case .below:
            controls.append(Control(id: "rightStick", kind: .stick, actions: [.pad(.rightStick)], label: "Right stick",
                                    anchor: .bottomTrailing, x: -middle, y: -zoneHeight / 2, width: 104, height: 104,
                                    floatingZone: ControlZone(anchor: .bottomTrailing, width: zoneWidth, height: zoneHeight)))
        case .above:
            let lift = cluster + gap
            controls.append(Control(id: "rightStick", kind: .stick, actions: [.pad(.rightStick)], label: "Right stick",
                                    anchor: .bottomTrailing, x: -middle, y: -(lift + aboveZoneHeight / 2), width: 104, height: 104,
                                    floatingZone: ControlZone(anchor: .bottomTrailing, y: -lift, width: zoneWidth,
                                                              height: aboveZoneHeight)))
        }
        controls += [
            Control(id: "y", actions: [.pad(.y)], label: "Y", anchor: .bottomTrailing, x: -middle, y: faceY - face,
                    width: face, height: face),
            Control(id: "x", actions: [.pad(.x)], label: "X", anchor: .bottomTrailing, x: -middle - face, y: faceY,
                    width: face, height: face),
            Control(id: "b", actions: [.pad(.b)], label: "B", anchor: .bottomTrailing, x: -middle + face, y: faceY,
                    width: face, height: face),
            Control(id: "a", actions: [.pad(.a)], label: "A", anchor: .bottomTrailing, x: -middle, y: faceY + face,
                    width: face, height: face),
        ]
        return ControlLayout(controls: controls)
    }

    /// A surface's size: larger than any safe area, so it is cut to the whole of it.
    static let wholeArea = 4000.0

    /// The Keyboard & mouse layout (TouchKeyboardMouse.dc.html), in the safe
    /// area of every iPhone (TouchLayoutsTests checks each):
    ///
    /// - The look area fills the safe area under everything: a drag anywhere
    ///   free looks. There is no Aim button: gyro aim aims by itself.
    /// - Esc, Tab and the touch keyboard's key in the top left corner; 1–4 in the top right.
    /// - The W A S D stick floats in the Gamepad layout's left zone.
    /// - Fire (the left button) in the lower right corner, with Use (E),
    ///   Reload (R) and Jump (Space) around it, under the right thumb.
    public static func keyboardMouse() -> ControlLayout {
        let zoneWidth = 210.0, zoneHeight = 126.0
        var controls = [
            Control(id: "look", kind: .lookArea, actions: [.mouse(.move)], label: "Look", anchor: .center, x: 0, y: 0,
                    width: wholeArea, height: wholeArea),
            Control(id: "esc", actions: [.key(0x1B, [])], label: "Esc", anchor: .topLeading, x: 30, y: 22, width: 52, height: 30),
            Control(id: "tab", actions: [.key(0x09, [])], label: "Tab", anchor: .topLeading, x: 88, y: 22, width: 52, height: 30),
            Control(id: "keyboard", actions: [.playport(.keyboard)], label: "⌨", anchor: .topLeading, x: 142, y: 22,
                    width: 44, height: 30),
        ]
        for n in 1...4 {
            controls.append(Control(id: "\(n)", actions: [.key(UInt8(0x30 + n), [])], label: "\(n)", anchor: .topTrailing,
                                    x: -26 - Double(4 - n) * 40, y: 22, width: 36, height: 30))
        }
        controls += [
            Control(id: "move", kind: .stick, actions: [.key(0x57, []), .key(0x53, []), .key(0x41, []), .key(0x44, [])],
                    label: "WASD", anchor: .bottomLeading, x: zoneWidth / 2, y: -zoneHeight / 2, width: 104, height: 104,
                    floatingZone: ControlZone(anchor: .bottomLeading, width: zoneWidth, height: zoneHeight)),
            Control(id: "use", actions: [.key(0x45, [])], label: "Use", anchor: .bottomTrailing, x: -150, y: -83, width: 50, height: 50),
            Control(id: "reload", actions: [.key(0x52, [])], label: "Reload", anchor: .bottomTrailing, x: -126, y: -137,
                    width: 46, height: 46),
            Control(id: "jump", actions: [.key(0x20, [])], label: "Jump", anchor: .bottomTrailing, x: -71, y: -166, width: 56, height: 56),
            Control(id: "fire", actions: [.mouse(.left)], label: "Fire", anchor: .bottomTrailing, x: -58, y: -75, width: 76, height: 76),
        ]
        return ControlLayout(controls: controls)
    }

    /// The Point & click layout (TouchPointer.dc.html): the pointer surface fills
    /// the safe area under everything; the Tap to click / Trackpad switch in the
    /// top right corner; the side bar at the left edge's middle, top to bottom:
    /// right click, hover, scroll, the touch keyboard and Esc.
    public static func pointClick() -> ControlLayout {
        let side = 44.0, step = 52.0
        func bar(_ i: Int, _ id: String, _ label: String, tool: PointerTool? = nil, actions: [InputAction] = []) -> Control {
            Control(id: id, kind: tool == nil ? .button : .tool, actions: actions, label: label, anchor: .leading, x: 30,
                    y: Double(i - 2) * step, width: side, height: side, tool: tool)
        }
        return ControlLayout(controls: [
            Control(id: "pointer", kind: .pointer, actions: [.mouse(.left)], label: "Pointer", anchor: .center, x: 0, y: 0,
                    width: wholeArea, height: wholeArea),
            Control(id: "mode", kind: .tool, actions: [], label: "Trackpad", anchor: .topTrailing, x: -105, y: 22,
                    width: 210, height: 32, tool: .trackpad),
            bar(0, "rightClick", "Right", tool: .rightClick),
            bar(1, "hover", "Hover", tool: .hover),
            bar(2, "scroll", "Scroll", tool: .scroll),
            bar(3, "keyboard", "Keys", actions: [.playport(.keyboard)]),
            bar(4, "esc", "Esc", actions: [.key(0x1B, [])]),
        ])
    }
}
