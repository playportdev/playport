// SPDX-License-Identifier: GPL-3.0-or-later
// When the on-screen controls show, and how (PLA-13,
// phase 1; SettingsControls.dc.html, QuickMenuControls.dc.html). Settings ›
// Controls holds the defaults (ControlsDefaults); the in-game menu's Controls
// panel sets a game's own (GameControls), which apply at once.
//
// - Automatic (the default): shown while no extended controller is connected,
//   hidden as soon as one connects, back when it goes. Always shows them with a
//   controller too; Never makes Off every game's starting choice.
// - A game's layout is Off, Gamepad, Keyboard & mouse or Point & click; with
//   none set it is Off when the default is Never, else Settings' Starting
//   layout, else the game's compatibility default's (CompatDefaults
//   `controls`; the Starting layout's "Suggested for the game"), else Gamepad.
//   Off hides them for that game whatever else. LayoutSuggestion offers
//   Keyboard & mouse once for a game on Gamepad that reads no XInput state.
// - A game's own copy of a preset, saved by the layout editor
//   (LayoutEditor.swift; GameControls.layouts), is drawn instead of the preset
//   whenever that preset is the game's layout.
// - The controls' pad is player 1 whenever no controller is connected, at rest
//   while the layout is Off (ControlsState.padConnected): a game that looks for
//   pads only now and then, or only at its start, already has it when the
//   controls are turned on in-game. A game may show pad prompts while Off.
// - A three-finger tap on the game opens the in-game menu whatever the layout
//   (S1Probe's HostIO.swift, GameSurfaceView), so Off draws nothing at all.
// - The Gamepad layout's d-pad (Off or On) and right stick (Off, Below A/B/X/Y
//   or Above A/B/X/Y): the game's own, else the default; both Off by default.
// - Opacity: the game's own, else the default (60%).
// - Gyro aim (GyroSettings.swift): the game's own fields in the same record,
//   over the `gyro.*` defaults; a change applies at once as the rest do.
// - The controller map (ControllerMap.swift): the game's own in the same
//   record, else Settings' (`controls.controllerMap`); `controller` by default.
//   Its Look speed the same way (`lookSpeed`, `controls.lookSpeed`; 1×).

import Foundation

public enum ControlsShow: String, Codable, CaseIterable, Sendable {
    case automatic, always, never

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .always: "Always"
        case .never: "Never"
        }
    }
}
/// A game's on-screen layout: none, or a preset (ControlLayout.swift).
public enum OnScreenLayout: String, Codable, CaseIterable, Sendable {
    case off, gamepad, keyboardMouse, pointClick

    public var title: String {
        switch self {
        case .off: "Off"
        case .gamepad: "Gamepad"
        case .keyboardMouse: "Keyboard & mouse"
        case .pointClick: "Point & click"
        }
    }

    /// The in-game menu's narrower panel: four beside "On-screen controls" in 330 pt.
    public var shortTitle: String {
        switch self {
        case .off: "Off"
        case .gamepad: "Pad"
        case .keyboardMouse: "Keys"
        case .pointClick: "Point"
        }
    }

    /// Settings › Controls › Starting layout's values: the game's suggestion (nil), then the layouts
    /// (Off is On-screen controls › Never).
    public static let startingChoices: [OnScreenLayout?] = [nil, .gamepad, .keyboardMouse, .pointClick]

    public static func startingTitle(_ l: OnScreenLayout?) -> String { l?.title ?? "Suggested for the game" }

    /// The layout with these options (the d-pad and right stick are Gamepad's).
    public func layout(dpad: OnScreenDpad, rightStick: OnScreenRightStick) -> ControlLayout? {
        switch self {
        case .off: nil
        case .gamepad: .gamepad(dpad: dpad, rightStick: rightStick)
        case .keyboardMouse: .keyboardMouse()
        case .pointClick: .pointClick()
        }
    }
}

/// The Gamepad layout's d-pad: centred above the left stick's zone when On.
public enum OnScreenDpad: String, Codable, CaseIterable, Sendable {
    case off, on

    public var title: String {
        switch self {
        case .off: "Off"
        case .on: "On"
        }
    }
}

/// The Gamepad layout's right stick: its zone centred under or over A/B/X/Y.
public enum OnScreenRightStick: String, Codable, CaseIterable, Sendable {
    /// No right stick; A/B/X/Y in the lower right corner.
    case off
    /// The zone in the lower right corner, A/B/X/Y above it.
    case below
    /// A/B/X/Y in the lower right corner, the zone above them.
    case above

    public var title: String {
        switch self {
        case .off: "Off"
        case .below: "Below A/B/X/Y"
        case .above: "Above A/B/X/Y"
        }
    }

    /// The in-game menu's narrower panel: `Below`.
    public var shortTitle: String {
        switch self {
        case .off: "Off"
        case .below: "Below"
        case .above: "Above"
        }
    }
}

public enum ControlsOpacity {
    /// The steps a row moves through with left and right.
    public static let steps: [Double] = [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
    public static let defaultValue = 0.6

    /// The step `by` steps from `value` (-1 left, +1 right), stopping at the ends.
    public static func step(_ value: Double, by: Int) -> Double {
        let i = steps.indices.min { abs(steps[$0] - value) < abs(steps[$1] - value) } ?? 0
        return steps[max(0, min(steps.count - 1, i + by))]
    }

    public static func label(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

/// Settings › Controls, in UserDefaults by these keys (the driver's `set:` sets them too).
public struct ControlsDefaults: Equatable, Sendable {
    public static let showKey = "controls.show"
    public static let opacityKey = "controls.opacity"
    public static let hapticsKey = "controls.haptics"
    public static let dpadKey = "controls.dpad"
    public static let rightStickKey = "controls.rightStick"
    public static let controllerMapKey = ControllerMap.defaultsKey
    public static let lookSpeedKey = LookSpeed.defaultsKey
    /// A layout's name; missing, empty or not one of `OnScreenLayout.startingChoices` is Suggested.
    public static let startingLayoutKey = "controls.startingLayout"

    public var show = ControlsShow.automatic
    public var opacity = ControlsOpacity.defaultValue
    public var haptics = true
    public var dpad = OnScreenDpad.off
    public var rightStick = OnScreenRightStick.off
    public var controllerMap = ControllerMap()
    public var lookSpeed = LookSpeed.defaultValue
    /// Every game's layout unless it has its own or a compatibility default; nil: the game's
    /// suggestion (its compatibility default, else Gamepad).
    public var startingLayout: OnScreenLayout?

    public init(show: ControlsShow = .automatic, opacity: Double = ControlsOpacity.defaultValue, haptics: Bool = true,
                dpad: OnScreenDpad = .off, rightStick: OnScreenRightStick = .off, controllerMap: ControllerMap = ControllerMap(),
                lookSpeed: Double = LookSpeed.defaultValue, startingLayout: OnScreenLayout? = nil) {
        self.show = show; self.opacity = opacity; self.haptics = haptics; self.dpad = dpad; self.rightStick = rightStick
        self.controllerMap = controllerMap; self.lookSpeed = lookSpeed; self.startingLayout = startingLayout
    }

    /// What `defaults` holds, each key missing (or not understood) read as its default.
    public init(_ defaults: UserDefaults) {
        show = defaults.string(forKey: Self.showKey).flatMap(ControlsShow.init(rawValue:)) ?? .automatic
        let o = defaults.object(forKey: Self.opacityKey) as? Double ?? ControlsOpacity.defaultValue
        opacity = (0.1...1).contains(o) ? o : ControlsOpacity.defaultValue
        haptics = defaults.object(forKey: Self.hapticsKey) as? Bool ?? true
        dpad = defaults.string(forKey: Self.dpadKey).flatMap(OnScreenDpad.init(rawValue:)) ?? .off
        rightStick = defaults.string(forKey: Self.rightStickKey).flatMap(OnScreenRightStick.init(rawValue:)) ?? .off
        controllerMap = ControllerMap(defaults)
        // A number, or a String that reads as one (the driver's `set:controls.lookSpeed=1.5`).
        lookSpeed = LookSpeed.kept(GyroSettings.number(defaults, Self.lookSpeedKey)) ?? LookSpeed.defaultValue
        startingLayout = defaults.string(forKey: Self.startingLayoutKey).flatMap(OnScreenLayout.init(rawValue:))
            .flatMap { OnScreenLayout.startingChoices.contains($0) ? $0 : nil }
    }
}

/// A game's own controls, nil fields following the defaults. Saved as JSON per
/// catalogue id; the dev driver's `controls:<title id>` saves one. `gyro` is the
/// game's own gyro aim (GyroSettings.swift), over Settings' `gyro.*` defaults;
/// `controllerMap` its controller map (ControllerMap.swift), over Settings', and
/// `lookSpeed` its mouse look's speed (LookSpeed), over Settings'. JSON
/// saved before either reads as none; a map this build cannot read (another
/// version) reads as none too, so the rest of the record still loads.
///
/// `layouts` are the game's own copies of presets, saved by the layout editor
/// (LayoutEditor.swift) under `layouts` as `{"keyboardMouse": <layout>}`: one
/// is drawn whenever its preset is the game's layout, and kept while another
/// is chosen. A copy this build cannot read (another layout version, a preset
/// it lacks, Off) makes the whole record unreadable rather than reading as
/// none, so GameControlsRecords writes it back as it came instead of dropping
/// the person's edits.
public struct GameControls: Codable, Equatable, Sendable {
    public var layout: OnScreenLayout?
    public var opacity: Double?
    public var dpad: OnScreenDpad?
    public var rightStick: OnScreenRightStick?
    public var gyro: GameGyro?
    public var controllerMap: ControllerMap?
    public var lookSpeed: Double?
    public var layouts: [OnScreenLayout: ControlLayout]

    public init(layout: OnScreenLayout? = nil, opacity: Double? = nil, dpad: OnScreenDpad? = nil,
                rightStick: OnScreenRightStick? = nil, gyro: GameGyro? = nil, controllerMap: ControllerMap? = nil,
                lookSpeed: Double? = nil, layouts: [OnScreenLayout: ControlLayout] = [:]) {
        self.layout = layout; self.opacity = opacity; self.dpad = dpad; self.rightStick = rightStick; self.gyro = gyro
        self.controllerMap = controllerMap; self.lookSpeed = lookSpeed; self.layouts = layouts
    }

    enum CodingKeys: String, CodingKey { case layout, opacity, dpad, rightStick, gyro, controllerMap, lookSpeed, layouts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = try c.decodeIfPresent(OnScreenLayout.self, forKey: .layout)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity)
        dpad = try c.decodeIfPresent(OnScreenDpad.self, forKey: .dpad)
        rightStick = try c.decodeIfPresent(OnScreenRightStick.self, forKey: .rightStick)
        gyro = try c.decodeIfPresent(GameGyro.self, forKey: .gyro)
        controllerMap = (try? c.decodeIfPresent(ControllerMap.self, forKey: .controllerMap)) ?? nil
        lookSpeed = try c.decodeIfPresent(Double.self, forKey: .lookSpeed)
        layouts = [:]
        for (name, l) in try c.decodeIfPresent([String: ControlLayout].self, forKey: .layouts) ?? [:] {
            guard let preset = OnScreenLayout(rawValue: name), preset != .off else {
                throw DecodingError.dataCorruptedError(forKey: .layouts, in: c, debugDescription: "no preset \"\(name)\" to copy")
            }
            layouts[preset] = l
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(layout, forKey: .layout)
        try c.encodeIfPresent(opacity, forKey: .opacity)
        try c.encodeIfPresent(dpad, forKey: .dpad)
        try c.encodeIfPresent(rightStick, forKey: .rightStick)
        try c.encodeIfPresent(gyro, forKey: .gyro)
        try c.encodeIfPresent(controllerMap, forKey: .controllerMap)
        try c.encodeIfPresent(lookSpeed, forKey: .lookSpeed)
        if !layouts.isEmpty {
            try c.encode(Dictionary(uniqueKeysWithValues: layouts.map { ($0.key.rawValue, $0.value) }), forKey: .layouts)
        }
    }

    public var isEmpty: Bool {
        layout == nil && opacity == nil && dpad == nil && rightStick == nil && (gyro?.isEmpty ?? true) && controllerMap == nil
            && lookSpeed == nil && layouts.isEmpty
    }

    /// The game's controller map, else the default.
    public func controllerMap(over defaults: ControlsDefaults) -> ControllerMap { controllerMap ?? defaults.controllerMap }

    /// The game's look speed when it is in range, else the default.
    public func lookSpeed(over defaults: ControlsDefaults) -> Double { LookSpeed.kept(lookSpeed) ?? defaults.lookSpeed }

    /// The same, with a gyro that sets nothing dropped (what the store saves).
    public var normalized: GameControls {
        var c = self
        if c.gyro?.isEmpty == true { c.gyro = nil }
        return c
    }

    /// The game's gyro aim settings over the defaults.
    public func gyroSettings(over defaults: GyroSettings) -> GyroSettings {
        gyro?.resolved(over: defaults) ?? defaults
    }
}

/// The controls a running game has now.
public struct ControlsState: Equatable, Sendable {
    public var layout: OnScreenLayout
    /// The layout's controls are shown.
    public var visible: Bool
    public var opacity: Double
    public var dpad: OnScreenDpad
    public var rightStick: OnScreenRightStick
    /// No controller is connected, or the controls are shown: the controls' pad
    /// is player 1 (slot 0), at rest while the layout is Off, so turning them on
    /// in-game only draws them and a game that notices a pad connecting late
    /// (or never) already has it.
    public var padConnected: Bool
    /// The game's own copy of `layout` (GameControls.layouts), drawn instead of the preset.
    public var edited: ControlLayout?

    public init(layout: OnScreenLayout, visible: Bool, opacity: Double, dpad: OnScreenDpad = .off,
                rightStick: OnScreenRightStick = .off, padConnected: Bool? = nil, edited: ControlLayout? = nil) {
        self.layout = layout; self.visible = visible; self.opacity = opacity; self.dpad = dpad; self.rightStick = rightStick
        self.padConnected = padConnected ?? visible
        self.edited = edited
    }

    /// What is drawn: the game's copy of the layout or the preset, or nothing.
    public var drawnLayout: ControlLayout? { visible ? edited ?? layout.layout(dpad: dpad, rightStick: rightStick) : nil }

    /// The d-pad and right stick options place something: the layout is the Gamepad preset itself, not
    /// the game's copy of it (which has its own) or another layout (which has none).
    public var hasGamepadOptions: Bool { layout == .gamepad && edited == nil }

    /// The game's own layout, else Off under Never, else the game's compatibility default (`compat`,
    /// CompatDefaults.Entry.controls), else Settings' Starting layout, else Gamepad (decision 0074).
    public static func resolve(game: GameControls?, defaults: ControlsDefaults, controllerConnected: Bool,
                               compat: OnScreenLayout? = nil) -> ControlsState {
        let layout = game?.layout ?? (defaults.show == .never ? .off : compat ?? defaults.startingLayout ?? .gamepad)
        let shown = layout != .off && (defaults.show == .always || !controllerConnected)
        return ControlsState(layout: layout, visible: shown, opacity: game?.opacity ?? defaults.opacity,
                             dpad: game?.dpad ?? defaults.dpad, rightStick: game?.rightStick ?? defaults.rightStick,
                             padConnected: shown || !controllerConnected, edited: game?.layouts[layout])
    }

    /// The in-game menu's Controls row: `Gamepad · 60%`, `Off`, `Gamepad · hidden` while a controller
    /// hides it (short: "controller connected" was cut off there, touch controls 3c).
    public var summary: String {
        guard layout != .off else { return layout.title }
        return layout.title + " · " + (visible ? ControlsOpacity.label(opacity) : "hidden")
    }
}
