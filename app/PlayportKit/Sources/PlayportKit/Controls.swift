// SPDX-License-Identifier: GPL-3.0-or-later
// When the on-screen controls show, and how (docs/plans/2026-10-09-touch-controls.md,
// phase 1; SettingsControls.dc.html, QuickMenuControls.dc.html). Settings ›
// Controls holds the defaults (ControlsDefaults); the in-game menu's Controls
// panel sets a game's own (GameControls), which apply at once.
//
// - Automatic (the default): shown while no extended controller is connected,
//   hidden as soon as one connects, back when it goes. Always shows them with a
//   controller too; Never makes Off every game's starting choice.
// - A game's layout is Off or Gamepad; with none set it is Gamepad, or Off
//   when the default is Never. Off hides them for that game whatever else.
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

/// A game's on-screen layout: none, or a preset (phase 4 adds Keyboard & mouse and Point & click).
public enum OnScreenLayout: String, Codable, CaseIterable, Sendable {
    case off, gamepad

    public var title: String {
        switch self {
        case .off: "Off"
        case .gamepad: "Gamepad"
        }
    }

    /// The layout with these options.
    public func layout(dpad: OnScreenDpad, rightStick: OnScreenRightStick) -> ControlLayout? {
        switch self {
        case .off: nil
        case .gamepad: .gamepad(dpad: dpad, rightStick: rightStick)
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

    public var show = ControlsShow.automatic
    public var opacity = ControlsOpacity.defaultValue
    public var haptics = true
    public var dpad = OnScreenDpad.off
    public var rightStick = OnScreenRightStick.off

    public init(show: ControlsShow = .automatic, opacity: Double = ControlsOpacity.defaultValue, haptics: Bool = true,
                dpad: OnScreenDpad = .off, rightStick: OnScreenRightStick = .off) {
        self.show = show; self.opacity = opacity; self.haptics = haptics; self.dpad = dpad; self.rightStick = rightStick
    }

    /// What `defaults` holds, each key missing (or not understood) read as its default.
    public init(_ defaults: UserDefaults) {
        show = defaults.string(forKey: Self.showKey).flatMap(ControlsShow.init(rawValue:)) ?? .automatic
        let o = defaults.object(forKey: Self.opacityKey) as? Double ?? ControlsOpacity.defaultValue
        opacity = (0.1...1).contains(o) ? o : ControlsOpacity.defaultValue
        haptics = defaults.object(forKey: Self.hapticsKey) as? Bool ?? true
        dpad = defaults.string(forKey: Self.dpadKey).flatMap(OnScreenDpad.init(rawValue:)) ?? .off
        rightStick = defaults.string(forKey: Self.rightStickKey).flatMap(OnScreenRightStick.init(rawValue:)) ?? .off
    }
}

/// A game's own controls, nil fields following the defaults. Saved as JSON per
/// catalogue id; the dev driver's `controls:<title id>` saves one. `gyro` is the
/// game's own gyro aim (GyroSettings.swift), over Settings' `gyro.*` defaults;
/// JSON saved before it reads as none.
public struct GameControls: Codable, Equatable, Sendable {
    public var layout: OnScreenLayout?
    public var opacity: Double?
    public var dpad: OnScreenDpad?
    public var rightStick: OnScreenRightStick?
    public var gyro: GameGyro?

    public init(layout: OnScreenLayout? = nil, opacity: Double? = nil, dpad: OnScreenDpad? = nil,
                rightStick: OnScreenRightStick? = nil, gyro: GameGyro? = nil) {
        self.layout = layout; self.opacity = opacity; self.dpad = dpad; self.rightStick = rightStick; self.gyro = gyro
    }

    public var isEmpty: Bool { layout == nil && opacity == nil && dpad == nil && rightStick == nil && (gyro?.isEmpty ?? true) }

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

    public init(layout: OnScreenLayout, visible: Bool, opacity: Double, dpad: OnScreenDpad = .off,
                rightStick: OnScreenRightStick = .off, padConnected: Bool? = nil) {
        self.layout = layout; self.visible = visible; self.opacity = opacity; self.dpad = dpad; self.rightStick = rightStick
        self.padConnected = padConnected ?? visible
    }

    /// What is drawn: the layout, or nothing.
    public var drawnLayout: ControlLayout? { visible ? layout.layout(dpad: dpad, rightStick: rightStick) : nil }

    public static func resolve(game: GameControls?, defaults: ControlsDefaults, controllerConnected: Bool) -> ControlsState {
        let layout = game?.layout ?? (defaults.show == .never ? .off : .gamepad)
        let shown = layout != .off && (defaults.show == .always || !controllerConnected)
        return ControlsState(layout: layout, visible: shown, opacity: game?.opacity ?? defaults.opacity,
                             dpad: game?.dpad ?? defaults.dpad, rightStick: game?.rightStick ?? defaults.rightStick,
                             padConnected: shown || !controllerConnected)
    }

    /// The in-game menu's Controls row: `Gamepad · 60%`, `Off`, `Gamepad · controller connected` while a controller hides it.
    public var summary: String {
        guard layout != .off else { return layout.title }
        return layout.title + " · " + (visible ? ControlsOpacity.label(opacity) : "controller connected")
    }
}
