// SPDX-License-Identifier: GPL-3.0-or-later
// Playport's in-game menu (QuickMenu.dc.html; S1Probe UI/InGameMenuView.swift):
// its rows in order, the ring moving along them, and the words each row shows.
// The controller side (the Home button held, the presses) is HostIOKit's
// QuickMenuControl. Controls opens a panel beside the rows (QuickMenuControls.dc.html):
// the game's on-screen layout, its d-pad and right stick, and their opacity, up and down between them, left
// and right (and A) to change one, B back to the rows.

import Foundation

public enum QuickMenuItem: String, CaseIterable, Sendable {
    case resume, controls, screenshot, overlay, controller, quit

    public var title: String {
        switch self {
        case .resume: "Resume"
        case .controls: "Controls"
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

    public var title: String {
        switch self {
        case .layout: "On-screen controls"
        case .dpad: "D-pad"
        case .rightStick: "Right stick"
        case .opacity: "Opacity"
        }
    }
}

public struct QuickMenu: Equatable, Sendable {
    /// The ringed row; the menu opens on Resume.
    public private(set) var ring: QuickMenuItem = .resume
    /// The Controls panel's ringed row while it is open; nil while the ring is on the rows.
    public private(set) var panel: QuickMenuControlsRow?

    public init() {}

    /// Up and down move the ring (in the panel while it is open), stopping at the ends.
    public mutating func move(down: Bool) {
        if let p = panel {
            let rows = QuickMenuControlsRow.allCases
            let i = rows.firstIndex(of: p)! + (down ? 1 : -1)
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
    public static func controller(name: String?, battery: Int?) -> String {
        guard let name else { return "None" }
        return battery.map { "\(name) · \($0)%" } ?? name
    }
}
