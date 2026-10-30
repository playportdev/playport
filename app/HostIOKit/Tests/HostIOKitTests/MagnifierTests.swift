// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import HostIOKit

/// Point & click's magnifier (TouchPointer.dc.html): where the loupe is drawn
/// for a finger, and which of the picture's pixels it shows.
final class MagnifierTests: XCTestCase {
    func p(_ x: Double, _ y: Double) -> TouchPoint { TouchPoint(x: x, y: y) }

    let bounds = TouchRect(x: 0, y: 0, width: 874, height: 402)
    /// A 3:2 picture pillarboxed in the view, from a 1800 × 1200 swap chain: 3 pixels a point.
    let picture = TouchRect(x: 137, y: 1, width: 600, height: 400)

    func magnifier(_ x: Double, _ y: Double) -> Magnifier? {
        Magnifier(at: p(x, y), picture: picture, texture: (1800, 1200), bounds: bounds)
    }

    /// The loupe sits above the finger and shows the 46 points around it twice as large.
    func testTheLoupeIsAboveTheFingerAndShowsWhatIsUnderIt() throws {
        let m = try XCTUnwrap(magnifier(437, 201))
        XCTAssertEqual(m.loupe, TouchRect(x: 391, y: 83, width: 92, height: 92))
        XCTAssertEqual(m.source, Magnifier.Pixels(x: 831, y: 531, width: 138, height: 138))
        XCTAssertEqual(m.mark, p(0.5, 0.5))
    }

    /// With no room above, it goes beside the finger (to the right, or the left at the right edge), kept in the view.
    func testNearTheTopTheLoupeGoesBesideTheFinger() throws {
        let top = try XCTUnwrap(magnifier(437, 30))
        XCTAssertEqual(top.loupe, TouchRect(x: 463, y: 0, width: 92, height: 92))
        XCTAssertEqual(top.source, Magnifier.Pixels(x: 831, y: 18, width: 138, height: 138))
        XCTAssertEqual(top.mark, p(0.5, 0.5))
        let corner = try XCTUnwrap(magnifier(860, 20))
        XCTAssertEqual(corner.loupe, TouchRect(x: 742, y: 0, width: 92, height: 92))
    }

    /// At the picture's edge the pixels shown stay inside it and the mark moves off the middle to
    /// the point; a finger in the black bar points at the picture's edge, as the pointer does.
    func testAtThePicturesEdgeTheMarkFollowsThePoint() throws {
        let corner = try XCTUnwrap(magnifier(140, 4))
        XCTAssertEqual(corner.source, Magnifier.Pixels(x: 0, y: 0, width: 138, height: 138))
        XCTAssertEqual(corner.mark.x, 9.0 / 138, accuracy: 1e-9)
        XCTAssertEqual(corner.mark.y, 9.0 / 138, accuracy: 1e-9)
        let bar = try XCTUnwrap(magnifier(860, 20))
        XCTAssertEqual(bar.source, Magnifier.Pixels(x: 1662, y: 0, width: 138, height: 138))
        XCTAssertEqual(bar.mark.x, 1, accuracy: 1e-9)
        XCTAssertEqual(bar.mark.y, 57.0 / 138, accuracy: 1e-9)
    }

    /// No picture yet (or an empty one): no loupe.
    func testNoPictureNoLoupe() {
        XCTAssertNil(Magnifier(at: p(10, 10), picture: picture, texture: (0, 0), bounds: bounds))
        XCTAssertNil(Magnifier(at: p(10, 10), picture: TouchRect(x: 0, y: 0, width: 0, height: 0), texture: (1800, 1200), bounds: bounds))
    }
}
