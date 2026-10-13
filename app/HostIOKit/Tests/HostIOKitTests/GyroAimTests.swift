// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import HostIOKit

/// GyroAim (docs/plans/2026-10-09-touch-controls.md, phase 2): synthetic rate
/// sequences at 256 Hz (a step of 1/256 s, so the windows' edges are exact).
final class GyroAimTests: XCTestCase {
    static let hz = 256.0
    static let upright = GyroVector(x: 0, y: -1, z: 0)
    static let degrees = 180 / Double.pi

    /// A deterministic noise source, -amplitude...amplitude per axis.
    struct Noise {
        var state: UInt64
        mutating func next(_ amplitude: Double) -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 11) / Double(1 << 53) * 2 - 1) * amplitude
        }
        mutating func vector(_ amplitude: Double) -> GyroVector {
            GyroVector(x: next(amplitude), y: next(amplitude), z: next(amplitude))
        }
    }

    /// Samples from `start` for `seconds`, each rate from `rate(t)`; the outputs.
    @discardableResult
    static func run(_ aim: inout GyroAim, from start: Double, seconds: Double, gravity: GyroVector = upright,
                    paused: Bool = false, rate: (Double) -> GyroVector) -> [GyroAimOutput] {
        let n = Int((seconds * hz).rounded())
        return (0..<n).map { i in
            let t = start + Double(i) / hz
            return aim.add(GyroSample(time: t, rate: rate(t), gravity: gravity), paused: paused)
        }
    }

    static func mouseSum(_ out: [GyroAimOutput]) -> (dx: Int, dy: Int) {
        out.reduce((0, 0)) { s, o in
            guard case .mouse(let dx, let dy) = o else { XCTFail("not mouse: \(o)"); return s }
            return (s.0 + Int(dx), s.1 + Int(dy))
        }
    }

    static func stick(_ o: GyroAimOutput?) -> (x: Double, y: Double) {
        guard case .rightStick(let x, let y)? = o else { XCTFail("not the right stick: \(String(describing: o))"); return (0, 0) }
        return (x, y)
    }

    func assertNear(_ a: GyroVector, _ b: GyroVector, _ accuracy: Double, _ message: String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, message, file: file, line: line)
    }

    func testStillnessCalibrationConvergesAndHoldsDuringMotion() {
        let bias = GyroVector(x: 0.01, y: -0.02, z: 0.015)
        var noise = Noise(state: 1)
        var aim = GyroAim(config: .init(output: .mouse))
        // Less than the first window of stillness: nothing learnt yet.
        Self.run(&aim, from: 0, seconds: 0.49) { _ in bias + noise.vector(0.003) }
        XCTAssertFalse(aim.calibrated)
        XCTAssertEqual(aim.bias, .zero)
        // Half a second still is enough for the first estimate (a pad just put down: touch controls 2f).
        Self.run(&aim, from: 0.49, seconds: 0.02) { _ in bias + noise.vector(0.003) }
        XCTAssertTrue(aim.calibrated)
        assertNear(aim.bias, bias, 0.002, "the first estimate")
        Self.run(&aim, from: 0.51, seconds: 2.48) { _ in bias + noise.vector(0.003) }
        XCTAssertTrue(aim.calibrated)
        assertNear(aim.bias, bias, 0.001, "still: the bias converges")

        // Hand motion: a sway and tremor. Nothing is learnt.
        let learnt = aim.bias
        Self.run(&aim, from: 2.99, seconds: 3) { t in bias + GyroVector(x: 0.3 * sin(7 * t), y: 0.8 * sin(3 * t), z: 0.1 * cos(5 * t)) }
        XCTAssertEqual(aim.bias, learnt, "motion")
        // A steady pan faster than any bias: not learnt either.
        Self.run(&aim, from: 5.99, seconds: 2) { _ in bias + GyroVector(x: 0, y: 0.3, z: 0) }
        XCTAssertEqual(aim.bias, learnt, "a steady pan")
        // Tilting the device slowly and smoothly, as slow as a bias: gravity moves, so not learnt.
        var g = 0.0
        for i in 0..<768 {
            g += 0.03 / Self.hz
            _ = aim.add(GyroSample(time: 7.99 + Double(i) / Self.hz, rate: bias + GyroVector(x: 0.03, y: 0, z: 0),
                                   gravity: GyroVector(x: 0, y: -cos(g), z: -sin(g))))
        }
        XCTAssertLessThan((bias + GyroVector(x: 0.03, y: 0, z: 0)).length, GyroAim.maxBias)
        XCTAssertEqual(aim.bias, learnt, "tilting")

        // The bias moves (the gyro warms): still again, the new one is learnt.
        let warm = GyroVector(x: -0.005, y: 0.01, z: 0.02)
        Self.run(&aim, from: 11, seconds: 5) { _ in warm + noise.vector(0.003) }
        assertNear(aim.bias, warm, 0.001, "a new bias")
    }

    func testNoiseAtRestProducesNoDrift() {
        let bias = GyroVector(x: 0.01, y: -0.012, z: 0.008)
        var noise = Noise(state: 7)
        var aim = GyroAim(config: .init(output: .mouse))
        Self.run(&aim, from: 0, seconds: 2) { _ in bias + noise.vector(0.004) }
        XCTAssertTrue(aim.calibrated)
        let rest = Self.mouseSum(Self.run(&aim, from: 2, seconds: 20) { _ in bias + noise.vector(0.004) })
        XCTAssertLessThanOrEqual(abs(rest.dx), 2, "20 s at rest")
        XCTAssertLessThanOrEqual(abs(rest.dy), 2, "20 s at rest")
        // Uncalibrated, the same bias would have moved it some 260 counts in 20 s.
        XCTAssertGreaterThan(abs(bias.y) * Self.degrees * GyroAim.mouseCountsPerDegree * 20, 250)
    }

    /// Within the first still window (no calibration yet), so the steps are the gyro's alone.
    func testSmoothingOnlyAtSmallSpeeds() {
        let window = Int(GyroAim.smoothingWindow * Self.hz)   // 32 samples
        func first(after rate: Double) -> (x: Double, y: Double, settled: Double) {
            var aim = GyroAim(config: .init(output: .rightStick, turnAxis: .yaw))
            Self.run(&aim, from: 0, seconds: 0.2) { _ in .zero }
            let out = Self.run(&aim, from: 0.2, seconds: 0.25) { _ in GyroVector(x: 0, y: rate, z: 0) }
            XCTAssertFalse(aim.calibrated)
            let a = Self.stick(out.first), b = Self.stick(out.last)
            return (a.x, a.y, b.x)
        }
        func full(_ rate: Double) -> Double { -rate * Self.degrees / GyroAim.stickFullScale }

        // Slow (under smoothingLow): averaged over the window, then all of it.
        let slow = first(after: 0.02)
        XCTAssertEqual(slow.x, full(0.02) / Double(window), accuracy: 1e-12)
        XCTAssertEqual(slow.settled, full(0.02), accuracy: 1e-12)
        // Between the tiers: half direct, half averaged.
        let middle = first(after: 0.06)
        XCTAssertEqual(middle.x, full(0.06) * 0.5 + full(0.06) * 0.5 / Double(window), accuracy: 1e-12)
        XCTAssertEqual(middle.settled, full(0.06), accuracy: 1e-12)
        // Fast (over smoothingHigh): no delay at all.
        let fast = first(after: 0.5)
        XCTAssertEqual(fast.x, full(0.5), accuracy: 1e-12)
        XCTAssertEqual(fast.settled, full(0.5), accuracy: 1e-12)
    }

    /// Smoothing Off passes every sample as it is, even the slowest.
    func testSmoothingOffPassesSamplesStraightThrough() {
        var aim = GyroAim(config: .init(output: .rightStick, turnAxis: .yaw, smoothing: .off))
        Self.run(&aim, from: 0, seconds: 0.2) { _ in .zero }
        let rates = [0.005, 0.02, 0.05, 0.01, 0.3, 0.001]
        for (i, rate) in rates.enumerated() {
            let o = aim.add(GyroSample(time: 0.2 + Double(i) / Self.hz, rate: GyroVector(x: rate / 2, y: rate, z: 0)))
            let s = Self.stick(o)
            XCTAssertEqual(s.x, -rate * Self.degrees / GyroAim.stickFullScale, accuracy: 1e-12, "rate \(rate)")
            XCTAssertEqual(s.y, rate / 2 * Self.degrees / GyroAim.stickFullScale, accuracy: 1e-12, "rate \(rate)")
        }
    }

    /// On a slow ramp (under every threshold), Light lags less than Normal, and Off not at all.
    func testLightSmoothingLagsLessThanNormalOnASlowRamp() {
        func lag(_ smoothing: GyroSmoothing) -> Double {
            var aim = GyroAim(config: .init(output: .rightStick, turnAxis: .yaw, smoothing: smoothing))
            Self.run(&aim, from: 0, seconds: 0.2) { _ in .zero }
            // 0 to 0.015 rad/s over 0.3 s: slower than Light's lower threshold (0.02).
            let out = Self.run(&aim, from: 0.2, seconds: 0.3) { t in GyroVector(x: 0, y: 0.05 * (t - 0.2), z: 0) }
            XCTAssertFalse(aim.calibrated)
            let last = 0.05 * Double(Int((0.3 * Self.hz).rounded()) - 1) / Self.hz   // the last sample's rate
            return Self.stick(out.last).x - (-last * Self.degrees / GyroAim.stickFullScale)
        }
        let off = lag(.off), light = lag(.light), normal = lag(.normal)
        XCTAssertEqual(off, 0, accuracy: 1e-12)
        // The output trails the input (the stick's x is the negative turn, so a lag is positive).
        XCTAssertGreaterThan(light, 1e-6)
        XCTAssertGreaterThan(normal, light * 1.8, "Normal's window is twice Light's")
    }

    func testMouseDeltasAreProportionalAndTheRemainderIsCarried() {
        func total(rate: Double, seconds: Double, sensitivity: Double) -> (sum: Int, steps: [Int32], exact: Double) {
            var aim = GyroAim(config: .init(output: .mouse, turnAxis: .yaw, sensitivity: sensitivity))
            let out = Self.run(&aim, from: 0, seconds: seconds) { _ in GyroVector(x: 0, y: rate, z: 0) }
            let steps = out.map { o -> Int32 in if case .mouse(let dx, _) = o { return dx }; return 0 }
            // The first sample has no interval before it.
            let exact = -rate * Self.degrees * GyroAim.mouseCountsPerDegree * sensitivity * (seconds * Self.hz - 1) / Self.hz
            return (Self.mouseSum(out).dx, steps, exact)
        }
        // 0.1 rad/s for 3 s: under one count per sample, nothing lost.
        let slow = total(rate: 0.1, seconds: 3, sensitivity: 1)
        XCTAssertEqual(slow.sum, Int(slow.exact.rounded(.towardZero)))
        XCTAssertTrue(slow.steps.allSatisfy { $0 == 0 || $0 == -1 })
        XCTAssertGreaterThan(slow.steps.filter { $0 == -1 }.count, 300)
        // Linear: twice the rate or twice the sensitivity, twice the motion; no acceleration.
        let fast = total(rate: 1, seconds: 3, sensitivity: 1)
        XCTAssertEqual(fast.sum, Int(fast.exact.rounded(.towardZero)))
        XCTAssertEqual(Double(fast.sum), slow.exact * 10, accuracy: 1)
        let twice = total(rate: 1, seconds: 3, sensitivity: 2)
        XCTAssertEqual(twice.sum, Int(twice.exact.rounded(.towardZero)))
        XCTAssertEqual(Double(twice.sum), fast.exact * 2, accuracy: 1)
        // A long run at an awkward rate: still exact to the count.
        let long = total(rate: -0.37, seconds: 60, sensitivity: 0.7)
        XCTAssertEqual(long.sum, Int(long.exact.rounded(.towardZero)))
    }

    func testDirectionsInvertAndVerticalRatio() {
        func out(_ rate: GyroVector, _ config: GyroAim.Config) -> GyroAimOutput {
            var aim = GyroAim(config: config)
            return Self.run(&aim, from: 0, seconds: 0.25) { _ in rate }.last!
        }
        let left = GyroVector(x: 0, y: 1, z: 0), up = GyroVector(x: 1, y: 0, z: 0)
        let stick = GyroAim.Config(output: .rightStick, turnAxis: .yaw, sensitivity: 0.5)
        let k = Self.degrees * 0.5 / GyroAim.stickFullScale   // ≈ 0.16 per rad/s
        // Turning left is the stick left; tilting up is the stick up.
        XCTAssertEqual(Self.stick(out(left, stick)).x, -k, accuracy: 1e-12)
        XCTAssertEqual(Self.stick(out(up, stick)).y, k, accuracy: 1e-12)
        var c = stick
        c.invertX = true
        XCTAssertEqual(Self.stick(out(left, c)).x, k, accuracy: 1e-12)
        XCTAssertEqual(Self.stick(out(up, c)).y, k, accuracy: 1e-12)
        c.invertY = true
        c.verticalRatio = 0.5
        XCTAssertEqual(Self.stick(out(up, c)).y, -k / 2, accuracy: 1e-12)
        XCTAssertEqual(Self.stick(out(left, c)).x, k, accuracy: 1e-12)
        // A deflection is at most 1.
        let hard = Self.stick(out(GyroVector(x: 10, y: 10, z: 0), stick))
        XCTAssertEqual((hard.x * hard.x + hard.y * hard.y).squareRoot(), 1, accuracy: 1e-12)
        // The mouse: left is -x, up is -y (Windows' +y is down).
        if case .mouse(let dx, let dy) = out(left, .init(output: .mouse, turnAxis: .yaw)) {
            XCTAssertLessThan(dx, 0); XCTAssertEqual(dy, 0)
        } else { XCTFail("mouse") }
        if case .mouse(let dx, let dy) = out(up, .init(output: .mouse, verticalRatio: 0.5, invertY: true)) {
            XCTAssertEqual(dx, 0); XCTAssertGreaterThan(dy, 0)
        } else { XCTFail("mouse") }
        // Off: nothing.
        XCTAssertEqual(out(left, .init(output: .off)), GyroAimOutput.none)
    }

    /// The right stick's anti-dead-zone (Portal 2 ate deflections of 0.33 and below: touch controls 2d).
    func testTheAntiDeadZoneStartsTheStickPastTheGamesDeadZone() {
        let a = 0.27
        func last(_ rate: GyroVector, _ adz: Double, sensitivity: Double = 1) -> (x: Double, y: Double) {
            var aim = GyroAim(config: .init(output: .rightStick, turnAxis: .yaw, sensitivity: sensitivity, antiDeadZone: adz))
            return Self.stick(Self.run(&aim, from: 0, seconds: 0.25) { _ in rate }.last)
        }
        func length(_ p: (x: Double, y: Double)) -> Double { (p.x * p.x + p.y * p.y).squareRoot() }
        // Zero stays zero, and a still device's residual under stickRest rests too.
        XCTAssertEqual(GyroAim.past(antiDeadZone: a, x: 0, y: 0), .rightStick(x: 0, y: 0))
        let residual = GyroAim.stickRest * 0.9 * GyroAim.stickFullScale / Self.degrees   // rad/s
        XCTAssertEqual(length(last(GyroVector(x: 0, y: residual, z: 0), a)), 0)
        // A tiny turn jumps just past the anti-dead-zone, in its own direction (turning left: the stick left).
        let tiny = last(GyroVector(x: 0, y: 0.02, z: 0), a)
        let d = 0.02 * Self.degrees / GyroAim.stickFullScale
        XCTAssertEqual(tiny.x, -(a + d * (1 - a)), accuracy: 1e-12)
        XCTAssertEqual(tiny.y, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(length(tiny), a)
        // Full stays full.
        XCTAssertEqual(length(last(GyroVector(x: 0, y: 10, z: 0), a)), 1, accuracy: 1e-12)
        let unit = Self.stick(GyroAim.past(antiDeadZone: a, x: 0.6, y: -0.8))
        XCTAssertEqual(unit.x, 0.6, accuracy: 1e-12)
        XCTAssertEqual(unit.y, -0.8, accuracy: 1e-12)
        // The direction is kept: a diagonal is scaled along itself.
        let diagonal = last(GyroVector(x: 0.3, y: -0.4, z: 0), a)
        let plain = last(GyroVector(x: 0.3, y: -0.4, z: 0), 0)
        XCTAssertEqual(diagonal.x / diagonal.y, plain.x / plain.y, accuracy: 1e-9)
        XCTAssertEqual(length(diagonal), a + length(plain) * (1 - a), accuracy: 1e-9)
        // None: as before.
        XCTAssertEqual(last(GyroVector(x: 0, y: 0.02, z: 0), 0).x, -d, accuracy: 1e-12)
        // Mouse output ignores it.
        var mouse = GyroAim(config: .init(output: .mouse, turnAxis: .yaw, antiDeadZone: a))
        XCTAssertEqual(Self.mouseSum(Self.run(&mouse, from: 0, seconds: 0.25) { _ in .zero }).dx, 0)

        // Through the mixer: added to the physical stick and clamped.
        var m = InputMixer()
        var p = PadValues()
        p.rx = 20000
        _ = m.physical(slot: 0, p)
        guard case .set(let v) = m.gyro(GyroAim.past(antiDeadZone: a, x: 0.5, y: 0)).slot0 else { return XCTFail("set") }
        XCTAssertEqual(v.rx, 32767)
        guard case .set(let back) = m.gyro(GyroAim.past(antiDeadZone: a, x: 0, y: 0)).slot0 else { return XCTFail("set") }
        XCTAssertEqual(back.rx, 20000)
    }

    /// The phone tilted back 45°: a turn about the world's vertical shows on both its y and z.
    func testPlayerSpaceYawAndRollOnATiltedGravity() {
        let s = 0.5.squareRoot()
        let tilted = GyroVector(x: 0, y: -s, z: -s)
        let worldTurn = GyroVector(x: 0, y: s, z: s)          // 1 rad/s about the world's up
        let ownYaw = GyroVector(x: 0, y: 1, z: 0)
        let ownRoll = GyroVector(x: 0, y: 0, z: 1)
        func turn(_ axis: GyroTurnAxis, _ rate: GyroVector, _ gravity: GyroVector) -> Double {
            var aim = GyroAim(config: .init(output: .rightStick, turnAxis: axis))
            let o = Self.run(&aim, from: 0, seconds: 0.25, gravity: gravity) { _ in rate }.last
            return -Self.stick(o).x * GyroAim.stickFullScale / Self.degrees   // back to rad/s, + left
        }
        // Player space turns fully however the phone is tilted; yaw and roll see part of it.
        XCTAssertEqual(turn(.playerSpace, worldTurn, tilted), 1, accuracy: 1e-9)
        XCTAssertEqual(turn(.yaw, worldTurn, tilted), s, accuracy: 1e-9)
        XCTAssertEqual(turn(.roll, worldTurn, tilted), s, accuracy: 1e-9)
        // Upright, player space is yaw; a roll does not turn it.
        XCTAssertEqual(turn(.playerSpace, ownYaw, Self.upright), 1, accuracy: 1e-9)
        XCTAssertEqual(turn(.playerSpace, ownRoll, Self.upright), 0, accuracy: 1e-9)
        XCTAssertEqual(turn(.yaw, ownRoll, Self.upright), 0, accuracy: 1e-9)
        XCTAssertEqual(turn(.roll, ownRoll, Self.upright), 1, accuracy: 1e-9)
        // Tilted 30°: the relax factor lets the device's own yaw turn fully, its roll partly.
        let thirty = GyroVector(x: 0, y: -cos(Double.pi / 6), z: -sin(Double.pi / 6))
        XCTAssertEqual(turn(.playerSpace, ownYaw, thirty), 1, accuracy: 1e-9)
        XCTAssertEqual(turn(.playerSpace, ownRoll, thirty), 0.5 * GyroAim.playerSpaceRelax, accuracy: 1e-9)
        // Gravity's length does not matter; none at all falls back to yaw.
        XCTAssertEqual(turn(.playerSpace, worldTurn, tilted * 9.81), 1, accuracy: 1e-9)
        XCTAssertEqual(turn(.playerSpace, ownYaw, .zero), 1, accuracy: 1e-9)
        // Pitch is the device's x in every mode.
        for axis in GyroTurnAxis.allCases {
            var aim = GyroAim(config: .init(output: .rightStick, turnAxis: axis))
            let o = Self.stick(Self.run(&aim, from: 0, seconds: 0.25, gravity: tilted) { _ in GyroVector(x: 1, y: 0, z: 0) }.last)
            XCTAssertEqual(o.x, 0, accuracy: 1e-9, axis.rawValue)
            XCTAssertEqual(o.y, Self.degrees / GyroAim.stickFullScale, accuracy: 1e-9, axis.rawValue)
        }
    }

    func testThePauseButtonStopsTheAimWithNoJumpOnRelease() {
        let bias = GyroVector(x: 0.01, y: 0.02, z: 0)
        var noise = Noise(state: 3)
        var aim = GyroAim(config: .init(output: .mouse, turnAxis: .yaw))
        Self.run(&aim, from: 0, seconds: 2) { _ in bias + noise.vector(0.003) }
        let learnt = aim.bias
        // Held while the player swings the phone back to centre: nothing moves, nothing is learnt.
        let held = Self.run(&aim, from: 2, seconds: 1.5, paused: true) { t in bias + GyroVector(x: 0.5 * sin(4 * t), y: 2, z: 0) }
        XCTAssertTrue(held.allSatisfy { $0 == .mouse(dx: 0, dy: 0) })
        XCTAssertEqual(aim.bias, learnt)
        // Released at rest: no motion at all.
        let after = Self.mouseSum(Self.run(&aim, from: 3.5, seconds: 1) { _ in bias + noise.vector(0.003) })
        XCTAssertLessThanOrEqual(abs(after.dx) + abs(after.dy), 1)
        // Released mid-turn: the first sample moves only its own step's worth.
        _ = Self.run(&aim, from: 4.5, seconds: 0.5, paused: true) { _ in bias + GyroVector(x: 0, y: 2, z: 0) }
        let turn = Self.run(&aim, from: 5, seconds: 0.25) { _ in bias + GyroVector(x: 0, y: 2, z: 0) }
        guard case .mouse(let dx, _)? = turn.first else { return XCTFail("mouse") }
        XCTAssertLessThanOrEqual(abs(Double(dx)), 2 * Self.degrees * GyroAim.mouseCountsPerDegree / Self.hz + 1)

        // The right stick rests while held.
        var stick = GyroAim(config: .init(output: .rightStick))
        XCTAssertEqual(Self.run(&stick, from: 0, seconds: 0.1, paused: true) { _ in GyroVector(x: 1, y: 1, z: 0) }.last,
                       .rightStick(x: 0, y: 0))

        // What counts as held.
        var v = PadValues()
        v.buttons = PadMapping.leftShoulder
        v.leftTrigger = 31
        XCTAssertTrue(PadControl.lb.isHeld(in: v))
        XCTAssertTrue(PadControl.lt.isHeld(in: v))
        XCTAssertFalse(PadControl.rb.isHeld(in: v))
        v.leftTrigger = 30
        XCTAssertFalse(PadControl.lt.isHeld(in: v))
        XCTAssertFalse(PadControl.rightStick.isHeld(in: v))
    }

    func testAGapInTheSamplesMovesNothing() {
        var aim = GyroAim(config: .init(output: .mouse, turnAxis: .yaw))
        Self.run(&aim, from: 0, seconds: 0.5) { _ in GyroVector(x: 0, y: 1, z: 0) }
        // The sensors stopped for 2 s and came back turning.
        let back = aim.add(GyroSample(time: 2.5, rate: GyroVector(x: 0, y: 1, z: 0)))
        XCTAssertEqual(back, .mouse(dx: 0, dy: 0))
    }

    /// A NaN or infinite sample moves nothing and leaves the bias and the windows
    /// as they were: the aim after it is the same as with the sample left out.
    func testANonFiniteSampleIsDropped() {
        let bias = GyroVector(x: 0.01, y: -0.02, z: 0.015)
        let bad: [GyroSample] = [
            GyroSample(time: 1.0 + 0.5 / Self.hz, rate: GyroVector(x: .nan, y: 0, z: 0)),
            GyroSample(time: 1.0 + 0.5 / Self.hz, rate: GyroVector(x: 0, y: .infinity, z: 0)),
            GyroSample(time: 1.0 + 0.5 / Self.hz, rate: bias, gravity: GyroVector(x: 0, y: -.infinity, z: 0)),
            GyroSample(time: .nan, rate: bias),
        ]
        for output in [GyroOutput.mouse, .rightStick] {
            var clean = GyroAim(config: .init(output: output, turnAxis: .playerSpace)), dirty = clean
            Self.run(&clean, from: 0, seconds: 1) { _ in bias }
            Self.run(&dirty, from: 0, seconds: 1) { _ in bias }
            XCTAssertTrue(dirty.calibrated)
            for s in bad {
                let o = dirty.add(s)
                XCTAssertEqual(o, output == .mouse ? .mouse(dx: 0, dy: 0) : .rightStick(x: 0, y: 0))
            }
            XCTAssertEqual(dirty.bias, clean.bias)
            let turn = { (_: Double) in bias + GyroVector(x: 0.3, y: 0.6, z: 0) }
            XCTAssertEqual(Self.run(&dirty, from: 1 + 1 / Self.hz, seconds: 0.25, rate: turn),
                           Self.run(&clean, from: 1 + 1 / Self.hz, seconds: 0.25, rate: turn))
        }
        var off = GyroAim()
        XCTAssertEqual(off.add(GyroSample(time: 0, rate: GyroVector(x: .nan, y: .nan, z: .nan))), GyroAimOutput.none)
    }
}

/// GyroAim through InputMixer: the right stick added to slot 0, the mouse as relative moves.
final class GyroMixerTests: XCTestCase {
    func testGyroIsAddedToTheRightStickAndClamped() {
        var m = InputMixer()
        // No pad in slot 0: the gyro connects none.
        XCTAssertEqual(m.gyro(.rightStick(x: 0.5, y: 0)).slot0, .unchanged)
        XCTAssertNil(m.slot0)

        var p = PadValues()
        p.rx = 10000
        p.ry = -2000
        let out = m.physical(slot: 0, p)
        XCTAssertEqual(out.rx, 10000 + 16384)            // 0.5 × 32767, rounded
        XCTAssertEqual(out.ry, -2000)
        guard case .set(let v) = m.gyro(.rightStick(x: 0.5, y: -0.25)).slot0 else { return XCTFail("set") }
        XCTAssertEqual(v.rx, 26384)
        XCTAssertEqual(v.ry, -2000 - 8192)
        // Past the end: clamped either way.
        p.rx = 30000
        p.ry = -30000
        let clamped = m.physical(slot: 0, p)
        XCTAssertEqual(clamped.rx, 32767)
        XCTAssertEqual(clamped.ry, -32768)
        // The other slots never get it.
        XCTAssertEqual(m.physical(slot: 1, p), p)

        // With the touch controls' stick deflected too (the physical one resting): touch, then the gyro on top.
        var t = TouchOutput()
        t.pad.rx = 0.25
        p.rx = 0
        p.ry = 0
        _ = m.physical(slot: 0, p)
        _ = m.touch(t)
        XCTAssertEqual(m.slot0?.rx, Int16((0.25 * 32767).rounded()) + 16384)

        // Off: the stick is the pads' alone again.
        guard case .set(let back) = m.gyro(.none).slot0 else { return XCTFail("set") }
        XCTAssertEqual(back.rx, Int16((0.25 * 32767).rounded()))
        XCTAssertEqual(m.gyro(.none).slot0, .unchanged)
    }

    func testGyroAsAMouseIsRelativeMotion() {
        var m = InputMixer()
        _ = m.physical(slot: 0, PadValues())
        XCTAssertEqual(m.gyro(.mouse(dx: 3, dy: -2)).outputs, [.move(dx: 3, dy: -2)])
        XCTAssertEqual(m.gyro(.mouse(dx: 0, dy: 0)).outputs, [])
        // From the stick to the mouse: the stick comes back.
        _ = m.gyro(.rightStick(x: 1, y: 0))
        XCTAssertEqual(m.slot0?.rx, 32767)
        let r = m.gyro(.mouse(dx: 1, dy: 0))
        XCTAssertEqual(r.slot0, .set(PadValues()))
        XCTAssertEqual(r.outputs, [.move(dx: 1, dy: 0)])
    }
}
