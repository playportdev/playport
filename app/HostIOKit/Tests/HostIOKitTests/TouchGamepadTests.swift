// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import HostIOKit

final class TouchGamepadTests: XCTestCase {
    func testIdleTouchPreservesPhysicalValuesInsideTheDefaultDeadZones() {
        var mixer = TouchPadMixer(), physical = PadValues()
        physical.lx = 1234; physical.ly = -2345; physical.rx = -3456; physical.ry = 4567
        XCTAssertEqual(mixer.input(slot: 0, physical), physical)
        var touch = PadValues(); touch.lx = 32767
        XCTAssertEqual(mixer.input(touch: touch).lx, 32767)
        XCTAssertEqual(mixer.input(touch: PadValues()), physical)
    }

    func testTwoFingersOnButtonAndIndependentStick() {
        var pad = TouchGamepad()
        pad.begin(1, control: .a); pad.begin(2, control: .a)
        pad.begin(3, control: .leftStick)
        pad.move(3, x: 1, y: 1)
        pad.end(1)
        XCTAssertTrue(pad.input.a)
        XCTAssertEqual(pad.input.lx, 1 / Float(2).squareRoot(), accuracy: 0.001)
        XCTAssertEqual(pad.input.ly, pad.input.lx)
        pad.end(2)
        XCTAssertFalse(pad.input.a)
        XCTAssertGreaterThan(pad.input.lx, 0)
        pad.reset()
        XCTAssertEqual(pad.input, PadInput())
    }

    func testSecondFingerCannotTakeOverStick() {
        var pad = TouchGamepad()
        pad.begin(1, control: .rightStick); pad.move(1, x: -1, y: 0)
        pad.begin(2, control: .rightStick); pad.move(2, x: 1, y: 0); pad.end(2)
        XCTAssertEqual(pad.input.rx, -1)
        pad.end(1)
        XCTAssertEqual(pad.input.rx, 0)
    }

    func testButtonsAndTriggersReachXInput() {
        var pad = TouchGamepad()
        for (id, control) in TouchGamepad.Control.allCases.enumerated() { pad.begin(id, control: control) }
        let v = PadMapping.values(pad.input)
        XCTAssertEqual(v.buttons, 0xf3ff)
        XCTAssertEqual(v.leftTrigger, 255)
        XCTAssertEqual(v.rightTrigger, 255)
    }

    func testPhysicalAndTouchSharePlayerOneWithoutChangingOtherSlots() {
        var mixer = TouchPadMixer()
        var touch = PadValues(); touch.buttons = PadMapping.a; touch.lx = -32768; touch.rightTrigger = 255
        XCTAssertEqual(mixer.input(touch: touch), touch)
        var physical = PadValues(); physical.buttons = PadMapping.b; physical.lx = 32767; physical.leftTrigger = 128
        let merged = mixer.input(slot: 0, physical)
        XCTAssertEqual(merged.buttons, PadMapping.a | PadMapping.b)
        XCTAssertEqual(merged.lx, 32767)
        XCTAssertEqual(merged.leftTrigger, 128)
        XCTAssertEqual(merged.rightTrigger, 255)
        XCTAssertEqual(mixer.input(slot: 1, physical), physical)
        mixer.disconnect(slot: 0)
        XCTAssertEqual(mixer.combined, touch)
        XCTAssertEqual(mixer.input(touch: PadValues()), PadValues())
    }

    func testTouchGoesThroughMenuGateAndCannotRemainHeldOnResume() {
        var mixer = TouchPadMixer(), gate = GuestPadGate()
        var touch = PadValues(); touch.buttons = PadMapping.a; touch.lx = -32768
        _ = gate.input(slot: 0, mixer.input(touch: touch))
        XCTAssertEqual(gate.hold(.menu), [0])
        XCTAssertNil(gate.input(slot: 0, mixer.input(touch: PadValues())))
        XCTAssertEqual(gate.release(.menu).first?.values, PadValues())
        XCTAssertEqual(gate.input(slot: 0, mixer.input(touch: touch)), touch)
    }
}
