// SPDX-License-Identifier: GPL-3.0-or-later
// A controller map (docs/plans/2026-10-09-touch-controls.md, "Controller maps",
// phase 3; ControllerMapping.dc.html): what a physical controller's inputs do
// in a game.
//
// - `controller` (the default): the pad is the game's XInput pad, as before.
// - `keyboardMouse`: the preset below; the game sees keys and a mouse, and
//   no pad input from the controller.
// - `custom`: the same kind of table (HostIOKit ControllerBindings), edited;
//   it starts as a copy of the preset, and is kept while another mode is chosen.
// - Home stays Playport's in every mode (it is never an input of a table).
// - The on-screen controls' pad is not a controller: no map applies to it.
//
// A game's map is part of its GameControls record (`controllerMap`, missing
// for the default); Settings' default is under `controls.controllerMap`, as a
// mode's name or a map's JSON. Saved JSON carries `version` (left out, it is
// this build's); any other is refused, and the default applies instead.
//
// Look speed (LookSpeed): how fast a stick bound to `mouse:move` turns the
// view, a multiple of MappedPad's 2000 counts a second. It is not part of the
// map: a game's own is GameControls.lookSpeed, over Settings'
// `controls.lookSpeed` (1×), so a mode change keeps it and Y on its row
// clears just it.

import Foundation
import HostIOKit

public struct ControllerMap: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let defaultsKey = "controls.controllerMap"

    public enum Mode: String, Codable, CaseIterable, Sendable {
        case controller, keyboardMouse, custom
    }

    public var mode: Mode
    /// The `custom` mode's table.
    public var custom: ControllerBindings

    public init(mode: Mode = .controller, custom: ControllerBindings = ControllerMap.keyboardMouse) {
        self.mode = mode
        self.custom = custom
    }

    /// The table a pad plays through; nil for `controller`, where it passes through.
    public var bindings: ControllerBindings? {
        switch mode {
        case .controller: nil
        case .keyboardMouse: Self.keyboardMouse
        case .custom: custom
        }
    }

    /// The `keyboardMouse` preset: left stick W A S D, right stick mouse look,
    /// RT left mouse button, LT right, A Space, B C, X R, Y F, LB Q, RB E,
    /// d-pad the arrow keys (so a game's menus can be driven: owner, 2026-10-13;
    /// it was 1–4 before touch controls U), View Tab, Menu Esc.
    public static let keyboardMouse: ControllerBindings = {
        func key(_ vk: UInt8) -> InputAction { .key(vk, []) }
        let table: [ControllerInput: InputAction] = [
            .stickDirection(.leftStick, .up): key(0x57),      // W
            .stickDirection(.leftStick, .left): key(0x41),    // A
            .stickDirection(.leftStick, .down): key(0x53),    // S
            .stickDirection(.leftStick, .right): key(0x44),   // D
            .control(.rightStick): .mouse(.move),
            .control(.rt): .mouse(.left),
            .control(.lt): .mouse(.right),
            .control(.a): key(0x20),                          // Space
            .control(.b): key(0x43),                          // C
            .control(.x): key(0x52),                          // R
            .control(.y): key(0x46),                          // F
            .control(.lb): key(0x51),                         // Q
            .control(.rb): key(0x45),                         // E
            .control(.up): key(0x26),                         // Up arrow
            .control(.right): key(0x27),                      // Right arrow
            .control(.down): key(0x28),                       // Down arrow
            .control(.left): key(0x25),                       // Left arrow
            .control(.back): key(0x09),                       // View: Tab
            .control(.start): key(0x1B),                      // Menu: Esc
        ]
        return ControllerBindings(table)!
    }()

    enum CodingKeys: String, CodingKey { case version, mode, table }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c,
                                                   debugDescription: "controller map version \(version); this build reads \(Self.currentVersion)")
        }
        mode = try c.decode(Mode.self, forKey: .mode)
        custom = try c.decodeIfPresent(ControllerBindings.self, forKey: .table) ?? Self.keyboardMouse
    }

    /// `table` only when it is not the preset.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(mode, forKey: .mode)
        if custom != Self.keyboardMouse { try c.encode(custom, forKey: .table) }
    }

    /// Settings' default: `controls.controllerMap` as a mode's name or a map's
    /// JSON; missing or not understood, `controller`.
    public init(_ defaults: UserDefaults) {
        self = Self.parse(defaults.string(forKey: Self.defaultsKey)) ?? ControllerMap()
    }

    /// A mode's name (`keyboardMouse`) or a map's JSON; nil for anything else.
    public static func parse(_ text: String?) -> ControllerMap? {
        guard let t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if let m = Mode(rawValue: t) { return ControllerMap(mode: m) }
        return try? JSONDecoder().decode(ControllerMap.self, from: Data(t.utf8))
    }

    /// For the logs: `keyboardMouse`, `custom (19 inputs)`.
    public var summary: String {
        mode == .custom ? "custom (\(custom.table.count) inputs)" : mode.rawValue
    }
}

/// The Look speed row's steps (Keyboard & mouse and Custom; ControllerMapping.dc.html).
public enum LookSpeed {
    public static let defaultsKey = "controls.lookSpeed"
    public static let defaultValue = 1.0
    public static let steps: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 4]
    /// What a saved or `set:` value may be; anything else reads as the default.
    public static let range = 0.1...8.0

    /// `value` when it is in range, else the default.
    public static func kept(_ value: Double?) -> Double? {
        guard let value, value.isFinite, range.contains(value) else { return nil }
        return value
    }

    /// The step `by` steps from `value` (-1 left, +1 right), stopping at the ends; a value between the steps moves from its nearest.
    public static func step(_ value: Double, by: Int) -> Double {
        let i = GyroSteps.nearest(value, in: steps)
        return steps[max(0, min(steps.count - 1, i + by))]
    }

    /// `1.0×`, `0.25×`.
    public static func label(_ value: Double) -> String { GyroText.sensitivity(value) }
}
