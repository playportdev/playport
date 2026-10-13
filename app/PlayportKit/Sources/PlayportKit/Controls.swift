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
// - Without a controller the Playport button stays even when the layout is Off,
//   so a person playing by touch can always reach the in-game menu.
// - Opacity: the game's own, else the default (60%).

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

    public var layout: ControlLayout? {
        switch self {
        case .off: nil
        case .gamepad: .gamepad
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

    public var show = ControlsShow.automatic
    public var opacity = ControlsOpacity.defaultValue
    public var haptics = true

    public init(show: ControlsShow = .automatic, opacity: Double = ControlsOpacity.defaultValue, haptics: Bool = true) {
        self.show = show; self.opacity = opacity; self.haptics = haptics
    }

    /// What `defaults` holds, each key missing (or not understood) read as its default.
    public init(_ defaults: UserDefaults) {
        show = defaults.string(forKey: Self.showKey).flatMap(ControlsShow.init(rawValue:)) ?? .automatic
        let o = defaults.object(forKey: Self.opacityKey) as? Double ?? ControlsOpacity.defaultValue
        opacity = (0.1...1).contains(o) ? o : ControlsOpacity.defaultValue
        haptics = defaults.object(forKey: Self.hapticsKey) as? Bool ?? true
    }
}

/// A game's own controls, nil fields following the defaults. Saved as JSON per
/// catalogue id; the dev driver's `controls:<title id>` saves one.
public struct GameControls: Codable, Equatable, Sendable {
    public var layout: OnScreenLayout?
    public var opacity: Double?

    public init(layout: OnScreenLayout? = nil, opacity: Double? = nil) {
        self.layout = layout; self.opacity = opacity
    }

    public var isEmpty: Bool { layout == nil && opacity == nil }
}

/// The controls a running game has now.
public struct ControlsState: Equatable, Sendable {
    public var layout: OnScreenLayout
    /// The layout's controls are shown, and their pad is player 1.
    public var visible: Bool
    public var opacity: Double
    /// The Playport button alone is shown: the layout is Off and no controller is connected.
    public var menuButtonOnly = false

    public init(layout: OnScreenLayout, visible: Bool, opacity: Double, menuButtonOnly: Bool = false) {
        self.layout = layout; self.visible = visible; self.opacity = opacity; self.menuButtonOnly = menuButtonOnly
    }

    /// What is drawn: the layout, the Playport button alone, or nothing.
    public var drawnLayout: ControlLayout? {
        visible ? layout.layout : menuButtonOnly ? .menuButton : nil
    }

    public static func resolve(game: GameControls?, defaults: ControlsDefaults, controllerConnected: Bool) -> ControlsState {
        let layout = game?.layout ?? (defaults.show == .never ? .off : .gamepad)
        let shown = layout != .off && (defaults.show == .always || !controllerConnected)
        return ControlsState(layout: layout, visible: shown, opacity: game?.opacity ?? defaults.opacity,
                             menuButtonOnly: !shown && !controllerConnected)
    }

    /// The in-game menu's Controls row: `Gamepad · 60%`, `Off`, `Gamepad · controller connected` while a controller hides it.
    public var summary: String {
        guard layout != .off else { return layout.title }
        return layout.title + " · " + (visible ? ControlsOpacity.label(opacity) : "controller connected")
    }
}
