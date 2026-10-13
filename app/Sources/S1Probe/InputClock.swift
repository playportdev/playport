// SPDX-License-Identifier: GPL-3.0-or-later
// The one clock of the continuous input sources (docs/plans/2026-10-09-touch-controls.md,
// "Output"): a CADisplayLink on the main run loop while any source needs a tick,
// stopped when none does. The on-screen controls tick for a button's repeat
// (UI/TouchControlsView.swift, OnScreenControls); the controller map for a
// stick's mouse motion and the wheel's repeat (HostIO.controllerMapTick).
// Gyro aim has its sensors' own clock (GyroSensors.swift).

#if canImport(UIKit)
import QuartzCore
import UIKit

@MainActor
final class InputClock: NSObject {
    static let shared = InputClock()

    enum Source: Hashable {
        case touchControls, controllerMap
    }

    private var sources: Set<Source> = []
    /// Holds its target (this, which lives for the app) strongly.
    private var link: CADisplayLink?

    /// Whether `source` needs a tick on every frame.
    func need(_ source: Source, _ on: Bool) {
        if on { sources.insert(source) } else { sources.remove(source) }
        if !sources.isEmpty, link == nil {
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
        } else if sources.isEmpty, let l = link {
            l.invalidate()
            link = nil
        }
    }

    @objc private func tick() {
        if sources.contains(.touchControls) { OnScreenControls.shared.tick() }
        if sources.contains(.controllerMap) { HostIO.shared.controllerMapTick() }
    }
}
#endif
