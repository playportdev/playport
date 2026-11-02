// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import PlayportKit

/// The dev footprint-jump sampler's rule (PLA-476): armed at the limit less 2,000 MB, then a
/// firing at +300 MB over the last one 5 s or more after it, or at +300 MB in one tick even inside
/// the spacing; while the last firing's walk runs, only a jump, without a walk.
final class FootprintJumpTriggerTests: XCTestCase {
    /// Run l9's footprint from +168 s to its load step (`[footprint]` ml358 and `fast` lines on the
    /// `[xp]` clock, `.work/ui-runs/20261030T135937-rdr2-p476l9`), limit 8,192 MB. A firing's walk
    /// is taken to run 0.75 s (the forced walk's measured cost).
    static let l9: [(Double, Int)] = [
        (168.25, 5762), (170.10, 5764), (172.14, 5761), (174.28, 5816), (176.09, 5849), (178.31, 6019),
        (180.18, 6044), (182.31, 6037), (184.09, 6007), (186.17, 6020), (188.21, 5990), (190.47, 6088),
        (192.24, 6160), (194.37, 6240), (196.55, 6386), (198.48, 6478), (198.84, 6497), (199.82, 6565),
        (200.48, 6585), (200.80, 6597), (201.12, 6638), (201.39, 6703), (202.01, 6757), (202.65, 6772),
        (202.95, 6814), (203.54, 6831), (204.21, 6853), (204.54, 6873), (204.87, 6916), (205.19, 6935),
        (205.51, 6977), (205.78, 7001), (206.10, 7045), (206.77, 7054), (207.43, 7062), (208.72, 7072),
        (208.72, 7174), (209.08, 7744), (209.08, 8106),
    ]

    func testL9FiresAtArmingTwiceOnLevelAndInsideTheStep() {
        var t = FootprintJumpTrigger()
        var busyUntil = -1.0
        var fired: [(Double, Int, FootprintJumpTrigger.Firing)] = []
        for (at, mb) in Self.l9 {
            if let f = t.tick(at: at, footprintMB: mb, limitMB: 8_192, busy: at < busyUntil) {
                fired.append((at, mb, f))
                if f.walks { busyUntil = at + 0.75 }
            }
        }
        XCTAssertEqual(fired.map(\.0), [194.37, 199.82, 204.87, 209.08, 209.08])
        XCTAssertEqual(fired.map(\.1), [6_240, 6_565, 6_916, 7_744, 8_106])
        XCTAssertEqual(fired.map(\.2.reason), [.armed, .level, .level, .jump, .jump])
        // the step's second jump comes while the first one's walk runs: its cheap line only
        XCTAssertEqual(fired.map(\.2.walks), [true, true, true, true, false])
    }

    func testNothingBelowTheArmingLevelOrWithoutALimit() {
        var t = FootprintJumpTrigger()
        XCTAssertNil(t.tick(at: 0, footprintMB: 6_191, limitMB: 8_192, busy: false))
        XCTAssertNil(t.tick(at: 1, footprintMB: 7_000, limitMB: nil, busy: false))
        XCTAssertEqual(t.tick(at: 2, footprintMB: 6_192, limitMB: 8_192, busy: false), .init(.armed, walks: true))
    }

    func testLevelWaitsForTheSpacingAndAJumpDoesNot() {
        var t = FootprintJumpTrigger()
        XCTAssertEqual(t.tick(at: 0, footprintMB: 6_500, limitMB: 8_192, busy: false), .init(.armed, walks: true))
        XCTAssertNil(t.tick(at: 1, footprintMB: 6_700, limitMB: 8_192, busy: false))
        XCTAssertNil(t.tick(at: 4.9, footprintMB: 6_850, limitMB: 8_192, busy: false))   // +350, 4.9 s
        XCTAssertEqual(t.tick(at: 5, footprintMB: 6_850, limitMB: 8_192, busy: false), .init(.level, walks: true))
        XCTAssertEqual(t.tick(at: 5.25, footprintMB: 7_150, limitMB: 8_192, busy: false), .init(.jump, walks: true))
        XCTAssertEqual(t.lastFiredMB, 7_150)
    }

    /// While the last firing's walk runs, a jump fires without a walk (the cheap line only) and the
    /// next firing counts from it; a level firing waits.
    func testOnlyAWalklessJumpWhileBusy() {
        var t = FootprintJumpTrigger()
        XCTAssertEqual(t.tick(at: 0.25, footprintMB: 6_500, limitMB: 8_192, busy: false), .init(.armed, walks: true))
        XCTAssertEqual(t.tick(at: 0.5, footprintMB: 6_900, limitMB: 8_192, busy: true), .init(.jump, walks: false))
        XCTAssertEqual(t.lastFiredMB, 6_900)
        XCTAssertEqual(t.lastFiredAt, 0.5)
        XCTAssertNil(t.tick(at: 0.75, footprintMB: 7_000, limitMB: 8_192, busy: false))
        XCTAssertNil(t.tick(at: 6, footprintMB: 7_250, limitMB: 8_192, busy: true))     // a level waits
        XCTAssertEqual(t.tick(at: 6.25, footprintMB: 7_250, limitMB: 8_192, busy: false), .init(.level, walks: true))
    }
}
