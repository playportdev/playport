// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import HostIOKit

/// GyroGravityEstimate (touch controls 2f): gravity for a pad that reports only
/// its total acceleration, at a DualShock 4's rate through GameController's
/// frame (GyroFrame.controller).
final class GyroGravityTests: XCTestCase {
    static let hz = 250.0

    /// A pad held normally, its face tilted `tilt` toward the player, in GameController's frame:
    /// the world's up, and what its accelerometer reads at rest (gravity, −up).
    static func held(tilt: Double) -> (up: GyroVector, rest: GyroVector) {
        let up = GyroVector(x: 0, y: sin(tilt), z: cos(tilt))
        return (up, up * -1)
    }

    /// The hand's shake: up to about 0.3 g on each axis, at a few hertz.
    static func shake(_ t: Double) -> GyroVector {
        GyroVector(x: 0.3 * sin(2 * .pi * 6 * t), y: 0.25 * cos(2 * .pi * 4 * t), z: 0.2 * sin(2 * .pi * 5 * t + 1))
    }

    func angle(_ a: GyroVector, _ b: GyroVector) -> Double {
        let c = (a.x * b.x + a.y * b.y + a.z * b.z) / (a.length * b.length)
        return acos(max(-1, min(1, c))) * 180 / .pi
    }

    /// Shaking a pad held still: the estimated gravity stays within 2° of the
    /// true one (raw acceleration swings by over 10°), so the turn read in player
    /// space from a turn with roll in it stays what the true gravity gives.
    func testTheTurnAxisStaysStableWhileThePadIsShaken() {
        let pad = Self.held(tilt: .pi / 4)
        let down = GyroFrame.controller(pad.rest)
        // 0.5 rad/s about the world's vertical with 1 rad/s of roll (about the pad's own forward axis).
        let turn = GyroFrame.controller(pad.up * 0.5 + GyroVector(x: 0, y: 1, z: 0))
        let truth = GyroAim.playerSpaceYaw(rate: turn, gravity: down)
        var g = GyroGravityEstimate()
        var worstAngle = 0.0, worstRawAngle = 0.0, worstTurn = 0.0
        for i in 0..<Int(3 * Self.hz) {
            let t = Double(i) / Self.hz
            let a = GyroFrame.controller(pad.rest + Self.shake(t))
            let est = g.add(time: t, rate: .zero, acceleration: a)
            guard t >= 1 else { continue }
            XCTAssertNotEqual(est, .zero)
            worstAngle = max(worstAngle, angle(est, down))
            worstRawAngle = max(worstRawAngle, angle(a, down))
            worstTurn = max(worstTurn, abs(GyroAim.playerSpaceYaw(rate: turn, gravity: est) - truth))
        }
        XCTAssertLessThan(worstAngle, 2, "degrees")
        XCTAssertGreaterThan(worstRawAngle, 10, "degrees")
        XCTAssertLessThan(worstTurn, 0.01 * abs(truth))
    }

    /// A quick tilt is followed through the gyro, not after the low-pass's second.
    func testATiltIsFollowedAtOnce() {
        var g = GyroGravityEstimate()
        var t = 0.0
        let step = 1 / Self.hz
        // At rest, flat, for a second.
        while t < 1 {
            _ = g.add(time: t, rate: .zero, acceleration: GyroFrame.controller(GyroVector(x: 0, y: 0, z: -1)))
            t += step
        }
        // Raise the far edge by 60° in 0.3 s (about the pad's x).
        let w = (Double.pi / 3) / 0.3
        var tilt = 0.0, worst = 0.0
        while tilt < .pi / 3 - 1e-9 {
            tilt = min(.pi / 3, tilt + w * step)
            // The world's down seen from the tilted pad.
            let down = GyroVector(x: 0, y: -sin(tilt), z: -cos(tilt))
            let est = g.add(time: t, rate: GyroFrame.controller(GyroVector(x: w, y: 0, z: 0)), acceleration: GyroFrame.controller(down))
            worst = max(worst, angle(est, GyroFrame.controller(down)))
            t += step
        }
        XCTAssertLessThan(worst, 1.0, "degrees behind the tilt")
    }

    /// Nothing to use before it settles, from a pad that reports no acceleration,
    /// or once no plausible acceleration has come for a while: player space is yaw then.
    func testNoEstimateIsZero() {
        var g = GyroGravityEstimate()
        let rest = GyroFrame.controller(GyroVector(x: 0, y: 0, z: -1))
        XCTAssertEqual(g.add(time: 0, rate: .zero, acceleration: rest), .zero)
        XCTAssertEqual(g.add(time: 0.1, rate: .zero, acceleration: rest), .zero)
        var t = 0.1
        while t < 0.4 { t += 0.004; _ = g.add(time: t, rate: .zero, acceleration: rest) }
        XCTAssertEqual(g.add(time: t, rate: .zero, acceleration: rest).y, -1, accuracy: 1e-9)
        // Free fall (or a pad that stops reporting): zero after staleAfter.
        var last = GyroVector.zero
        while t < 0.4 + GyroGravityEstimate.staleAfter + 0.1 { t += 0.004; last = g.add(time: t, rate: .zero, acceleration: .zero) }
        XCTAssertEqual(last, .zero)

        var none = GyroGravityEstimate()
        for i in 0..<500 { XCTAssertEqual(none.add(time: Double(i) / Self.hz, rate: .zero, acceleration: .zero), .zero) }
        // A gap (the sensors stopped) starts it over.
        var gap = GyroGravityEstimate()
        for i in 0...100 { _ = gap.add(time: Double(i) / Self.hz, rate: .zero, acceleration: rest) }
        XCTAssertEqual(gap.add(time: 2, rate: .zero, acceleration: rest), .zero)
    }

    /// A NaN or infinite rate, acceleration or time is ignored: the estimate stays as it was.
    func testANonFiniteSampleIsIgnored() {
        let rest = GyroFrame.controller(GyroVector(x: 0, y: 0, z: -1))
        var g = GyroGravityEstimate()
        var t = 0.0
        while t < 0.5 { t += 0.004; _ = g.add(time: t, rate: .zero, acceleration: rest) }
        let before = g.add(time: t, rate: .zero, acceleration: rest)
        XCTAssertNotEqual(before, .zero)
        XCTAssertEqual(g.add(time: t + 0.004, rate: GyroVector(x: .nan, y: 0, z: 0), acceleration: rest), before)
        XCTAssertEqual(g.add(time: t + 0.004, rate: .zero, acceleration: GyroVector(x: 0, y: .infinity, z: 0)), before)
        XCTAssertEqual(g.add(time: .nan, rate: .zero, acceleration: rest), before)
        let after = g.add(time: t + 0.004, rate: .zero, acceleration: rest)
        XCTAssertTrue(after.isFinite)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-9)
        var fresh = GyroGravityEstimate()
        XCTAssertEqual(fresh.add(time: 0, rate: .zero, acceleration: GyroVector(x: .nan, y: .nan, z: .nan)), .zero)
    }

    /// A pad held in the hands with a tremor too small to matter: GyroAim's first
    /// estimate comes within a second through the estimated gravity, while the raw
    /// acceleration's hand jitter (over the 1.1° gravity spread) never lets it.
    func testAPadHeldStillInTheHandsCalibrates() {
        let bias = GyroVector(x: 0.03, y: 0.0095, z: 0.036)   // the DualShock 4 in the owner's run (GameController's frame)
        let pad = Self.held(tilt: .pi / 6)
        func run(filtered: Bool) -> Double? {
            var aim = GyroAim(config: .init(output: .mouse))
            var g = GyroGravityEstimate()
            for i in 0..<Int(4 * Self.hz) {
                let t = Double(i) / Self.hz
                let tremor = GyroVector(x: 0.008 * sin(2 * .pi * 9 * t), y: 0.006 * cos(2 * .pi * 7 * t), z: 0.005 * sin(2 * .pi * 11 * t))
                let jitter = GyroVector(x: 0.03 * sin(2 * .pi * 8 * t), y: 0.025 * cos(2 * .pi * 6 * t), z: 0.02 * sin(2 * .pi * 9 * t))
                let rate = GyroFrame.controller(bias + tremor), a = GyroFrame.controller(pad.rest + jitter)
                let gravity = filtered ? g.add(time: t, rate: rate, acceleration: a) : a
                _ = aim.add(GyroSample(time: t, rate: rate, gravity: gravity))
                if aim.calibrated { return t }
            }
            return nil
        }
        let t = run(filtered: true)
        XCTAssertNotNil(t)
        XCTAssertLessThan(t ?? 99, 1.0)
        XCTAssertNil(run(filtered: false))
    }
}
