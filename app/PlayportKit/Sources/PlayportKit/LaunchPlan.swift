// SPDX-License-Identifier: GPL-3.0-or-later
// What one launch runs, in the terms TitleMode's run takes: the DOS path of
// the executable on drive C and the argument list. A title launches with its
// cohort arguments, madeira.cfg keys and screen (titles.json), none for any
// other title, with free-running presents; with no screen it gets the
// panel's native pixels (TitleScreen.swift's defaults).

import Foundation

public struct LaunchPlan: Equatable, Sendable {
    /// Relative to C:\, backslash-separated (`Games\Hollow Knight\hollow_knight.exe`).
    public var exe: String
    public var args: [String]
    /// madeira.cfg keys for this launch only (TitleConfig); empty for none.
    public var config: [String: String]
    /// The guest's screen as a screen spec (HostIOKit Display.guestSize:
    /// `native`, `<rows>`, `4:3`, `WxH`); nil for the panel's native pixels.
    public var screen: String?

    public init(exe: String, args: [String], config: [String: String] = [:], screen: String? = nil) {
        self.exe = exe
        self.args = args
        self.config = config
        self.screen = screen
    }

    /// A spec Display.guestSize can read, before the panel's size is known:
    /// `native`, `4:3`, 200-4320 rows, or WxH within 320-8192 × 200-8192.
    public static func validScreen(_ spec: String) -> Bool {
        let s = spec.lowercased()
        if s == "native" || s == "4:3" { return true }
        if s.allSatisfy(\.isASCII), let rows = Int(s) { return (200...4320).contains(rows) }
        let parts = s.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let w = Int(parts[0]), let h = Int(parts[1]) else { return false }
        return (320...8192).contains(w) && (200...8192).contains(h)
    }

    public static func make(installDir: String, executable: String, arguments: [String],
                            config: [String: String] = [:], screen: String? = nil) throws -> LaunchPlan {
        let parts = [installDir] + executable
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard !installDir.isEmpty, !executable.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") })
        else { throw LaunchPlanError.badPath(installDir + "\\" + executable) }
        try TitleConfig.validate(config)
        if let screen, !validScreen(screen) { throw LaunchPlanError.badScreen(screen) }
        return LaunchPlan(exe: (["Games"] + parts).joined(separator: "\\"), args: arguments, config: config,
                          screen: screen)
    }
}

public enum LaunchPlanError: Error, Equatable, CustomStringConvertible {
    case badPath(String)
    case badConfig(String)
    case badScreen(String)

    public var description: String {
        switch self {
        case .badPath(let p): "not a path inside C:\\Games: \(p)"
        case .badConfig(let k): "not a madeira.cfg key = value line: \(k)"
        case .badScreen(let s): "not a screen (native, <rows>, 4:3 or WxH): \(s)"
        }
    }
}
