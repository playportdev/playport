// SPDX-License-Identifier: GPL-3.0-or-later
// A title's screen (the UI's Play): landscape, a guest display mode at the
// panel's native pixels or the title's own screen (LaunchSettings, else its
// titles.json `screen`; HostIOKit Display.guestSize), the swap chain
// aspect-fitted rather than stretched, a Unity title asked to open full screen
// at that size (LaunchCoordinator), and presents free to run at the panel's
// refresh (120 Hz on ProMotion) instead of DXMT's 60 Hz lock. The player's
// frame rate limit (LaunchSettings) is the only cap: the game layer holds each
// frame to it (PacedMetalLayer, HostIO.swift). The size becomes
// MADEIRA_SCREEN_W/H, which the runtime's virtual monitor, metrics and mode
// list follow; the guest's monitor reports the panel's maximum rate
// (MADEIRA_SCREEN_HZ).

#if canImport(UIKit)
import Foundation
import HostIO
import HostIOKit
import QuartzCore
import UIKit

enum TitleScreen {
    /// What configure() chose, for the title's log.
    nonisolated(unsafe) private(set) static var summary = "not configured"

    /// Whether startDisplayLink ran: configure may run again for a later title.
    @MainActor private static var linked = false

    /// On the main thread, before the runtime reads its environment; again
    /// for each title a process starts, since the environment it sets is only
    /// read when the runtime starts. `title` is the title's screen spec
    /// (LaunchPlan.screen, or the player's choice), nil for the panel's;
    /// `frameLimit` the player's limit, 0 for none.
    @MainActor
    static func configure(title: String? = nil, frameLimit: Int = 0) {
        let px = UIScreen.main.nativeBounds.size
        let screen: String
        if let (w, h) = Display.guestSize(panelLong: Int(px.width), panelShort: Int(px.height), spec: title) {
            setenv("MADEIRA_SCREEN_W", String(w), 1)
            setenv("MADEIRA_SCREEN_H", String(h), 1)
            screen = "\(w)x\(h)" + (title.map { " (the title's screen \($0))" } ?? "")
        } else {
            screen = "\(title ?? "") not understood; the runtime's 1024x768"
        }
        madeira_set_vsync_locked(0)
        PacedMetalLayer.limit(fps: frameLimit)
        // The refresh the guest's monitor reports (patches/madeira-unix/0011-win32u-report-the-host-panel-s-refresh-rate-for-the-.patch).
        let hz = UIScreen.main.maximumFramesPerSecond
        setenv("MADEIRA_SCREEN_HZ", String(hz), 0)
        if !linked {
            linked = true
            startDisplayLink()
        }
        summary = "screen \(screen) (panel \(Int(px.width))x\(Int(px.height)) px), landscape, swap chain aspect-fitted, "
            + "presents free-running, display link asks for up to \(hz) Hz"
            + (frameLimit > 0 ? ", frames limited to \(frameLimit) FPS" : ", no frame rate limit")
            + ", guest monitor \(ProcessInfo.processInfo.environment["MADEIRA_SCREEN_HZ"] ?? "60") Hz"
    }

    /// ProMotion keeps a CAMetalLayer at 60 Hz unless the app asks for more:
    /// CADisableMinimumFrameDurationOnPhone (Info.plist) and a display link's
    /// preferred range. The link does no work; it only states the rate.
    @MainActor
    private static func startDisplayLink() {
        let link = CADisplayLink(target: Tick.shared, selector: #selector(Tick.tick))
        let top = Float(UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, top), maximum: top, preferred: top)
        link.add(to: .main, forMode: .common)
    }

    private final class Tick: NSObject, Sendable {
        static let shared = Tick()
        @objc func tick() {}
    }
}
#endif
