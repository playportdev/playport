// SPDX-License-Identifier: GPL-3.0-or-later
// The phone's network as downloads see it (NWPathMonitor): connected or not,
// and expensive (cellular, or a hotspot shared over it). Settings › Downloads
// names it under "Download over cellular"; the download queue asks
// `mayDownload` (PlayportKit DownloadPreferences) before a job runs.

import Foundation
import Network
import PlayportKit

@MainActor
final class NetworkPath: ObservableObject {
    static let shared = NetworkPath()

    @Published private(set) var connected = true
    @Published private(set) var expensive = false
    @Published private(set) var cellular = false

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let connected = path.status == .satisfied
            let expensive = path.isExpensive
            let cellular = path.usesInterfaceType(.cellular)
            Task { @MainActor in
                let n = NetworkPath.shared
                if n.connected != connected { n.connected = connected }
                if n.expensive != expensive { n.expensive = expensive }
                if n.cellular != cellular { n.cellular = cellular }
            }
        }
        monitor.start(queue: DispatchQueue(label: "playport.network-path"))
    }

    /// Whether a download may run now, by Settings › Downloads.
    var mayDownload: Bool {
        DownloadPreferences.current.mayDownload(connected: connected, expensive: expensive)
    }

    /// Settings' line under Download over cellular.
    var summary: String {
        guard connected else { return "Not connected now" }
        if cellular || expensive { return "On cellular data now" }
        return "On Wi-Fi now"
    }
}
