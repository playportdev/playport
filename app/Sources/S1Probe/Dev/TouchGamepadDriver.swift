// SPDX-License-Identifier: GPL-3.0-or-later
import HostIOKit
import Foundation

@MainActor
enum TouchGamepadDriver {
    /// touch:A+ls-left@500. Bounded holds always release, including cancellation.
    static func press(_ specification: String) async -> Bool {
        let parts = specification.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2, let first = parts.first, !first.isEmpty,
              let duration = parts.count == 2 ? Int(parts[1]) : 250,
              (1...10000).contains(duration),
              let view = TouchGamepadView.drivenView, view.active else { return false }
        let names = first.split(separator: "+", omittingEmptySubsequences: false)
        let controls = names.compactMap { control(String($0)) }
        guard controls.count == names.count else { return false }
        view.drive(controls)
        defer { view.reset() }
        do { try await Task.sleep(for: .milliseconds(duration)) } catch { return false }
        return true
    }

    private static func control(_ name: String) -> (TouchGamepad.Control, Float, Float)? {
        switch name.lowercased() {
        case "ls-left": return (.leftStick, -1, 0)
        case "ls-right": return (.leftStick, 1, 0)
        case "ls-up": return (.leftStick, 0, 1)
        case "ls-down": return (.leftStick, 0, -1)
        case "rs-left": return (.rightStick, -1, 0)
        case "rs-right": return (.rightStick, 1, 0)
        case "rs-up": return (.rightStick, 0, 1)
        case "rs-down": return (.rightStick, 0, -1)
        case "up": return (.up, 0, 0)
        case "down": return (.down, 0, 0)
        case "left": return (.left, 0, 0)
        case "right": return (.right, 0, 0)
        default:
            return TouchGamepad.Control.allCases.first { $0.rawValue.lowercased() == name.lowercased() }.map { ($0, 0, 0) }
        }
    }
}
