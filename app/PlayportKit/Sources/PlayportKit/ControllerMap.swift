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
    /// d-pad 1–4 (up, right, down, left), View Tab, Menu Esc.
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
            .control(.up): key(0x31),                         // 1
            .control(.right): key(0x32),                      // 2
            .control(.down): key(0x33),                       // 3
            .control(.left): key(0x34),                       // 4
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
