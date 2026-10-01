// SPDX-License-Identifier: GPL-3.0-or-later
// Playport's in-game menu (QuickMenu.dc.html; S1Probe UI/InGameMenuView.swift):
// its rows in order, the ring moving along them, and the words each row shows.
// The controller side (the Home button held, the presses) is HostIOKit's
// QuickMenuControl.

import Foundation

public enum QuickMenuItem: String, CaseIterable, Sendable {
    case resume, screenshot, overlay, controller, quit

    public var title: String {
        switch self {
        case .resume: "Resume"
        case .screenshot: "Screenshot"
        case .overlay: "Performance overlay"
        case .controller: "Controller"
        case .quit: "Quit game"
        }
    }
}

public struct QuickMenu: Equatable, Sendable {
    /// The ringed row; the menu opens on Resume.
    public private(set) var ring: QuickMenuItem = .resume

    public init() {}

    /// Up and down move the ring, stopping at the ends; nothing else moves it.
    public mutating func move(down: Bool) {
        let all = QuickMenuItem.allCases
        let i = all.firstIndex(of: ring)! + (down ? 1 : -1)
        if all.indices.contains(i) { ring = all[i] }
    }

    public mutating func ring(_ item: QuickMenuItem) { ring = item }

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
