// SPDX-License-Identifier: GPL-3.0-or-later
import PlayportKit
import SteamClientKit
import XCTest

final class SVGPathTests: XCTestCase {
    private func end(_ s: SVGPath.Segment) -> SVGPath.Point? {
        switch s {
        case .move(let p), .line(let p), .cubic(_, _, let p): p
        case .close: nil
        }
    }

    func testRelativeCommandsAndImplicitRepeatsBecomeAbsolute() {
        let segments = SVGPath.parse("m1 2 3 4h2v-1H0V0l1-1.5.5.5z")
        XCTAssertEqual(segments, [
            .move(.init(1, 2)), .line(.init(4, 6)),  // a pair after m is a relative line
            .line(.init(6, 6)), .line(.init(6, 5)), .line(.init(0, 5)), .line(.init(0, 0)),
            .line(.init(1, -1.5)), .line(.init(1.5, -1)), .close,
        ])
    }

    func testAnArcWithPackedFlagsSweepsTheWayItsFlagSays() throws {
        // A half circle from (0,0) to (2,0): sweep 1 turns through (1,-1) with y down, sweep 0 through (1,1).
        let up = try XCTUnwrap(SVGPath.parse("M0 0a1 1 0 012 0"))
        let down = try XCTUnwrap(SVGPath.parse("M0 0a1 1 0 0 0 2 0"))
        XCTAssertEqual(up.count, 3, "a move and two quarter turns")
        let mid = try XCTUnwrap(end(up[1])), last = try XCTUnwrap(end(up[2]))
        XCTAssertEqual(mid.x, 1, accuracy: 1e-9); XCTAssertEqual(mid.y, -1, accuracy: 1e-9)
        XCTAssertEqual(last, .init(2, 0), "the last piece ends exactly on the arc's end point")
        let other = try XCTUnwrap(end(down[1]))
        XCTAssertEqual(other.y, 1, accuracy: 1e-9)
    }

    func testMalformedDataIsRejected() {
        XCTAssertNil(SVGPath.parse("1 2 L3 4"), "numbers before any command")
        XCTAssertNil(SVGPath.parse("M1"), "a point needs two numbers")
        XCTAssertNil(SVGPath.parse("M0 0 a1 1 0 2 0 3 3"), "an arc flag is 0 or 1")
    }

    func testEveryStoreMarkParsesInsideItsBox() throws {
        for store in Store.allCases {
            guard let d = StoreMark.path(store) else {
                XCTAssertEqual(store, .local, "only a local game has no mark")
                continue
            }
            let segments = try XCTUnwrap(SVGPath.parse(d), "\(store)")
            XCTAssertGreaterThan(segments.count, 10, "\(store)")
            for p in segments.compactMap(end) {
                XCTAssert((-0.5...24.5).contains(p.x) && (-0.5...24.5).contains(p.y), "\(store): \(p) outside 24×24")
            }
        }
    }
}
