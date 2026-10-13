// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import HostIOKit

/// GyroSources.swift: each sensor's frame onto GyroAim's, the mouse coalescing,
/// the log's activity line, and GyroAim.restart.
final class GyroSourcesTests: XCTestCase {
    static let hz = 100.0

    func cross(_ a: GyroVector, _ b: GyroVector) -> GyroVector {
        GyroVector(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }

    /// Mouse counts summed over `seconds` of a constant device-frame rate, mapped by `map`.
    func mouse(rate: GyroVector, gravity: GyroVector, seconds: Double = 0.5, turnAxis: GyroTurnAxis = .playerSpace,
               map: (GyroVector) -> GyroVector) -> (dx: Int, dy: Int) {
        var aim = GyroAim(config: .init(output: .mouse, turnAxis: turnAxis))
        var sum = (dx: 0, dy: 0)
        for i in 0..<Int(seconds * Self.hz) {
            let o = aim.add(GyroSample(time: Double(i) / Self.hz, rate: map(rate), gravity: map(gravity)))
            if case .mouse(let dx, let dy) = o { sum.dx += Int(dx); sum.dy += Int(dy) }
        }
        return sum
    }

    func testEveryFrameMappingIsARotation() {
        let x = GyroVector(x: 1, y: 0, z: 0), y = GyroVector(x: 0, y: 1, z: 0), z = GyroVector(x: 0, y: 0, z: 1)
        let maps: [(String, (GyroVector) -> GyroVector)] =
            GyroScreenOrientation.allCases.map { o in (o.rawValue, { GyroFrame.phone($0, o) }) } + [("controller", GyroFrame.controller)]
        for (name, m) in maps {
            // Right-handed in, right-handed out: x × y = z survives the mapping.
            XCTAssertEqual(cross(m(x), m(y)), m(z), name)
            XCTAssertEqual(m(GyroVector(x: 0.1, y: -0.2, z: 0.3)).length, GyroVector(x: 0.1, y: -0.2, z: 0.3).length, accuracy: 1e-12, name)
        }
    }

    /// Held upright in landscape, gravity is the aim frame's down in either orientation.
    func testThePhoneHeldUprightInLandscape() {
        // Landscape right: the device's top on the left, so gravity runs along the device's -x.
        XCTAssertEqual(GyroFrame.phone(GyroVector(x: -1, y: 0, z: 0), .landscapeRight), GyroVector(x: 0, y: -1, z: 0))
        XCTAssertEqual(GyroFrame.phone(GyroVector(x: 1, y: 0, z: 0), .landscapeLeft), GyroVector(x: 0, y: -1, z: 0))
        XCTAssertEqual(GyroFrame.phone(GyroVector(x: 0, y: -1, z: 0), .portrait), GyroVector(x: 0, y: -1, z: 0))
        XCTAssertEqual(GyroFrame.phone(GyroVector(x: 0, y: 1, z: 0), .portraitUpsideDown), GyroVector(x: 0, y: -1, z: 0))
        // The screen's right edge: the device's -y in landscape right, +y in landscape left.
        XCTAssertEqual(GyroFrame.phone(GyroVector(x: 0, y: -1, z: 0), .landscapeRight), GyroVector(x: 1, y: 0, z: 0))
        XCTAssertEqual(GyroFrame.phone(GyroVector(x: 0, y: 1, z: 0), .landscapeLeft), GyroVector(x: 1, y: 0, z: 0))
    }

    /// Turning left about the world's vertical moves the mouse left, tilting the top
    /// edge back moves it up, in both landscape orientations and lying flat.
    func testThePhoneTurnsTheAimTheSameWayInBothLandscapes() {
        let w = 1.0   // rad/s
        for (o, up) in [(GyroScreenOrientation.landscapeRight, GyroVector(x: 1, y: 0, z: 0)),
                        (.landscapeLeft, GyroVector(x: -1, y: 0, z: 0))] {
            let gravity = up * -1
            // Left: positive rotation about the world's up.
            let left = mouse(rate: up * w, gravity: gravity) { GyroFrame.phone($0, o) }
            XCTAssertLessThan(left.dx, -100, o.rawValue)
            XCTAssertEqual(left.dy, 0, o.rawValue)
            XCTAssertEqual(mouse(rate: up * w, gravity: gravity, turnAxis: .yaw) { GyroFrame.phone($0, o) }.dx, left.dx, o.rawValue)
            // Up: positive rotation about the screen's right edge.
            let right = GyroFrame.phone(o == .landscapeRight ? GyroVector(x: 0, y: -1, z: 0) : GyroVector(x: 0, y: 1, z: 0), o)
            XCTAssertEqual(right, GyroVector(x: 1, y: 0, z: 0))
            let tilt = o == .landscapeRight ? GyroVector(x: 0, y: -w, z: 0) : GyroVector(x: 0, y: w, z: 0)
            let upward = mouse(rate: tilt, gravity: gravity) { GyroFrame.phone($0, o) }
            XCTAssertLessThan(upward.dy, -100, o.rawValue)
            XCTAssertEqual(upward.dx, 0, o.rawValue)
            // Flat on a table (screen up), turning it about the vertical (the device's z) turns the aim in player space.
            let flat = mouse(rate: GyroVector(x: 0, y: 0, z: w), gravity: GyroVector(x: 0, y: 0, z: -1)) { GyroFrame.phone($0, o) }
            XCTAssertEqual(flat.dx, left.dx, o.rawValue)
        }
    }

    /// A controller held flat: its z is up. Turning it about the vertical is yaw,
    /// raising its far edge is up; with no gravity reported player space is yaw.
    func testAControllerHeldFlat() {
        XCTAssertEqual(GyroFrame.controller(GyroVector(x: 0, y: 0, z: -1)), GyroVector(x: 0, y: -1, z: 0))
        let w = 1.0
        let flat = GyroVector(x: 0, y: 0, z: -1)
        let left = mouse(rate: GyroVector(x: 0, y: 0, z: w), gravity: flat, map: GyroFrame.controller)
        XCTAssertLessThan(left.dx, -100)
        XCTAssertEqual(left.dy, 0)
        let upward = mouse(rate: GyroVector(x: w, y: 0, z: 0), gravity: flat, map: GyroFrame.controller)
        XCTAssertLessThan(upward.dy, -100)
        XCTAssertEqual(upward.dx, 0)
        // No gravity (a pad that reports none): player space falls back to yaw.
        let blind = mouse(rate: GyroVector(x: 0, y: 0, z: w), gravity: .zero, map: GyroFrame.controller)
        XCTAssertEqual(blind.dx, left.dx)
        // Tilted toward the player by 30°, player space still turns fully about the vertical.
        let a = Double.pi / 6
        let tilted = GyroVector(x: 0, y: -sin(a), z: -cos(a))
        let about = GyroVector(x: 0, y: sin(a), z: cos(a)) * w
        XCTAssertEqual(Double(mouse(rate: about, gravity: tilted, map: GyroFrame.controller).dx), Double(left.dx), accuracy: 2)
    }

    func testTheCoalescerSendsAtMostOneMovePerInterval() {
        // The iPhone's 100 Hz: every sample is sent.
        var c = GyroMouseCoalescer()
        var sent = 0
        for i in 0..<100 { if c.add(dx: 3, dy: -1, time: Double(i) / 100) != nil { sent += 1 } }
        XCTAssertEqual(sent, 100)
        // A 250 Hz controller: every other one, nothing lost.
        c = GyroMouseCoalescer()
        var moves: [(dx: Int32, dy: Int32)] = []
        for i in 0..<250 { if let m = c.add(dx: 2, dy: 1, time: 1000 + Double(i) / 250) { moves.append(m) } }
        XCTAssertLessThanOrEqual(moves.count, 126)
        XCTAssertGreaterThanOrEqual(moves.count, 124)
        let carried = 500 - moves.reduce(0) { $0 + Int($1.dx) }
        XCTAssertLessThanOrEqual(carried, 2)
        XCTAssertEqual(moves.reduce(0) { $0 + Int($1.dy) } * 2, moves.reduce(0) { $0 + Int($1.dx) })
        // Nothing to send leaves the clock alone: the next motion goes at once.
        c = GyroMouseCoalescer()
        XCTAssertNotNil(c.add(dx: 1, dy: 0, time: 0))
        XCTAssertNil(c.add(dx: 0, dy: 0, time: 0.005))
        XCTAssertNil(c.add(dx: 1, dy: 0, time: 0.006))
        XCTAssertEqual(c.add(dx: 1, dy: 0, time: 0.009)?.dx, 2)
        // A stop drops what is carried.
        XCTAssertNil(c.add(dx: 5, dy: 5, time: 0.010))
        c.reset()
        XCTAssertEqual(c.add(dx: 1, dy: 0, time: 0.011)?.dx, 1)
    }

    func testTheActivityLineIsQuietWhileStill() {
        var a = GyroActivity()
        var lines: [String] = []
        for i in 0...500 { if let l = a.add(.mouse(dx: 0, dy: 0), time: Double(i) / 100) { lines.append(l) } }
        XCTAssertEqual(lines, [])
        for i in 501...900 { if let l = a.add(.mouse(dx: 2, dy: -1), time: Double(i) / 100) { lines.append(l) } }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("mouse dx="), lines[0])
        XCTAssertEqual(lines[1], "2.0 s, 200 samples, mouse dx=400 dy=-200")
        var s = GyroActivity()
        _ = s.add(.rightStick(x: 0, y: 0), time: 0)
        _ = s.add(.rightStick(x: 0.3, y: 0.4), time: 1)
        XCTAssertEqual(s.add(.rightStick(x: 0, y: 0), time: 2), "2.0 s, 3 samples, right stick peak 0.50")
    }

    /// A restart (the sensors stopped and started again) moves nothing for the gap and keeps the bias.
    func testRestartKeepsTheBiasAndMovesNothingAcrossTheStop() {
        var aim = GyroAim(config: .init(output: .mouse, turnAxis: .yaw))
        let bias = GyroVector(x: 0.01, y: 0.01, z: 0)
        for i in 0..<300 { _ = aim.add(GyroSample(time: Double(i) / Self.hz, rate: bias)) }
        XCTAssertTrue(aim.calibrated)
        let learnt = aim.bias
        aim.restart()
        XCTAssertEqual(aim.bias, learnt)
        XCTAssertTrue(aim.calibrated)
        // 50 ms after the last sample (within maxStep): without the restart this sample would move by its dt.
        XCTAssertEqual(aim.add(GyroSample(time: 3.04, rate: GyroVector(x: 0, y: 2, z: 0))), .mouse(dx: 0, dy: 0))
        if case .mouse(let dx, _) = aim.add(GyroSample(time: 3.05, rate: GyroVector(x: 0, y: 2, z: 0))) {
            XCTAssertLessThan(dx, 0)
        } else { XCTFail("mouse") }
    }
}
