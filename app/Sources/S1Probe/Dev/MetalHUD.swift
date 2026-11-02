// SPDX-License-Identifier: GPL-3.0-or-later
// Apple's Metal performance HUD over a game, dev builds only (a release build
// has the performance overlay, UI/PerformanceOverlay.swift): Settings ›
// Developer › Metal HUD, on unless turned off. Metal loads the HUD
// (libMetalMetricsInterpose, which costs every encoder CPU time even with the
// HUD hidden) only when MTL_HUD_ENABLED=1 is in the environment as the process
// starts, so the app sets it then (PlayportApp) only when the setting is on,
// and has Metal log the HUD's figures once a second (MTL_HUD_LOG_ENABLED;
// `pp perf` reads them); each game layer then shows it. A setting changed
// takes effect at the app's next start (`pp perf` sets it in a launch of its
// own). A process launched with its own MTL_HUD_ENABLED keeps what that says.

import QuartzCore

enum MetalHUD {
    static let key = "metalHUD"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    private static let inherited = ProcessInfo.processInfo.environment["MTL_HUD_ENABLED"]

    /// Metal loaded the HUD in this process: the setting was on at loadAtStart.
    nonisolated(unsafe) private static var loaded = false

    /// Before anything creates a Metal device.
    static func loadAtStart() {
        guard inherited == nil, enabled else { return }
        setenv("MTL_HUD_ENABLED", "1", 1)
        setenv("MTL_HUD_LOG_ENABLED", "1", 1)
        loaded = true
    }

    static func show(on layer: CAMetalLayer) {
        guard inherited == nil else { return HostIO.log("hostio: Metal HUD from the launch environment") }
        guard loaded else { return }
        // Turned off since the start: loaded, but hidden.
        layer.developerHUDProperties = ["mode": enabled ? "default" : "off"]
        HostIO.log("hostio: Metal HUD " + (enabled ? "on" : "off"))
    }
}
