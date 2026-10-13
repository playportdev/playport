// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import HostIOKit

/// The cases Madeira's check-touch-gamepad.py lists, and phase 1's state machines
/// (docs/plans/2026-10-09-touch-controls.md).
final class TouchControlsTests: XCTestCase {
    let a = TouchTarget(id: "a", kind: .button(.pad(.a), .hold), frame: TouchRect(x: 700, y: 300, width: 50, height: 50))
    let b = TouchTarget(id: "b", kind: .button(.pad(.b), .hold), frame: TouchRect(x: 760, y: 250, width: 50, height: 50))
    let lt = TouchTarget(id: "lt", kind: .button(.pad(.lt), .hold), frame: TouchRect(x: 44, y: 82, width: 66, height: 34))
    let left = TouchTarget(id: "leftStick", kind: .stick(.leftStick, zone: TouchRect(x: 0, y: 134, width: 291, height: 268)),
                           frame: TouchRect(x: 52, y: 256, width: 116, height: 116))
    let right = TouchTarget(id: "rightStick", kind: .stick(.rightStick, zone: nil), frame: TouchRect(x: 552, y: 284, width: 92, height: 92))
    let dpad = TouchTarget(id: "dpad", kind: .dpad([.pad(.up), .pad(.down), .pad(.left), .pad(.right)]),
                           frame: TouchRect(x: 132, y: 168, width: 92, height: 92))

    func p(_ x: Double, _ y: Double) -> TouchPoint { TouchPoint(x: x, y: y) }

    func testTwoFingersOnOneButtonHoldItUntilTheLastLifts() {
        var t = TouchControls(targets: [a])
        XCTAssertTrue(t.began(1, at: p(710, 310), time: 0))
        XCTAssertTrue(t.began(2, at: p(740, 340), time: 0.1))
        t.ended(1, time: 0.2)
        XCTAssertTrue(t.output.pad.a)
        XCTAssertEqual(t.held, ["a"])
        t.ended(2, time: 0.3)
        XCTAssertFalse(t.output.pad.a)
        XCTAssertEqual(t.held, [])
    }

    func testATouchOffEveryControlIsTheGames() {
        var t = TouchControls(targets: [a, right])
        XCTAssertFalse(t.began(1, at: p(400, 100), time: 0))
        XCTAssertEqual(t.output, TouchOutput())
        XCTAssertNil(t.target(at: p(400, 100)))
    }

    func testControlsInsideTheFloatingZoneAreHitFirst() {
        let inZone = TouchTarget(id: "lb", kind: .button(.pad(.lb), .hold), frame: TouchRect(x: 44, y: 140, width: 66, height: 34))
        var t = TouchControls(targets: [left, inZone])
        XCTAssertEqual(t.target(at: p(60, 150)), 1)
        XCTAssertEqual(t.target(at: p(250, 380)), 0)   // anywhere else in the lower left third
        XCTAssertNil(t.target(at: p(300, 380)))
        XCTAssertTrue(t.began(1, at: p(60, 150), time: 0))
        XCTAssertTrue(t.output.pad.leftShoulder)
    }

    func testAFloatingStickStartsWhereTheThumbLands() {
        var t = TouchControls(targets: [left])
        XCTAssertTrue(t.began(1, at: p(200, 300), time: 0))
        XCTAssertEqual(t.output.pad.lx, 0)
        t.moved(1, at: p(229, 300), time: 0.05)   // half the radius (58) to the right
        XCTAssertEqual(t.output.pad.lx, 0.5, accuracy: 0.001)
        XCTAssertEqual(t.output.pad.ly, 0)
        t.moved(1, at: p(200, 200), time: 0.1)     // far up: clamped to the unit circle, +y up
        XCTAssertEqual(t.output.pad.lx, 0, accuracy: 0.001)
        XCTAssertEqual(t.output.pad.ly, 1, accuracy: 0.001)
        XCTAssertEqual(t.stick("leftStick")?.origin, p(200, 300))
        t.ended(1, time: 0.5)
        XCTAssertEqual(t.output.pad.ly, 0)
        XCTAssertNil(t.stick("leftStick"))
    }

    func testStickAnalogueRangesThroughPadMapping() {
        var t = TouchControls(targets: [right])
        t.began(1, at: p(598, 330), time: 0)
        t.moved(1, at: p(498, 330), time: 0.1)
        var v = PadMapping.values(t.output.pad)
        XCTAssertEqual(v.rx, -32768)
        XCTAssertEqual(v.ry, 0)
        t.moved(1, at: p(698, 230), time: 0.2)   // the diagonal, clamped
        v = PadMapping.values(t.output.pad)
        XCTAssertEqual(v.rx, 23170)
        XCTAssertEqual(v.ry, 23170)
    }

    func testDoubleTapOnAStickHoldsItsThumbButton() {
        var t = TouchControls(targets: [left, right])
        t.began(1, at: p(100, 300), time: 0)
        t.ended(1, time: 0.1)
        XCTAssertFalse(t.output.pad.leftThumb)
        t.began(2, at: p(102, 301), time: 0.3)
        XCTAssertTrue(t.output.pad.leftThumb)
        XCTAssertFalse(t.output.pad.rightThumb)
        t.ended(2, time: 0.4)
        XCTAssertFalse(t.output.pad.leftThumb)
        // The tap that ended a double tap does not start another.
        t.began(3, at: p(100, 300), time: 0.5)
        XCTAssertFalse(t.output.pad.leftThumb)
        t.ended(3, time: 0.55)
        // Too slow: no thumb.
        t.began(4, at: p(100, 300), time: 1.0)
        XCTAssertFalse(t.output.pad.leftThumb)
        t.ended(4, time: 1.1)
        // A drag is not a tap.
        t.began(5, at: p(100, 300), time: 2.0)
        t.moved(5, at: p(160, 300), time: 2.1)
        t.ended(5, time: 2.15)
        t.began(6, at: p(100, 300), time: 2.2)
        XCTAssertFalse(t.output.pad.leftThumb)
        // The right stick's own double tap is R3.
        t.began(7, at: p(598, 330), time: 3.0)
        t.ended(7, time: 3.05)
        t.began(8, at: p(598, 330), time: 3.2)
        XCTAssertTrue(t.output.pad.rightThumb)
    }

    func testTwoStickFingersTakeTheStrongerDeflection() {
        var t = TouchControls(targets: [right])
        t.began(1, at: p(560, 300), time: 0)
        t.began(2, at: p(600, 340), time: 0)
        t.moved(1, at: p(583, 300), time: 0.1)    // 0.5 right
        t.moved(2, at: p(600, 380), time: 0.1)    // ~0.87 down
        XCTAssertEqual(t.output.pad.ry, -40.0 / 46.0, accuracy: 0.001)
        XCTAssertEqual(t.output.pad.rx, 0, accuracy: 0.001)
        t.ended(2, time: 0.2)
        XCTAssertEqual(t.output.pad.rx, 0.5, accuracy: 0.001)
    }

    func testDpadEightWaysAndItsDeadZone() {
        var t = TouchControls(targets: [dpad])
        let c = dpad.frame.center
        t.began(1, at: c, time: 0)
        XCTAssertEqual(t.output.pad, PadInput())   // the centre holds nothing
        t.moved(1, at: p(c.x, c.y - 40), time: 0.1)
        XCTAssertTrue(t.output.pad.up)
        XCTAssertFalse(t.output.pad.left || t.output.pad.right || t.output.pad.down)
        t.moved(1, at: p(c.x + 30, c.y + 30), time: 0.2)
        XCTAssertTrue(t.output.pad.down && t.output.pad.right)
        XCTAssertFalse(t.output.pad.up || t.output.pad.left)
        t.moved(1, at: p(c.x - 40, c.y + 5), time: 0.3)
        XCTAssertTrue(t.output.pad.left)
        XCTAssertFalse(t.output.pad.down || t.output.pad.up)
        t.ended(1, time: 0.4)
        XCTAssertEqual(t.output.pad, PadInput())
    }

    func testToggleFlipsOnEachPress() {
        let crouch = TouchTarget(id: "crouch", kind: .button(.key(0x43, []), .toggle), frame: TouchRect(x: 0, y: 0, width: 40, height: 40))
        var t = TouchControls(targets: [crouch])
        t.began(1, at: p(10, 10), time: 0)
        t.ended(1, time: 0.1)
        XCTAssertEqual(t.output.keys, [.key(0x43, [])])
        XCTAssertEqual(t.held, ["crouch"])
        t.began(2, at: p(10, 10), time: 1)
        XCTAssertEqual(t.output.keys, [])
        t.ended(2, time: 1.1)
        XCTAssertEqual(t.output.keys, [])
    }

    func testRepeatPressesAgainWhileHeld() {
        let fire = TouchTarget(id: "fire", kind: .button(.pad(.x), .repeat), frame: TouchRect(x: 0, y: 0, width: 40, height: 40))
        var t = TouchControls(targets: [fire])
        t.began(1, at: p(10, 10), time: 10)
        XCTAssertTrue(t.needsClock)
        XCTAssertTrue(t.output.pad.x)
        t.tick(time: 10.07)
        XCTAssertFalse(t.output.pad.x)
        t.tick(time: 10.12)
        XCTAssertTrue(t.output.pad.x)
        t.ended(1, time: 10.13)
        XCTAssertFalse(t.output.pad.x)
        XCTAssertFalse(t.needsClock)
    }

    func testReleaseAllLetsGoOfEverythingAndLaterTouchesWork() {
        let crouch = TouchTarget(id: "crouch", kind: .button(.key(0x43, []), .toggle), frame: TouchRect(x: 0, y: 0, width: 40, height: 40))
        var t = TouchControls(targets: [a, lt, left, crouch])
        t.began(1, at: p(710, 310), time: 0)
        t.began(2, at: p(50, 90), time: 0)
        t.began(3, at: p(200, 300), time: 0)
        t.moved(3, at: p(250, 300), time: 0.1)
        t.began(4, at: p(10, 10), time: 0)
        XCTAssertNotEqual(t.output, TouchOutput())
        t.releaseAll()   // the menu opened, the app left the front
        XCTAssertEqual(t.output, TouchOutput())
        XCTAssertEqual(t.held, [])
        t.ended(1, time: 0.2)   // UIKit's late end of a released finger changes nothing
        t.moved(3, at: p(260, 300), time: 0.2)
        XCTAssertEqual(t.output, TouchOutput())
        XCTAssertTrue(t.began(5, at: p(710, 310), time: 1))
        XCTAssertTrue(t.output.pad.a)
    }

    func testANewLayoutReleasesWhatTheOldOneHeld() {
        var t = TouchControls(targets: [a])
        t.began(1, at: p(710, 310), time: 0)
        t.setTargets([b])
        XCTAssertEqual(t.output, TouchOutput())
        t.ended(1, time: 0.1)
        XCTAssertTrue(t.began(2, at: p(770, 260), time: 0.2))
        XCTAssertTrue(t.output.pad.b)
    }

    func testPlayportAndMouseActionsReachTheOutput() {
        let menu = TouchTarget(id: "playport", kind: .button(.playport(.menu), .hold), frame: TouchRect(x: 387, y: 8, width: 100, height: 26))
        let click = TouchTarget(id: "click", kind: .button(.mouse(.left), .hold), frame: TouchRect(x: 0, y: 0, width: 40, height: 40))
        var t = TouchControls(targets: [menu, click])
        t.began(1, at: p(400, 20), time: 0)
        t.began(2, at: p(5, 5), time: 0)
        XCTAssertEqual(t.output.playport, [.menu])
        XCTAssertEqual(t.output.mouse, [.left])
    }
}

final class InputMixerTests: XCTestCase {
    func values(buttons: UInt16 = 0, lt: UInt8 = 0, lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0) -> PadValues {
        var v = PadValues()
        v.buttons = buttons; v.leftTrigger = lt; v.lx = lx; v.ly = ly; v.rx = rx
        return v
    }

    func touch(_ body: (inout PadInput) -> Void) -> TouchOutput {
        var t = TouchOutput()
        body(&t.pad)
        return t
    }

    func testMadeirasMergeRule() {
        let physical = values(buttons: PadMapping.a, lt: 37, lx: 1000, ly: 2000)
        XCTAssertEqual(InputMixer.merge(physical: physical, touch: PadValues()), physical)
        var t = values(buttons: PadMapping.b, lt: 255, rx: 10000)
        var m = InputMixer.merge(physical: physical, touch: t)
        XCTAssertEqual(m.buttons, PadMapping.a | PadMapping.b)
        XCTAssertEqual(m.leftTrigger, 255)
        XCTAssertEqual(m.rx, 10000)
        XCTAssertEqual([m.lx, m.ly], [1000, 2000])   // a resting touch stick keeps the physical value
        t = values(lx: -32768)
        m = InputMixer.merge(physical: values(lx: 20000), touch: t)
        XCTAssertEqual(m.lx, 20000)                  // a deflected physical stick wins
        m = InputMixer.merge(physical: values(lx: 7000), touch: t)
        XCTAssertEqual(m.lx, -32768)                 // inside the dead zone, the touch stick wins
    }

    func testTouchAloneIsSlotZeroAndOffDisconnectsIt() {
        var mixer = InputMixer()
        var r = mixer.touch(TouchOutput())
        XCTAssertEqual(r.slot0, .set(PadValues()))   // on with nothing held: player 1 is connected
        XCTAssertTrue(mixer.touchOn)
        r = mixer.touch(touch { $0.a = true })
        XCTAssertEqual(r.slot0, .set(values(buttons: PadMapping.a)))
        r = mixer.touch(touch { $0.a = true })
        XCTAssertEqual(r.slot0, .unchanged)
        r = mixer.touch(nil)
        XCTAssertEqual(r.slot0, .disconnect)
        XCTAssertFalse(mixer.touchOn)
    }

    func testAPhysicalPadAndTouchTogether() {
        var mixer = InputMixer()
        XCTAssertEqual(mixer.physical(slot: 0, values(buttons: PadMapping.x)), values(buttons: PadMapping.x))
        var r = mixer.touch(touch { $0.a = true })
        XCTAssertEqual(r.slot0, .set(values(buttons: PadMapping.x | PadMapping.a)))
        XCTAssertEqual(mixer.physical(slot: 0, PadValues()), values(buttons: PadMapping.a))
        // Other slots pass through.
        XCTAssertEqual(mixer.physical(slot: 1, values(buttons: PadMapping.y)), values(buttons: PadMapping.y))
        // Releasing touch leaves the physical pad's own.
        _ = mixer.physical(slot: 0, values(buttons: PadMapping.x))
        r = mixer.touch(TouchOutput())
        XCTAssertEqual(r.slot0, .set(values(buttons: PadMapping.x)))
        // The pad leaves: slot 0 stays the controls'.
        XCTAssertEqual(mixer.physicalLeft(slot: 0), .set(PadValues()))
        XCTAssertEqual(mixer.physicalLeft(slot: 1), .disconnect)
        // The controls go off with a pad in slot 0: the pad's values alone.
        _ = mixer.physical(slot: 0, values(buttons: PadMapping.b))
        r = mixer.touch(nil)
        XCTAssertEqual(r.slot0, .unchanged)
        XCTAssertEqual(mixer.slot0, values(buttons: PadMapping.b))
        XCTAssertEqual(mixer.physicalLeft(slot: 0), .disconnect)
    }

    func testKeysGoDownModifiersFirstAndUpKeyFirst() {
        var mixer = InputMixer()
        var t = TouchOutput()
        t.keys = [.key(0x31, .shift)]
        XCTAssertEqual(mixer.touch(t).outputs, [.key(0xA0, down: true), .key(0x31, down: true)])
        t.keys.insert(.key(0x20, []))
        XCTAssertEqual(mixer.touch(t).outputs, [.key(0x20, down: true)])
        XCTAssertEqual(mixer.touch(TouchOutput()).outputs,
                       [.key(0x20, down: false), .key(0x31, down: false), .key(0xA0, down: false)])
    }

    func testMouseButtonsHoldTheWheelAndMenuHappenOnce() {
        var mixer = InputMixer()
        var t = TouchOutput()
        t.mouse = [.left, .wheelUp]
        t.playport = [.menu]
        XCTAssertEqual(mixer.touch(t).outputs, [.pointer(flags: Pointer.leftDown, data: 0),
                                                .pointer(flags: Pointer.wheel, data: 120), .playport(.menu)])
        XCTAssertEqual(mixer.touch(t).outputs, [])
        XCTAssertEqual(mixer.touch(nil).outputs, [.pointer(flags: Pointer.leftUp, data: 0)])
        t.mouse = [.wheelDown]
        XCTAssertEqual(mixer.touch(t).outputs, [.pointer(flags: Pointer.wheel, data: UInt32(bitPattern: -120)), .playport(.menu)])
    }

    func testReleaseOnPauseThroughTheMixer() {
        var controls = TouchControls(targets: [
            TouchTarget(id: "a", kind: .button(.pad(.a), .hold), frame: TouchRect(x: 0, y: 0, width: 50, height: 50)),
            TouchTarget(id: "w", kind: .button(.key(0x57, []), .hold), frame: TouchRect(x: 60, y: 0, width: 50, height: 50)),
        ])
        var mixer = InputMixer()
        _ = mixer.touch(controls.output)
        controls.began(1, at: TouchPoint(x: 10, y: 10), time: 0)
        controls.began(2, at: TouchPoint(x: 70, y: 10), time: 0)
        var r = mixer.touch(controls.output)
        XCTAssertEqual(r.slot0, .set(values(buttons: PadMapping.a)))
        XCTAssertEqual(r.outputs, [.key(0x57, down: true)])
        controls.releaseAll()   // the in-game menu opened
        r = mixer.touch(controls.output)
        XCTAssertEqual(r.slot0, .set(PadValues()))
        XCTAssertEqual(r.outputs, [.key(0x57, down: false)])
    }
}

final class InputActionTests: XCTestCase {
    func testNamesRoundTrip() throws {
        let all: [InputAction] = PadControl.allCases.map { .pad($0) } + MouseAction.allCases.map { .mouse($0) }
            + [.key(0x20, []), .key(0x31, [.shift, .control]), .key(0x1B, .alt), .playport(.menu)]
        for a in all {
            XCTAssertEqual(InputAction(name: a.name), a, a.name)
            let data = try JSONEncoder().encode([a])
            XCTAssertEqual(try JSONDecoder().decode([InputAction].self, from: data), [a])
        }
        XCTAssertEqual(InputAction.key(0x31, [.shift, .control]).name, "key:shift+ctrl+0x31")
        XCTAssertEqual(InputAction(name: "key:32"), .key(0x20, []))
        XCTAssertEqual(PadControl.leftStick.thumb, .ls)
        XCTAssertNil(PadControl.a.thumb)
    }

    func testUnknownNamesAreRefused() {
        for s in ["", "pad", "pad:z", "key:", "key:0x00", "key:meta+0x20", "key:0x1FF", "mouse:back", "playport:quit", "gyro:on"] {
            XCTAssertNil(InputAction(name: s), s)
        }
        XCTAssertThrowsError(try JSONDecoder().decode([InputAction].self, from: Data(#"["pad:z"]"#.utf8)))
    }
}
