// SPDX-License-Identifier: GPL-3.0-or-later
// Playport's in-game menu (QuickMenu.dc.html; S1Probe UI/InGameMenuView.swift):
// its rows in order, the ring moving along them, and the words each row shows.
// The controller side (the Home button held, the presses) is HostIOKit's
// QuickMenuControl. Controls opens a panel beside the rows (QuickMenuControls.dc.html):
// the game's on-screen layout, its d-pad and right stick, their opacity, its gyro aim
// (output and sensitivity) and, while a controller is connected, its controller map's
// mode (ControllerMap.swift), up and down between them, left and right (and A) to
// change one, B back to the rows. Touch keyboard goes back to the game with the
// touch keyboard open over it (HostIOKit TouchKeyboard); Type text goes back to it
// with the text bar open over it (HostIOKit TextBar), the way into a guest's text
// field with a controller connected, when no on-screen controls are drawn.

import Foundation

public enum QuickMenuItem: String, CaseIterable, Sendable {
    case resume, controls, keyboard, text, screenshot, overlay, controller, quit

    public var title: String {
        switch self {
        case .resume: "Resume"
        case .controls: "Controls"
        case .keyboard: "Touch keyboard"
        case .text: "Type text"
        case .screenshot: "Screenshot"
        case .overlay: "Performance overlay"
        case .controller: "Controller"
        case .quit: "Quit game"
        }
    }
}

/// The Controls panel's rows.
public enum QuickMenuControlsRow: String, CaseIterable, Sendable {
    case layout, dpad, rightStick, opacity
    /// The game's gyro aim output (Off, Mouse, Right stick) and its sensitivity (GyroOptions.swift).
    case gyro, gyroSensitivity
    /// The controller map's mode (Pad, Keys & mouse, Custom): only while a controller is connected.
    case controllerMap

    /// The rows shown: the D-pad's and Right stick's only while they change what is drawn
    /// (`ControlsState.hasGamepadOptions`), the controller map's only with a controller connected.
    public static func shown(controller: Bool, state: ControlsState) -> [QuickMenuControlsRow] {
        allCases.filter { r in
            switch r {
            case .dpad, .rightStick: state.hasGamepadOptions
            case .controllerMap: controller
            default: true
            }
        }
    }

    public var title: String {
        switch self {
        case .layout: "On-screen controls"
        case .dpad: "D-pad"
        case .rightStick: "Right stick"
        case .opacity: "Opacity"
        case .gyro: "Gyro aim"
        case .gyroSensitivity: "Sensitivity"
        case .controllerMap: "Controller"
        }
    }
}

public struct QuickMenu: Equatable, Sendable {
    /// The ringed row; the menu opens on Resume.
    public private(set) var ring: QuickMenuItem = .resume
    /// The Controls panel's ringed row while it is open; nil while the ring is on the rows.
    public private(set) var panel: QuickMenuControlsRow?

    public init() {}

    /// Up and down move the ring (in the panel while it is open, along `rows`, the ones shown), stopping at the ends.
    public mutating func move(down: Bool, rows: [QuickMenuControlsRow] = QuickMenuControlsRow.allCases) {
        if let p = panel {
            // A row no longer shown (the controller went): the last one shown.
            guard let at = rows.firstIndex(of: p) else { panel = rows.last; return }
            let i = at + (down ? 1 : -1)
            if rows.indices.contains(i) { panel = rows[i] }
            return
        }
        let all = QuickMenuItem.allCases
        let i = all.firstIndex(of: ring)! + (down ? 1 : -1)
        if all.indices.contains(i) { ring = all[i] }
    }

    public mutating func ring(_ item: QuickMenuItem) {
        ring = item
        if item != .controls { panel = nil }
    }

    /// Controls chosen: the panel opens on its first row (or on `row`, a tap on it).
    public mutating func openPanel(_ row: QuickMenuControlsRow = .layout) {
        ring = .controls
        panel = row
    }

    /// B in the panel: the ring goes back to the Controls row.
    public mutating func closePanel() { panel = nil }

    /// The presses that take the ring from `from` to `to` (the driver's `menu:ITEM`): "up" or "down" each.
    public static func steps(from: QuickMenuItem, to: QuickMenuItem) -> [Bool] {
        let all = QuickMenuItem.allCases
        let d = all.firstIndex(of: to)! - all.firstIndex(of: from)!
        return Array(repeating: d > 0, count: abs(d))
    }

    /// The heading above the rows: `Playing · 42 min`.
    public static func playing(seconds: TimeInterval) -> String {
        "Playing · " + (seconds < 60 ? "just started" : PlayTime.format(seconds))
    }

    /// The controller row's value: `Xbox · 80%`, the name alone without a battery, `None`.
    /// `scriptedPad`: the dev build's scripted pad is connected; it is no GameController pad,
    /// so it has no name of its own and is `Scripted pad` when no real one is named.
    public static func controller(name: String?, battery: Int?, scriptedPad: Bool = false) -> String {
        guard let name else { return scriptedPad ? "Scripted pad" : "None" }
        return battery.map { "\(name) · \($0)%" } ?? name
    }
}
