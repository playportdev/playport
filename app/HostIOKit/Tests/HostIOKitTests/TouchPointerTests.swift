// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import HostIOKit

/// Phase 4's touch machines (PLA-13): the
/// Keyboard & mouse layout's look area and WASD stick, and Point & click's
/// pointer surface and its side-bar tools.
final class TouchPointerTests: XCTestCase {
    func p(_ x: Double, _ y: Double) -> TouchPoint { TouchPoint(x: x, y: y) }

    let fire = TouchTarget(id: "fire", kind: .button(.mouse(.left), .hold), frame: TouchRect(x: 700, y: 300, width: 60, height: 60))
    let look = TouchTarget(id: "look", kind: .look, frame: TouchRect(x: 0, y: 0, width: 800, height: 400))

    func testDraggingTheLookAreaMovesTheMouse() {
        var t = TouchControls(targets: [look, fire])
        t.lookScale = 3
        // A control on the look area is hit first; the rest of it is the look area's.
        XCTAssertEqual(t.target(at: p(710, 310)), 1)
        XCTAssertEqual(t.target(at: p(300, 200)), 0)
        XCTAssertTrue(t.began(1, at: p(300, 200), time: 0))
        XCTAssertEqual(t.takeOutput().events, [])
        t.moved(1, at: p(310, 195), time: 0.016)
        XCTAssertEqual(t.takeOutput().events, [.move(dx: 30, dy: -15)])
        XCTAssertEqual(t.takeOutput().events, [])   // taken once
        // Under a count is carried to the next move, not lost.
        t.moved(1, at: p(310.2, 195), time: 0.032)
        XCTAssertEqual(t.takeOutput().events, [])
        t.moved(1, at: p(310.4, 195), time: 0.048)
        XCTAssertEqual(t.takeOutput().events, [.move(dx: 1, dy: 0)])
        // It holds nothing: the output's state is empty, the look area drawn as held.
        XCTAssertEqual(t.output, TouchOutput())
        XCTAssertEqual(t.held, ["look"])
        // Fire with the other thumb while looking.
        XCTAssertTrue(t.began(2, at: p(710, 310), time: 0.05))
        t.moved(1, at: p(300.4, 205), time: 0.06)
        let out = t.takeOutput()
        XCTAssertEqual(out.mouse, [.left])
        XCTAssertEqual(out.events, [.move(dx: -29, dy: 30)])   // -30 + the 0.2 carried: -29, -0.8 carried
        // Two fingers on the look area both look.
        XCTAssertTrue(t.began(3, at: p(100, 100), time: 0.07))
        t.moved(3, at: p(100, 110), time: 0.08)
        t.moved(1, at: p(310.4, 205), time: 0.08)
        XCTAssertEqual(t.takeOutput().events, [.move(dx: 0, dy: 30), .move(dx: 29, dy: 0)])   // 30 - 0.8
        // Where the fingers looking are now, in the order they went down (the view rings each).
        XCTAssertEqual(t.points(on: "look"), [p(310.4, 205), p(100, 110)])
        XCTAssertEqual(t.points(on: "fire"), [p(710, 310)])
        t.ended(2, time: 0.09)
        XCTAssertEqual(t.points(on: "fire"), [])
        t.ended(1, time: 0.1)
        t.ended(3, time: 0.1)
        t.moved(1, at: p(0, 0), time: 0.2)   // a lifted finger moves nothing
        XCTAssertEqual(t.takeOutput().events, [])
        XCTAssertEqual(t.points(on: "look"), [])
    }
}

extension TouchPointerTests {
    static let wasd: [InputAction] = [.key(0x57, []), .key(0x53, []), .key(0x41, []), .key(0x44, [])]
    var stick: TouchTarget {
        TouchTarget(id: "move", kind: .keyStick(Self.wasd, zone: TouchRect(x: 0, y: 200, width: 210, height: 126)),
                    frame: TouchRect(x: 53, y: 211, width: 104, height: 104))
    }

    /// W A S D from a floating stick: a direction holds its key from half the radius until under 0.4 of it.
    func testTheWasdStickHoldsKeysWithHysteresis() {
        var t = TouchControls(targets: [look, stick])
        // Its zone is taken before the look area under it.
        XCTAssertEqual(t.target(at: p(100, 300)), 1)
        XCTAssertTrue(t.began(1, at: p(100, 300), time: 0))
        XCTAssertEqual(t.output.keys, [])
        t.moved(1, at: p(100, 275), time: 0.05)   // 25 of 52 up: under half
        XCTAssertEqual(t.output.keys, [])
        t.moved(1, at: p(100, 274), time: 0.06)   // 26: half
        XCTAssertEqual(t.output.keys, [.key(0x57, [])])
        t.moved(1, at: p(100, 280), time: 0.07)   // 20 (0.38): under the release point
        XCTAssertEqual(t.output.keys, [])
        t.moved(1, at: p(100, 274), time: 0.08)
        t.moved(1, at: p(100, 279), time: 0.09)   // 21 (0.40): still held
        XCTAssertEqual(t.output.keys, [.key(0x57, [])])
        XCTAssertEqual(t.stick("move")?.origin, p(100, 300))
        // Down and right at once, past the edge: S and D.
        t.moved(1, at: p(200, 400), time: 0.1)
        XCTAssertEqual(t.output.keys, [.key(0x53, []), .key(0x44, [])])
        t.moved(1, at: p(40, 300), time: 0.11)
        XCTAssertEqual(t.output.keys, [.key(0x41, [])])
        XCTAssertEqual(t.output.pad, PadInput())   // no pad stick
        XCTAssertEqual(t.held, ["move"])
        t.ended(1, time: 0.2)
        XCTAssertEqual(t.output.keys, [])
        // A double tap is no thumb button: a key stick has none.
        t.began(2, at: p(100, 300), time: 0.25)
        XCTAssertEqual(t.output, TouchOutput())
    }
}

/// Point & click: the pointer surface over the safe area of an 874 × 402 view, and the side bar's tools.
extension TouchPointerTests {
    var pointerTargets: [TouchTarget] {
        let view = TouchRect(x: 0, y: 0, width: 874, height: 402)
        return [
            TouchTarget(id: "pointer", kind: .pointer(view: view), frame: TouchRect(x: 62, y: 0, width: 750, height: 381)),
            TouchTarget(id: "right", kind: .tool(.rightClick), frame: TouchRect(x: 70, y: 70, width: 44, height: 44)),
            TouchTarget(id: "hover", kind: .tool(.hover), frame: TouchRect(x: 70, y: 122, width: 44, height: 44)),
            TouchTarget(id: "scroll", kind: .tool(.scroll), frame: TouchRect(x: 70, y: 174, width: 44, height: 44)),
            TouchTarget(id: "mode", kind: .tool(.trackpad), frame: TouchRect(x: 600, y: 8, width: 200, height: 36)),
        ]
    }

    func tap(_ t: inout TouchControls, _ touch: Int, _ x: Double, _ y: Double, at time: Double) {
        XCTAssertTrue(t.began(touch, at: p(x, y), time: time))
        t.ended(touch, time: time + 0.05)
    }

    /// Tap to click: the left button goes down where the finger lands, follows it and comes up as it lifts;
    /// the magnifier shows the point under the finger while it is down.
    func testATapClicksWhereTheFingerIs() {
        var t = TouchControls(targets: pointerTargets)
        XCTAssertEqual(t.target(at: p(92, 92)), 1)   // a tool on the surface is hit first
        XCTAssertEqual(t.target(at: p(437, 201)), 0)
        XCTAssertNil(t.target(at: p(30, 201)))        // under the island: no control's
        XCTAssertFalse(t.trackpad)
        XCTAssertTrue(t.began(1, at: p(437, 201), time: 0))
        XCTAssertEqual(t.magnifier, p(437, 201))
        var out = t.takeOutput()
        XCTAssertEqual(out.events, [.place(x: 32768, y: 32768)])   // the middle of the client area
        XCTAssertEqual(out.mouse, [.left])
        t.moved(1, at: p(218.5, 100.5), time: 0.1)                  // dragged to a quarter
        out = t.takeOutput()
        XCTAssertEqual(out.events, [.place(x: 16384, y: 16384)])
        XCTAssertEqual(out.mouse, [.left])
        XCTAssertEqual(t.magnifier, p(218.5, 100.5))
        t.ended(1, time: 0.2)
        out = t.takeOutput()
        XCTAssertEqual(out.events, [])
        XCTAssertEqual(out.mouse, [])
        XCTAssertNil(t.magnifier)
        // Only the first finger on the surface points; a second one does nothing.
        XCTAssertTrue(t.began(2, at: p(437, 201), time: 1))
        XCTAssertTrue(t.began(3, at: p(600, 300), time: 1))
        t.moved(3, at: p(610, 300), time: 1.1)
        XCTAssertEqual(t.takeOutput().events, [.place(x: 32768, y: 32768)])
        XCTAssertEqual(t.magnifier, p(437, 201))
        t.ended(2, time: 1.2)
        XCTAssertEqual(t.output.mouse, [])
        XCTAssertNil(t.magnifier)
    }

    /// Hover moves the pointer without a button until it is tapped off; right click is for one click;
    /// the three take turns.
    func testHoverAndRightClickTools() {
        var t = TouchControls(targets: pointerTargets)
        tap(&t, 1, 92, 144, at: 0)
        XCTAssertEqual(t.tool, .hover)
        XCTAssertEqual(t.held, ["hover"])
        XCTAssertTrue(t.began(2, at: p(437, 201), time: 1))
        t.moved(2, at: p(218.5, 100.5), time: 1.1)
        var out = t.takeOutput()
        XCTAssertEqual(out.events, [.place(x: 32768, y: 32768), .place(x: 16384, y: 16384)])
        XCTAssertEqual(out.mouse, [])
        XCTAssertEqual(t.magnifier, p(218.5, 100.5))
        t.ended(2, time: 1.2)
        XCTAssertEqual(t.tool, .hover)   // it stays on
        // Right click takes over from hover, for one press.
        tap(&t, 3, 92, 92, at: 2)
        XCTAssertEqual(t.tool, .rightClick)
        XCTAssertEqual(t.held, ["right"])
        XCTAssertTrue(t.began(4, at: p(437, 201), time: 3))
        out = t.takeOutput()
        XCTAssertEqual(out.events, [.place(x: 32768, y: 32768)])
        XCTAssertEqual(out.mouse, [.right])
        t.ended(4, time: 3.1)
        XCTAssertEqual(t.output.mouse, [])
        XCTAssertNil(t.tool)
        XCTAssertTrue(t.began(5, at: p(437, 201), time: 4))
        XCTAssertEqual(t.output.mouse, [.left])
        t.ended(5, time: 4.1)
        // A tool tapped again is off.
        tap(&t, 6, 92, 144, at: 5)
        tap(&t, 7, 92, 144, at: 6)
        XCTAssertNil(t.tool)
        XCTAssertEqual(t.held, [])
    }

    /// Scroll: a drag turns the wheel a notch each `scrollStep` points, the content following the finger
    /// (down: the wheel toward the top, +); the pointer goes where it landed first, and nothing clicks.
    func testScrollTurnsTheWheel() {
        var t = TouchControls(targets: pointerTargets)
        t.scrollStep = 20
        tap(&t, 1, 92, 196, at: 0)
        XCTAssertEqual(t.tool, .scroll)
        XCTAssertTrue(t.began(2, at: p(437, 201), time: 1))
        XCTAssertEqual(t.takeOutput().events, [.place(x: 32768, y: 32768)])
        XCTAssertNil(t.magnifier)
        t.moved(2, at: p(437, 246), time: 1.1)   // 45 down: two notches, 5 carried
        XCTAssertEqual(t.takeOutput().events, [.wheel(2)])
        t.moved(2, at: p(440, 216), time: 1.2)   // 30 up: -25, one notch back
        var out = t.takeOutput()
        XCTAssertEqual(out.events, [.wheel(-1)])
        XCTAssertEqual(out.mouse, [])
        t.ended(2, time: 1.3)
        out = t.takeOutput()
        XCTAssertEqual(out, TouchOutput())
        XCTAssertEqual(t.tool, .scroll)
    }

    /// Trackpad: a drag moves the pointer by `trackpadScale` counts a point, a short still tap clicks
    /// where it is (right with the right-click tool), and there is no magnifier.
    func testTrackpadMovesAndTapsClick() {
        var t = TouchControls(targets: pointerTargets)
        t.trackpadScale = 2
        tap(&t, 1, 700, 20, at: 0)
        XCTAssertTrue(t.trackpad)
        XCTAssertEqual(t.held, ["mode"])
        XCTAssertTrue(t.began(2, at: p(400, 200), time: 1))
        t.moved(2, at: p(420, 190), time: 1.1)
        var out = t.takeOutput()
        XCTAssertEqual(out.events, [.move(dx: 40, dy: -20)])
        XCTAssertEqual(out.mouse, [])
        XCTAssertNil(t.magnifier)
        t.ended(2, time: 1.2)
        XCTAssertEqual(t.takeOutput().events, [])   // a drag is no tap
        // A short tap that barely moves clicks once, as one event.
        XCTAssertTrue(t.began(3, at: p(400, 200), time: 2))
        t.moved(3, at: p(403, 200), time: 2.05)
        t.ended(3, time: 2.1)
        XCTAssertEqual(t.takeOutput().events, [.move(dx: 6, dy: 0), .click(.left)])
        // Too long a press is no tap.
        XCTAssertTrue(t.began(4, at: p(400, 200), time: 3))
        t.ended(4, time: 3.5)
        XCTAssertEqual(t.takeOutput().events, [])
        // Right click: the next tap is the right button, then it is off.
        tap(&t, 5, 92, 92, at: 4)
        tap(&t, 6, 400, 200, at: 5)
        XCTAssertEqual(t.takeOutput().events, [.click(.right)])
        XCTAssertNil(t.tool)
        // Hover: taps do not click.
        tap(&t, 7, 92, 144, at: 6)
        tap(&t, 8, 400, 200, at: 7)
        XCTAssertEqual(t.takeOutput().events, [])
        // Scroll on the trackpad turns the wheel and moves nothing.
        tap(&t, 9, 92, 196, at: 8)
        XCTAssertTrue(t.began(10, at: p(400, 200), time: 9))
        t.moved(10, at: p(410, 160), time: 9.1)
        XCTAssertEqual(t.takeOutput().events, [.wheel(-2)])
        t.ended(10, time: 9.2)
        // The mode tool back: tap to click.
        tap(&t, 11, 700, 20, at: 10)
        XCTAssertFalse(t.trackpad)
    }

    /// A cancelled finger (the three-finger tap) clicks nothing and flips no tool; release-all lets go
    /// of the button and turns the tools off, keeping the trackpad mode, a preference.
    func testCancelAndReleaseAllCoverThePointer() {
        var t = TouchControls(targets: pointerTargets)
        XCTAssertTrue(t.began(1, at: p(92, 92), time: 0))
        t.cancelled(1, time: 0.05)
        XCTAssertNil(t.tool)
        XCTAssertTrue(t.began(2, at: p(700, 20), time: 0.1))
        t.cancelled(2, time: 0.15)
        XCTAssertFalse(t.trackpad)
        // Right armed; a press with it taken back leaves it armed and the button up.
        tap(&t, 3, 92, 92, at: 1)
        XCTAssertTrue(t.began(4, at: p(437, 201), time: 2))
        XCTAssertEqual(t.output.mouse, [.right])
        t.cancelled(4, time: 2.05)
        let out = t.takeOutput()
        XCTAssertEqual(out.events, [.place(x: 32768, y: 32768)])
        XCTAssertEqual(out.mouse, [])
        XCTAssertEqual(t.tool, .rightClick)
        // On the trackpad a cancelled tap clicks nothing.
        tap(&t, 5, 700, 20, at: 3)
        XCTAssertTrue(t.began(6, at: p(437, 201), time: 4))
        t.cancelled(6, time: 4.05)
        XCTAssertEqual(t.takeOutput().events, [])
        XCTAssertEqual(t.tool, .rightClick)
        // Release-all with a finger down and a tool on.
        tap(&t, 7, 700, 20, at: 5)   // back to tap to click
        tap(&t, 8, 92, 144, at: 6)   // hover
        tap(&t, 9, 92, 144, at: 7)   // off
        XCTAssertTrue(t.began(10, at: p(437, 201), time: 8))
        t.moved(10, at: p(440, 201), time: 8.1)
        t.releaseAll()
        XCTAssertEqual(t.takeOutput(), TouchOutput())
        XCTAssertNil(t.magnifier)
        tap(&t, 11, 700, 20, at: 9)
        tap(&t, 12, 92, 196, at: 10)
        t.releaseAll()
        XCTAssertNil(t.tool)
        XCTAssertTrue(t.trackpad)
        XCTAssertEqual(t.held, ["mode"])
    }
}

/// The surfaces' events through InputMixer, and release-all of the new holds.
extension TouchPointerTests {
    func testTheMixerSendsTheEventsInOrderBeforeTheHolds() {
        var mixer = InputMixer()
        var t = TouchControls(targets: pointerTargets)
        _ = mixer.touch(t.takeOutput())
        // Tap to click: the pointer goes there, then the button goes down; it comes up after the last place.
        t.began(1, at: p(437, 201), time: 0)
        XCTAssertEqual(mixer.touch(t.takeOutput()).outputs, [.place(x: 32768, y: 32768), .pointer(flags: Pointer.leftDown, data: 0)])
        t.moved(1, at: p(218.5, 100.5), time: 0.1)
        t.ended(1, time: 0.2)
        XCTAssertEqual(mixer.touch(t.takeOutput()).outputs, [.place(x: 16384, y: 16384), .pointer(flags: Pointer.leftUp, data: 0)])
        // A trackpad tap is a click, down and up at once; motion is a move.
        var e = TouchOutput()
        e.events = [.move(dx: 4, dy: -2), .click(.left), .click(.right), .wheel(2), .wheel(-1)]
        XCTAssertEqual(mixer.touch(e).outputs, [
            .move(dx: 4, dy: -2),
            .pointer(flags: Pointer.leftDown, data: 0), .pointer(flags: Pointer.leftUp, data: 0),
            .pointer(flags: Pointer.rightDown, data: 0), .pointer(flags: Pointer.rightUp, data: 0),
            .pointer(flags: Pointer.wheel, data: 240), .pointer(flags: Pointer.wheel, data: UInt32(bitPattern: -120)),
        ])
        XCTAssertEqual(mixer.touch(TouchOutput()).outputs, [])
        // A click on a button already held by the controls leaves it held.
        var held = TouchOutput()
        held.mouse = [.left]
        XCTAssertEqual(mixer.touch(held).outputs, [.pointer(flags: Pointer.leftDown, data: 0)])
        held.events = [.click(.left)]
        XCTAssertEqual(mixer.touch(held).outputs, [])
    }

    /// The in-game menu opens with a finger on the pointer, one on the WASD stick and one looking:
    /// the button and the key come up, and nothing moves after.
    func testReleaseAllLetsGoOfTheNewHolds() {
        var t = TouchControls(targets: [look, stick])
        var mixer = InputMixer()
        _ = mixer.touch(t.takeOutput())
        t.began(1, at: p(100, 300), time: 0)
        t.moved(1, at: p(100, 240), time: 0.1)
        t.began(2, at: p(400, 100), time: 0)
        t.moved(2, at: p(410, 100), time: 0.1)
        XCTAssertEqual(mixer.touch(t.takeOutput()).outputs, [.move(dx: 30, dy: 0), .key(0x57, down: true)])
        t.moved(2, at: p(420, 100), time: 0.2)
        t.releaseAll()
        XCTAssertEqual(mixer.touch(t.takeOutput()).outputs, [.key(0x57, down: false)])
        t.moved(2, at: p(430, 100), time: 0.3)
        t.moved(1, at: p(100, 200), time: 0.3)
        XCTAssertEqual(mixer.touch(t.takeOutput()).outputs, [])

        var u = TouchControls(targets: pointerTargets)
        u.began(1, at: p(437, 201), time: 0)
        _ = mixer.touch(u.takeOutput())
        u.releaseAll()
        XCTAssertEqual(mixer.touch(u.takeOutput()).outputs, [.pointer(flags: Pointer.leftUp, data: 0)])
    }
}

/// The game's picture inside the view: the pointer surface maps a point to the client area as
/// GameSurfaceView.route maps a game touch, through the aspect-fitted picture, not the whole view.
extension TouchPointerTests {
    func testThePointerPlacesInTheGamePicture() {
        var t = TouchControls(targets: pointerTargets)
        // A 3:2 picture pillarboxed in the middle of the 874 × 402 view.
        t.setPicture(TouchRect(x: 137, y: 1, width: 600, height: 400))
        XCTAssertTrue(t.began(1, at: p(437, 201), time: 0))
        XCTAssertEqual(t.takeOutput().events, [.place(x: 32768, y: 32768)])
        t.moved(1, at: p(287, 101), time: 0.1)   // a quarter of the picture each way
        XCTAssertEqual(t.takeOutput().events, [.place(x: 16384, y: 16384)])
        t.moved(1, at: p(100, 201), time: 0.2)   // in the black bar: the picture's left edge
        XCTAssertEqual(t.takeOutput().events, [.place(x: 0, y: 32768)])
        // The swap chain changes size under a held finger: nothing is let go, it maps to the new picture.
        t.setPicture(TouchRect(x: 0, y: 0, width: 874, height: 402))
        t.moved(1, at: p(437, 201), time: 0.3)
        let out = t.takeOutput()
        XCTAssertEqual(out.events, [.place(x: 32768, y: 32768)])
        XCTAssertEqual(out.mouse, [.left])
        // Only the pointer surface changes.
        t.setPicture(TouchRect(x: 137, y: 1, width: 600, height: 400))
        t.ended(1, time: 0.4)
        XCTAssertEqual(t.targets[0].kind, .pointer(view: TouchRect(x: 137, y: 1, width: 600, height: 400)))
        XCTAssertEqual(t.targets[1].kind, .tool(.rightClick))
    }
}
