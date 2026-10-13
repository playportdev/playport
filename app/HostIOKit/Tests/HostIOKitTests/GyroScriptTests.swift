// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import HostIOKit

/// GyroScript, the dev driver's `gyro:` steps, through GyroAim as a sensor's samples are.
final class GyroScriptTests: XCTestCase {
    func play(_ text: String, _ config: GyroAim.Config) throws -> [GyroAimOutput] {
        var a = GyroAim(config: config)
        return try GyroScript.parse(text).samples(from: 100).map { a.add($0) }
    }

    func mouse(_ out: [GyroAimOutput]) -> (dx: Int, dy: Int) {
        out.reduce((0, 0)) { s, o in
            guard case .mouse(let dx, let dy) = o else { return s }
            return (s.0 + Int(dx), s.1 + Int(dy))
        }
    }

    func testParse() throws {
        let s = try GyroScript.parse("yaw=90@500/pitch=-30+yaw=10.5@300/rest@200/roll=45@100")
        XCTAssertEqual(s.steps.map(\.ms), [500, 300, 200, 100])
        XCTAssertEqual(s.totalMs, 1100)
        let r = Double.pi / 180
        XCTAssertEqual(s.steps[0].rate, GyroVector(x: 0, y: -90 * r, z: 0))
        XCTAssertEqual(s.steps[1].rate, GyroVector(x: -30 * r, y: -10.5 * r, z: 0))
        XCTAssertEqual(s.steps[2].rate, .zero)
        XCTAssertEqual(s.steps[3].rate, GyroVector(x: 0, y: 0, z: -45 * r))
        for bad in ["", "yaw=90", "yaw=90@", "yaw=90@0", "yaw=90@10001", "yaw@100", "yaw=x@100", "spin=10@100",
                    "yaw=10+yaw=20@100", "yaw=2001@100", "yaw=90@500/", "yaw=90@500//rest@1", "rest=1@100", "yaw=nan@100",
                    "rest@10000/rest@10000/rest@10000/rest@10000/rest@10000/rest@10000/rest@1"] {
            XCTAssertThrowsError(try GyroScript.parse(bad), bad)
        }
        XCTAssertEqual(try GyroScript.parse("rest@10000/rest@10000/rest@10000/rest@10000/rest@10000/rest@10000").totalMs, 60_000)
    }

    /// Samples at 100 Hz, upright: one at rest, the steps, then 150 ms at rest.
    func testSamples() throws {
        let samples = try GyroScript.parse("yaw=90@50").samples(from: 10)
        XCTAssertEqual(samples.count, 1 + 5 + 15)
        XCTAssertEqual(samples.first?.time, 10)
        XCTAssertEqual(samples.first?.rate, .zero)
        XCTAssertEqual(samples[1].rate.y, -90 * Double.pi / 180)
        XCTAssertEqual(samples[5].rate.y, -90 * Double.pi / 180)
        XCTAssertEqual(samples[6].rate, .zero)
        XCTAssertEqual(samples.last!.time, 10.2, accuracy: 1e-9)
        XCTAssertTrue(samples.allSatisfy { $0.gravity == GyroScript.upright })
    }

    /// A step's angle comes out as rate × duration × 20 counts per degree (to the count: the
    /// remainder carried may leave one), in the script's directions.
    func testTheMouseMovesByTheScriptsAngle() throws {
        func near(_ a: Int, _ b: Int, _ m: String = "", line: UInt = #line) {
            XCTAssertEqual(Double(a), Double(b), accuracy: 1, m, line: line)
        }
        let m = mouse(try play("yaw=90@500", .init(output: .mouse)))
        near(m.dx, 900)   // 45° right
        XCTAssertEqual(m.dy, 0)
        let down = mouse(try play("pitch=-30@300/rest@100/yaw=-10@1000", .init(output: .mouse, turnAxis: .yaw)))
        near(down.dy, 180)   // 9° down
        near(down.dx, -200)  // 10° left
        near(mouse(try play("roll=45@200", .init(output: .mouse, turnAxis: .roll))).dx, 180)
        // Roll does not turn in player space with the device upright.
        XCTAssertEqual(mouse(try play("roll=45@200", .init(output: .mouse))).dx, 0)
        near(mouse(try play("yaw=90@500", .init(output: .mouse, sensitivity: 2))).dx, 1800)
    }

    func testTheRightStickDeflectsAndComesBack() throws {
        let out = try play("yaw=90@500", .init(output: .rightStick))
        guard case .rightStick(let x, let y) = out[25] else { return XCTFail("\(out[25])") }
        XCTAssertEqual(x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(y, 0)
        XCTAssertEqual(out.last, .rightStick(x: 0, y: 0))
    }
}
