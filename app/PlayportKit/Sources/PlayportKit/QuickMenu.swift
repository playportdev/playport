// SPDX-License-Identifier: GPL-3.0-or-later
// Playport's in-game menu (QuickMenu.dc.html; S1Probe UI/InGameMenuView.swift):
// its rows in order, the ring moving along them, and the words each row shows.
// The controller side (the Home button held, the presses) is HostIOKit's
// QuickMenuControl.

import Foundation

public enum QuickMenuItem: String, CaseIterable, Sendable {
    case resume, screenshot, overlay
    /// The virtual gamepad's layout and its editor (a foldable's, S1Probe VirtualGamepad.swift).
    case padLayout, padEdit
    case controller, quit

    public var title: String {
        switch self {
        case .resume: "Resume"
        case .screenshot: "Screenshot"
        case .overlay: "Performance overlay"
        case .padLayout: "Gamepad layout"
        case .padEdit: "Edit gamepad layout"
        case .controller: "Controller"
        case .quit: "Quit game"
        }
    }
}

public struct QuickMenu: Equatable, Sendable {
    /// The ringed row; the menu opens on Resume.
    public private(set) var ring: QuickMenuItem = .resume
    /// The rows shown: the gamepad layout's only for a game with the virtual gamepad.
    public let items: [QuickMenuItem]

    public init(virtualPad: Bool = false) {
        items = QuickMenuItem.allCases.filter { virtualPad || ($0 != .padLayout && $0 != .padEdit) }
    }

    /// Up and down move the ring, stopping at the ends; nothing else moves it.
    public mutating func move(down: Bool) {
        let i = items.firstIndex(of: ring)! + (down ? 1 : -1)
        if items.indices.contains(i) { ring = items[i] }
    }

    public mutating func ring(_ item: QuickMenuItem) { if items.contains(item) { ring = item } }

    /// The presses that take the ring from where it is to `to` (the driver's `menu:ITEM`):
    /// "up" or "down" each; nil for a row not shown.
    public func steps(to: QuickMenuItem) -> [Bool]? {
        guard let t = items.firstIndex(of: to) else { return nil }
        let d = t - items.firstIndex(of: ring)!
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
