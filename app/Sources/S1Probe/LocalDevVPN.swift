// SPDX-License-Identifier: GPL-3.0-or-later
// LocalDevVPN (App Store) carries the loopback tunnel to 10.7.0.1 that every
// JIT attach and the restart after a game use (docs/DEVICE.md, "JIT
// activation"). Playport cannot carry that tunnel itself: a packet tunnel
// needs the Network Extension entitlement, which a free team cannot have. It
// turns LocalDevVPN on for the player instead, when a Play, a restart or
// Settings finds the tunnel down.
//
// - LocalDevVPN's `localdevvpn://enable?scheme=playport` starts its tunnel and,
//   about a second later, opens `playport://`, which brings Playport back.
//   Playport's scheme (Info.plist CFBundleURLTypes) is that way back only: the
//   app ignores what a URL carries (RootView; decision 0012).
// - An open that fails means LocalDevVPN is not installed: its App Store page
//   opens instead. No URL scheme is queried (the release check forbids
//   LSApplicationQueriesSchemes, build/verify-ipa.py).
// - The first enable may stop at LocalDevVPN's own "Add VPN Configurations"
//   prompt; the caller then hears `.notConnected` and says so.
// - `tunnelUp` reads the route only: the source address the phone picks for
//   10.7.0.1 is on a utun interface. Another VPN that routes 10.7.0.1 reads as
//   up; the JIT step then fails with its own message, as before.

import Darwin
import SwiftUI
import UIKit

@MainActor
enum LocalDevVPN {
    enum Outcome: Equatable {
        /// Back within a minute, with the tunnel up.
        case connected
        /// Back within a minute, the tunnel still down after 3 s.
        case notConnected
        /// LocalDevVPN did not open; its App Store page did.
        case notInstalled
        /// Back after more than a minute: the player did something else meanwhile.
        case late
    }

    static let appStore = URL(string: "https://apps.apple.com/app/id6755608044")!
    private static let enable = URL(string: "localdevvpn://enable?scheme=playport")!
    private static let lateAfter: TimeInterval = 60

    private struct Pending: Sendable {
        let asked: Date
        var leftFront = false
        let then: @MainActor (Outcome) -> Void
    }
    private static var pending: Pending?

    nonisolated static func log(_ line: String) { WineHostRuntime.appendLog("vpn: " + line) }

    /// Opens LocalDevVPN to connect its tunnel. `then` runs once Playport is in
    /// front again, or at once with `.notInstalled`. A second call while one
    /// waits replaces it.
    static func connect(then: @escaping @MainActor (Outcome) -> Void) {
        log("tunnel down: opening LocalDevVPN to connect it")
        pending = Pending(asked: Date(), then: then)
        Task {
            guard !(await UIApplication.shared.open(enable, options: [:])) else { return }
            log("LocalDevVPN did not open (not installed?): opening its App Store page")
            pending = nil
            _ = await UIApplication.shared.open(appStore, options: [:])
            then(.notInstalled)
        }
    }

    /// RootView, on each scene phase: a return to the front after the switch
    /// to LocalDevVPN delivers the outcome.
    static func scenePhaseChanged(_ phase: ScenePhase) {
        guard var p = pending else { return }
        switch phase {
        case .background:
            p.leftFront = true
            pending = p
        case .active where p.leftFront:
            pending = nil
            let away = Date().timeIntervalSince(p.asked)
            if away > lateAfter {
                log(String(format: "back after %.0f s", away))
                p.then(.late)
                return
            }
            Task {
                var up = tunnelUp
                for _ in 0..<12 where !up {
                    try? await Task.sleep(for: .milliseconds(250))
                    up = tunnelUp
                }
                log(String(format: "back after %.1f s, tunnel ", Date().timeIntervalSince(p.asked)) + (up ? "up" : "still down"))
                p.then(up ? .connected : .notConnected)
            }
        default:
            break
        }
    }

    /// Whether the phone routes 10.7.0.1 through a tunnel interface now. A
    /// connected UDP socket sends nothing; its local address is the route's.
    nonisolated static var tunnelUp: Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var peer = sockaddr_in()
        peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        peer.sin_family = sa_family_t(AF_INET)
        peer.sin_port = in_port_t(49152).bigEndian
        guard inet_pton(AF_INET, AppRestart.host, &peer.sin_addr) == 1 else { return false }
        let connected = withUnsafePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return false }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return false }

        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if a == local.sin_addr.s_addr {
                return String(cString: ifa.pointee.ifa_name).hasPrefix("utun")
            }
        }
        return false
    }
}
