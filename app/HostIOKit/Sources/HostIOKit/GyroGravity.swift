// SPDX-License-Identifier: GPL-3.0-or-later
/// Gravity for a controller that reports only its total acceleration
/// (GCMotion.hasGravityAndUserAcceleration false: a DualShock 4 or DualSense;
/// touch controls 2f): the hand's own accelerations taken out, so player space
/// turns about the world's vertical however the pad is shaken.
///
/// A complementary filter in the aim frame. Each sample turns the estimate by
/// the gyro's rotation over the step (a direction fixed in the world moves by
/// −ω × g in the device's frame), then pulls it toward the acceleration's
/// direction with time constant `timeConstant` (for the first such span, a
/// running mean of the accelerations so far), so a tilt is followed at
/// once through the gyro while a shake (a second or less) barely moves it. An
/// acceleration far from 1 g (`plausible`) is a shake or a fall, not gravity,
/// and corrects nothing.
///
/// Until `settle` seconds of plausible acceleration are in, and again once
/// none has come for `staleAfter` seconds, the estimate is zero: GyroAim's
/// player space is then yaw (its fallback for no gravity). A gap of more than
/// GyroAim.maxStep starts it over. A sample with a value that is not finite is
/// ignored: the estimate stays as it was.

import Foundation

public struct GyroGravityEstimate: Sendable {
    public static let timeConstant = 1.0     // s
    public static let plausible = 0.25       // g: |a| within 1 ± this corrects the estimate
    public static let settle = 0.25          // s of plausible acceleration before the estimate is used
    public static let staleAfter = 2.0       // s with no plausible acceleration before it is dropped

    /// The estimate, a unit vector; nil until the first plausible acceleration.
    private var g: GyroVector?
    private var last: Double?
    private var settled = 0.0
    private var lastPlausible: Double?

    public init() {}

    /// The sensors start again: the estimate starts over.
    public mutating func reset() { self = GyroGravityEstimate() }

    /// A sample: the rotation rate (rad/s) and total acceleration (in g, any
    /// sign convention the rate's frame shares; a pad at rest reads gravity
    /// as −up), both in the aim frame. Returns gravity in the aim frame, unit
    /// length, or zero while there is no estimate to use.
    public mutating func add(time: Double, rate: GyroVector, acceleration a: GyroVector) -> GyroVector {
        guard time.isFinite, rate.isFinite, a.isFinite else { return estimate(at: last) }
        var dt = 0.0
        if let l = last {
            if time - l > GyroAim.maxStep { g = nil; settled = 0; lastPlausible = nil } else { dt = max(0, time - l) }
        }
        last = max(last ?? time, time)
        if let e = g, dt > 0 { g = (e - rate.cross(e) * dt).unit }
        let n = a.length
        if n.isFinite, abs(n - 1) <= Self.plausible {
            let u = a * (1 / n)
            if let e = g {
                // A running mean of what has come for the first `timeConstant`, so the first sample's shake fades as fast as it can.
                let k = settled + dt < Self.timeConstant ? dt / (settled + dt) : 1 - exp(-dt / Self.timeConstant)
                g = (e + (u - e) * k).unit
                settled += dt
            } else {
                g = u
            }
            lastPlausible = time
        }
        return estimate(at: time)
    }

    /// The estimate at time `t` when it is settled and not stale, else zero.
    private func estimate(at t: Double?) -> GyroVector {
        guard let e = g, settled >= Self.settle, let t, let p = lastPlausible, t - p <= Self.staleAfter else { return .zero }
        return e
    }
}

extension GyroVector {
    func cross(_ b: GyroVector) -> GyroVector {
        GyroVector(x: y * b.z - z * b.y, y: z * b.x - x * b.z, z: x * b.y - y * b.x)
    }
}
