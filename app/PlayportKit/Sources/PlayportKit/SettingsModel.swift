// SPDX-License-Identifier: GPL-3.0-or-later
// Settings' non-UI logic (docs/design/2026-09-28-gamepad-ui/Settings.dc.html,
// SettingsGraphics.dc.html; UI/SettingsView.swift draws it):
//
// - SettingsSection: the sections down the left, in order, and the names a
//   dev build's `open:settings#NAME` takes for them.
// - SettingSteps: a value row changed with left and right ("‹ 720p ›"),
//   whose default is one of its values and reads "Default · 720p"; picking
//   the default stores nil, so the row follows Playport's default again.
// - DownloadPreferences: the Downloads section's switches, in UserDefaults,
//   and whether a download may run on the network the phone has now.

import Foundation

public enum SettingsSection: String, CaseIterable, Sendable {
    case steam, graphics, downloads, controllers, storage, setup, about
    /// Dev builds only: diagnostics, simulations, probes and logs.
    case developer

    public var title: String {
        switch self {
        case .steam: "Steam account"
        case .graphics: "Graphics"
        case .downloads: "Downloads"
        case .controllers: "Controllers"
        case .storage: "Storage"
        case .setup: "Setup check"
        case .about: "About"
        case .developer: "Developer"
        }
    }

    /// The sections a build shows, top to bottom.
    public static func all(developer: Bool) -> [SettingsSection] {
        allCases.filter { developer || $0 != .developer }
    }

    /// The section `open:settings#NAME` names: a section's own name, or what
    /// used to be a section of the old Settings list (account, jit, memory,
    /// diagnostics, pairing, probes, logs).
    public static func named(_ name: String) -> SettingsSection? {
        if let s = SettingsSection(rawValue: name) { return s }
        switch name {
        case "account": return .steam
        case "jit", "memory": return .setup
        case "diagnostics", "pairing", "probes", "logs": return .developer
        default: return nil
        }
    }

    /// Up (-1) or down (+1) the list, stopping at its ends.
    public func step(_ by: Int, developer: Bool) -> SettingsSection {
        let list = Self.all(developer: developer)
        guard let i = list.firstIndex(of: self) else { return list[0] }
        return list[max(0, min(list.count - 1, i + by))]
    }
}

/// A value row's choices, in the order left to right, one of them the default.
public struct SettingSteps<Value: Equatable>: Sendable where Value: Sendable {
    public let values: [Value]
    public let defaultValue: Value

    /// `values` without the default gets it put first.
    public init(values: [Value], defaultValue: Value) {
        self.values = values.contains(defaultValue) ? values : [defaultValue] + values
        self.defaultValue = defaultValue
    }

    /// Where a stored value sits: nil (and a value no longer offered) is the default.
    public func index(of stored: Value?) -> Int {
        let v = stored.flatMap { s in values.contains(s) ? s : nil } ?? defaultValue
        return values.firstIndex(of: v) ?? 0
    }

    /// What to store for the value at `i`: nil for the default, so it follows Playport's.
    public func stored(at i: Int) -> Value? {
        guard values.indices.contains(i) else { return nil }
        return values[i] == defaultValue ? nil : values[i]
    }

    /// The row's labels: the default's reads "Default · X".
    public func labels(_ name: (Value) -> String) -> [String] {
        values.map { $0 == defaultValue ? "Default · " + name($0) : name($0) }
    }
}

/// Settings › Downloads (Settings.dc.html). The download queue (SteamInstalls)
/// reads them from UserDefaults.standard by these keys; Steam Cloud's switch
/// is SteamAccountModel.cloudKey (`steamCloud`), as it was.
public struct DownloadPreferences: Equatable, Sendable {
    /// Queue a game's update when Steam has a new version (default on).
    public static let autoUpdateKey = "downloads.autoUpdate"
    /// Download over cellular data too; off, only on Wi-Fi (default off).
    public static let cellularKey = "downloads.cellular"
    /// Download mode: dim the screen after a minute without input while downloading (default on).
    public static let dimKey = "downloads.dim"

    public var autoUpdate = true
    public var cellular = false
    public var dim = true

    public init(autoUpdate: Bool = true, cellular: Bool = false, dim: Bool = true) {
        self.autoUpdate = autoUpdate
        self.cellular = cellular
        self.dim = dim
    }

    /// What `defaults` holds, each key missing read as its default.
    public init(_ defaults: UserDefaults) {
        autoUpdate = defaults.object(forKey: Self.autoUpdateKey) as? Bool ?? true
        cellular = defaults.object(forKey: Self.cellularKey) as? Bool ?? false
        dim = defaults.object(forKey: Self.dimKey) as? Bool ?? true
    }

    public static var current: DownloadPreferences { DownloadPreferences(.standard) }

    /// Whether a download may run on the phone's network now: `expensive` is
    /// NWPath's isExpensive (cellular, or a hotspot shared over it).
    public func mayDownload(connected: Bool, expensive: Bool) -> Bool {
        connected && (cellular || !expensive)
    }
}
