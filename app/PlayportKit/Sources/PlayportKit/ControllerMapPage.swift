// SPDX-License-Identifier: GPL-3.0-or-later
// The Controller page's logic (ControllerMapping.dc.html; UI/ControllerMapView.swift):
// a controller map's mode and, for Keyboard & mouse and Custom, what each of
// the controller's inputs does, beside a picture of the pad.
//
// - Rows (ControllerMapRow): LT, LB, L stick, L3, D-pad, View and Menu down
//   the left; RT, RB, Y, X, B, A, R stick and R3 down the right. Home is
//   Playport's, shown and not a row.
// - A stick's row is the whole stick (mouse look, a pad stick) or its four
//   directions (W A S D); the D-pad's row is its four directions. Choosing
//   such a row lists its parts (ControllerMapPart): for a stick Whole stick
//   or Four directions, then what each does; a part's ActionPicker sets it.
// - In Custom, a row that differs from the Keyboard & mouse preset has the
//   amber dot, and Y puts just that row back to the preset (`reset`). Reset all
//   (ControllerMapConfirm.resetAll) and Edit a copy (`copyPreset`, from
//   Keyboard & mouse) ask first when they would replace the player's own table.
// - Pressing a controller's input rings its row, but for those the page
//   moves with (A, B, Y, the D-pad, the left stick): X, LB, RB, View and Menu
//   come as the router's presses (`row(for:)`), LT, RT, L3, R3 and the right
//   stick from its snapshots (`pressed(from:to:)`).

import Foundation
import HostIOKit

extension ControllerMap.Mode {
    /// The page's switch and Game options' value (ControllerMapping.dc.html).
    public var title: String {
        switch self {
        case .controller: "As a controller"
        case .keyboardMouse: "As keyboard & mouse"
        case .custom: "Custom"
        }
    }

    /// The in-game menu's narrower panel.
    public var shortTitle: String {
        switch self {
        case .controller: "Pad"
        case .keyboardMouse: "Keys & mouse"
        case .custom: "Custom"
        }
    }
}

public enum ControllerMapRow: String, CaseIterable, Sendable {
    case lt, lb, leftStick, ls, dpad, back, start
    case rt, rb, y, x, b, a, rightStick, rs

    public var title: String {
        switch self {
        case .leftStick: "L stick"
        case .rightStick: "R stick"
        case .dpad: "D-pad"
        default: pad.map(ActionText.pad) ?? rawValue
        }
    }

    /// The pad's control this row is (nil for the D-pad's four).
    public var pad: PadControl? { self == .dpad ? nil : PadControl(rawValue: rawValue) }

    /// Down the left of the picture, else the right.
    public var isLeft: Bool { Self.left.contains(self) }

    public static let left: [ControllerMapRow] = [.lt, .lb, .leftStick, .ls, .dpad, .back, .start]
    public static let right: [ControllerMapRow] = [.rt, .rb, .y, .x, .b, .a, .rightStick, .rs]

    /// The focus item and the driver's id: `ctl:a`, `ctl:leftStick`.
    public var itemID: String { "ctl:" + rawValue }

    public var stick: PadControl? { self == .leftStick ? .leftStick : self == .rightStick ? .rightStick : nil }

    /// Every input the row covers (a stick: whole and its four directions).
    public var inputs: [ControllerInput] {
        if let s = stick { return [.control(s)] + Self.directionOrder.map { .stickDirection(s, $0) } }
        if self == .dpad { return [PadControl.up, .right, .down, .left].map { .control($0) } }
        return [.control(pad!)]
    }

    /// The inputs it shows for `b`, in the picture's order: a stick by direction W A S D
    /// (up, left, down, right), the D-pad clockwise from up.
    public func shown(in b: ControllerBindings) -> [ControllerInput] {
        if let s = stick { return ControllerMapEdit.isWhole(s, in: b) ? [.control(s)] : Array(inputs.dropFirst()) }
        return inputs
    }

    /// What each shown input does, short: `W`, `Mouse`, `Left`, `–`.
    public func caps(in b: ControllerBindings) -> [String] { shown(in: b).map { ActionText.short(b[$0]) } }

    static let directionOrder: [StickDirection] = [.up, .left, .down, .right]

    /// The row an input is on.
    public static func row(of input: ControllerInput) -> ControllerMapRow {
        switch input {
        case .stickDirection(let s, _): s == .leftStick ? .leftStick : .rightStick
        case .control(let c): [.up, .down, .left, .right].contains(c) ? .dpad : ControllerMapRow(rawValue: c.rawValue)!
        }
    }

    /// The row a router press rings: X, LB, RB, View, Menu (A, B, Y and the directions move the page).
    public static func row(for b: NavButton) -> ControllerMapRow? {
        switch b {
        case .x: .x
        case .lb: .lb
        case .rb: .rb
        case .view: .back
        case .menu: .start
        default: nil
        }
    }

    /// The row a pad's snapshot rings as one of LT, RT, L3, R3 or the right stick goes past half.
    public static func pressed(from old: PadInput, to new: PadInput) -> ControllerMapRow? {
        func past(_ v: Float) -> Bool { v >= 0.5 }
        func stick(_ p: PadInput) -> Bool { (p.rx * p.rx + p.ry * p.ry).squareRoot() >= 0.5 }
        if past(new.leftTrigger) && !past(old.leftTrigger) { return .lt }
        if past(new.rightTrigger) && !past(old.rightTrigger) { return .rt }
        if new.leftThumb && !old.leftThumb { return .ls }
        if new.rightThumb && !old.rightThumb { return .rs }
        if stick(new) && !stick(old) { return .rightStick }
        return nil
    }
}

/// One entry of a stick's or the D-pad's list (a PadModal picker).
public struct ControllerMapPart: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Switch the stick to whole, or to its four directions.
        case whole, directions
        /// What this input does: its ActionPicker.
        case input(ControllerInput)
    }

    public var id: String
    public var label: String
    public var detail: String?
    public var kind: Kind
    /// A radio on (the stick's current way).
    public var on = false
}

/// Changing a Custom table; every function returns a valid table.
public enum ControllerMapEdit {
    public static var preset: ControllerBindings { ControllerMap.keyboardMouse }

    /// Bound whole (or not bound at all), rather than by direction.
    public static func isWhole(_ stick: PadControl, in b: ControllerBindings) -> Bool {
        b[.control(stick)] != nil || !StickDirection.allCases.contains { b[.stickDirection(stick, $0)] != nil }
    }

    /// `b` with `input` doing `action` (nil: nothing); a stick bound whole loses its
    /// directions and a direction loses the whole stick. Nil when the input does not take it.
    public static func setting(_ input: ControllerInput, _ action: InputAction?, in b: ControllerBindings) -> ControllerBindings? {
        if let action, !input.accepts(action) { return nil }
        var t = b.table
        t[input] = action
        if action != nil {
            switch input {
            case .control(let s) where s.isStick:
                for d in StickDirection.allCases { t[.stickDirection(s, d)] = nil }
            case .stickDirection(let s, _):
                t[.control(s)] = nil
            default:
                break
            }
        }
        return ControllerBindings(t)
    }

    /// The stick bound whole: the preset's whole action, else its own pad stick.
    public static func usingWhole(_ stick: PadControl, in b: ControllerBindings) -> ControllerBindings {
        guard b[.control(stick)] == nil else { return b }
        return setting(.control(stick), preset[.control(stick)] ?? .pad(stick), in: b)!
    }

    /// The stick by direction: the preset's keys when it has them (W A S D), else the arrow keys.
    public static func usingDirections(_ stick: PadControl, in b: ControllerBindings) -> ControllerBindings {
        guard isWhole(stick, in: b) else { return b }
        let arrows: [StickDirection: UInt8] = [.up: 0x26, .down: 0x28, .left: 0x25, .right: 0x27]
        var t = b.table
        t[.control(stick)] = nil
        for d in StickDirection.allCases {
            t[.stickDirection(stick, d)] = preset[.stickDirection(stick, d)] ?? .key(arrows[d]!, [])
        }
        return ControllerBindings(t)!
    }

    /// The row's inputs back to the preset's (Y on the row).
    public static func reset(_ row: ControllerMapRow, in b: ControllerBindings) -> ControllerBindings {
        var t = b.table
        for i in row.inputs { t[i] = preset[i] }
        return ControllerBindings(t)!
    }

    /// The row does something the preset's does not (the amber dot).
    public static func differs(_ row: ControllerMapRow, in b: ControllerBindings) -> Bool {
        row.inputs.contains { b[$0] != preset[$0] }
    }

    /// A stick's or the D-pad's list; nil for a row of one input (its ActionPicker opens at once).
    public static func parts(_ row: ControllerMapRow, in b: ControllerBindings) -> [ControllerMapPart]? {
        func part(_ i: ControllerInput, _ label: String) -> ControllerMapPart {
            ControllerMapPart(id: i.name, label: label, detail: ActionText.name(b[i]), kind: .input(i))
        }
        if let s = row.stick {
            let whole = isWhole(s, in: b)
            var out = [
                ControllerMapPart(id: "whole", label: "Whole stick", detail: "Mouse look, or a pad's stick", kind: .whole, on: whole),
                ControllerMapPart(id: "directions", label: "Four directions", detail: "A key or button each", kind: .directions, on: !whole),
            ]
            if whole {
                out.append(part(.control(s), "What it does"))
            } else {
                out += ControllerMapRow.directionOrder.map { part(.stickDirection(s, $0), $0.title) }
            }
            return out
        }
        if row == .dpad { return row.inputs.map { i in part(i, i.direction?.title ?? i.name) } }
        return nil
    }

    /// A part chosen: the stick switched (and the list again), or the input whose ActionPicker opens.
    public static func choose(_ part: ControllerMapPart, of row: ControllerMapRow,
                              in b: ControllerBindings) -> (table: ControllerBindings, pick: ControllerInput?) {
        switch part.kind {
        case .whole: (row.stick.map { usingWhole($0, in: b) } ?? b, nil)
        case .directions: (row.stick.map { usingDirections($0, in: b) } ?? b, nil)
        case .input(let i): (b, i)
        }
    }

    /// The ActionPicker's title for an input: `What A presses`, `What L stick up presses`.
    public static func pickerTitle(_ input: ControllerInput) -> String {
        let row = ControllerMapRow.row(of: input)
        let part: String = switch input {
        case .stickDirection(_, let d): row.title + " " + d.title.lowercased()
        case .control(let c) where row == .dpad: ActionText.pad(c)
        default: row.title
        }
        return "What \(part) presses"
    }
}

/// Reset all, and Edit a copy over the player's own table: asked first in a
/// list whose first, default choice changes nothing.
public enum ControllerMapConfirm: String, Sendable {
    case resetAll, copyPreset

    /// Whether it must ask: only when it would replace a table that is not the preset.
    public static func needed(for map: ControllerMap) -> Bool { map.custom != ControllerMap.keyboardMouse }

    public var title: String {
        switch self {
        case .resetAll: "Reset every input?"
        case .copyPreset: "Edit a copy of Keyboard & mouse?"
        }
    }

    public var note: String {
        switch self {
        case .resetAll: "Every input goes back to what Keyboard & mouse does."
        case .copyPreset: "Custom already has your own changes."
        }
    }

    /// (id, label); the first is the default and keeps the player's table.
    public var options: [(id: String, label: String)] {
        switch self {
        case .resetAll: [("keep", "Keep my changes"), ("reset", "Reset all to Keyboard & mouse")]
        case .copyPreset: [("keep", "Use my Custom map"), ("reset", "Start again from Keyboard & mouse")]
        }
    }

    public var defaultChoice: String { "keep" }

    /// The map after `choice` (`keep` or `reset`); Edit a copy is in Custom either way.
    public func apply(_ choice: String, to map: ControllerMap) -> ControllerMap {
        var m = map
        if self == .copyPreset { m.mode = .custom }
        if choice == "reset" { m.custom = ControllerMap.keyboardMouse }
        return m
    }
}

extension StickDirection {
    public var title: String {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        }
    }
}

extension ControllerInput {
    /// A D-pad direction's or a stick direction's way.
    var direction: StickDirection? {
        switch self {
        case .stickDirection(_, let d): d
        case .control(.up): .up
        case .control(.down): .down
        case .control(.left): .left
        case .control(.right): .right
        default: nil
        }
    }
}

extension ActionText {
    /// A row's key cap: `W`, `Shift+1`, `Left`, `Mouse`, `Pad A`, `Playport`; `–` for nothing.
    public static func short(_ a: InputAction?) -> String {
        switch a {
        case nil: "–"
        case .mouse(.left)?: "Left"
        case .mouse(.right)?: "Right"
        case .mouse(.middle)?: "Middle"
        case .mouse(.move)?: "Mouse"
        case .playport?: "Playport"
        default: name(a)
        }
    }
}
