// SPDX-License-Identifier: GPL-3.0-or-later
/// Gyro aim's sources (docs/plans/2026-10-09-touch-controls.md, "Gyro"): each
/// sensor's axes onto GyroAim's aim frame (x right, y up, z toward the
/// player, right-handed), and what S1Probe's GyroSensors does with the output.
///
/// - **The iPhone.** CoreMotion's device frame: x to the right of the screen
///   held in portrait, y to its top, z out of the screen. The aim frame
///   follows the interface orientation: in landscape the screen's right and
///   up are the device's ∓y and ±x. Rate and gravity rotate alike.
/// - **A controller.** GameController's motion frame for a controller held
///   flat (SDL reads it the same way): x to the right, y away from the
///   player, z up out of its face. Its up is the aim frame's y and its z the
///   aim frame's −z, so turning the controller about the world's vertical is
///   yaw whether the phone is landscape or not.
/// - **Mouse coalescing.** Mouse output goes to Winios's 256-event input
///   ring, which drops what does not fit while the game does not drain it.
///   GyroMouseCoalescer sends at most one move per `minInterval` (125 a
///   second): every sample of the iPhone's 100 Hz feed, every other one of a
///   faster controller's, the counts carried, never lost.
/// - **The log.** GyroActivity sums the output over `interval` seconds and
///   gives one line when anything moved, none while the aim is still: the
///   samples and their rate (the sensor's actual rate), the output, and for
///   the mouse the moves sent, their rate and the longest a move waited in the
///   coalescer (`lastDelay`), the measures phase 2d reads on the phone.

import Foundation

/// The interface orientation the game is shown in (UIInterfaceOrientation's cases).
public enum GyroScreenOrientation: String, Sendable, CaseIterable {
    case portrait, portraitUpsideDown
    /// UIInterfaceOrientation.landscapeLeft: the device's top on the right (Home indicator on the left).
    case landscapeLeft
    /// UIInterfaceOrientation.landscapeRight: the device's top on the left.
    case landscapeRight
}

public enum GyroFrame {
    /// A CoreMotion vector (rotation rate or gravity, device frame) in the aim frame for the screen's orientation.
    public static func phone(_ v: GyroVector, _ o: GyroScreenOrientation) -> GyroVector {
        switch o {
        case .portrait: v
        case .portraitUpsideDown: GyroVector(x: -v.x, y: -v.y, z: v.z)
        case .landscapeLeft: GyroVector(x: v.y, y: -v.x, z: v.z)
        case .landscapeRight: GyroVector(x: -v.y, y: v.x, z: v.z)
        }
    }

    /// A GameController motion vector (rotation rate, gravity or acceleration) in the aim frame.
    public static func controller(_ v: GyroVector) -> GyroVector {
        GyroVector(x: v.x, y: v.z, z: -v.y)
    }
}

/// Gyro mouse counts into at most one relative move per `minInterval` of sample time (less 10% for jitter).
public struct GyroMouseCoalescer: Sendable {
    public static let minInterval = 1.0 / 125
    private var dx = 0, dy = 0
    private var lastSent: Double?
    /// When the counts carried now began to wait.
    private var pendingSince: Double?
    /// How long the last move sent had waited, from its first sample's counts (the delay coalescing added), s.
    public private(set) var lastDelay = 0.0

    public init() {}

    /// A sample's counts at `time`: the move to send now, or nil (nothing due, or carried to a later sample).
    public mutating func add(dx: Int32, dy: Int32, time: Double) -> (dx: Int32, dy: Int32)? {
        self.dx += Int(dx)
        self.dy += Int(dy)
        guard self.dx != 0 || self.dy != 0 else { pendingSince = nil; return nil }
        if pendingSince == nil { pendingSince = time }
        // 10% slack: samples' timestamps jitter, and two of a 250 Hz feed are one interval apart.
        if let l = lastSent, time >= l, time - l < Self.minInterval * 0.9 { return nil }
        lastSent = time
        lastDelay = max(0, time - (pendingSince ?? time))
        pendingSince = nil
        defer { self.dx = 0; self.dy = 0 }
        return (Int32(clamping: self.dx), Int32(clamping: self.dy))
    }

    /// The sensors stopped: what is carried is dropped (the menu or the background took the game).
    public mutating func reset() { dx = 0; dy = 0; lastSent = nil; pendingSince = nil; lastDelay = 0 }
}

/// What gyro aim did lately, for the log: one line per `interval` with motion in it.
public struct GyroActivity: Sendable {
    public static let interval = 2.0
    /// The smallest right-stick deflection that counts as motion (0.01 at the line's precision).
    public static let stickMotion = 0.005
    private var since: Double?
    private var samples = 0
    private var dx = 0, dy = 0
    private var peak = 0.0
    private var stick = false
    private var moved = false
    /// Mouse moves sent to the guest (after coalescing), and the longest a move waited.
    private var moves = 0
    private var maxDelay = 0.0

    public init() {}

    /// A coalesced mouse move went to the guest, `delay` s after its first counts (GyroMouseCoalescer.lastDelay).
    public mutating func sent(delay: Double) {
        moves += 1
        maxDelay = max(maxDelay, delay)
    }

    /// One sample's output; a line (without the `gyro: ` prefix) once `interval` has passed with motion in it.
    public mutating func add(_ o: GyroAimOutput, time: Double) -> String? {
        if since == nil || time < since! { since = time }
        samples += 1
        switch o {
        case .none: break
        case .mouse(let x, let y):
            dx += Int(x); dy += Int(y)
            if x != 0 || y != 0 { moved = true }
        case .rightStick(let x, let y):
            stick = true
            let l = (x * x + y * y).squareRoot()
            peak = max(peak, l)
            // A still device's residual noise leaves the stick a few hundred-thousandths off
            // centre: motion is a deflection the line's two decimals show.
            if l >= Self.stickMotion { moved = true }
        }
        guard let s = since, time - s >= Self.interval else { return nil }
        defer { self = GyroActivity(); since = time }
        guard moved else { return nil }
        let what = stick ? String(format: "right stick peak %.2f", peak) : "mouse dx=\(dx) dy=\(dy)"
        let span = time - s
        let sent = moves == 0 ? ""
            : String(format: "; %d moves (%.0f/s), coalescing delay max %.1f ms", moves, Double(moves) / span, maxDelay * 1000)
        return String(format: "%.1f s, %d samples (%.0f/s), ", span, samples, Double(samples) / span) + what + sent
    }

    /// The sensors stopped: start the next interval afresh.
    public mutating func reset() { self = GyroActivity() }
}
