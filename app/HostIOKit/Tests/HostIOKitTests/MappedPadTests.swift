// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import HostIOKit

/// Controller maps (docs/plans/2026-10-09-touch-controls.md, phase 3):
/// ControllerBindings, MappedPad, and InputMixer's mapped pads.
final class MappedPadTests: XCTestCase {
    /// A table with every mapping kind (the keyboardMouse preset itself is PlayportKit's: ControllerMapTests).
    let table = ControllerBindings([
        .stickDirection(.leftStick, .up): .key(0x57, []), .stickDirection(.leftStick, .left): .key(0x41, []),
        .stickDirection(.leftStick, .down): .key(0x53, []), .stickDirection(.leftStick, .right): .key(0x44, []),
        .control(.rightStick): .mouse(.move),
        .control(.rt): .mouse(.left), .control(.lt): .mouse(.right),
        .control(.a): .key(0x20, []), .control(.x): .key(0x31, .shift),
        .control(.up): .key(0x31, []), .control(.back): .key(0x09, []), .control(.start): .key(0x1B, []),
        .control(.rb): .mouse(.wheelUp), .control(.lb): .playport(.menu),
    ])!

    func pad(buttons: UInt16 = 0, lt: UInt8 = 0, rt: UInt8 = 0, lx: Double = 0, ly: Double = 0, rx: Double = 0, ry: Double = 0) -> PadValues {
        var v = PadValues()
        v.buttons = buttons; v.leftTrigger = lt; v.rightTrigger = rt
        v.lx = Int16(lx * 32767); v.ly = Int16(ly * 32767); v.rx = Int16(rx * 32767); v.ry = Int16(ry * 32767)
        return v
    }

    // MARK: the table

    func testInputNamesRoundTripAndHomeIsNone() {
        for i in ControllerInput.all { XCTAssertEqual(ControllerInput(name: i.name), i, i.name) }
        XCTAssertEqual(ControllerInput.stickDirection(.leftStick, .up).name, "leftStick.up")
        for bad in ["home", "a.up", "leftStick.forward", "", "leftStick.up.x", "guide"] { XCTAssertNil(ControllerInput(name: bad), bad) }
        XCTAssertEqual(ControllerInput.all.count, PadControl.allCases.count + 8)
    }

    func testAStickActionOnlyOnAWholeStick() {
        XCTAssertNil(ControllerBindings([.control(.a): .mouse(.move)]))
        XCTAssertNil(ControllerBindings([.control(.a): .pad(.leftStick)]))
        XCTAssertNil(ControllerBindings([.stickDirection(.leftStick, .up): .mouse(.move)]))
        XCTAssertNil(ControllerBindings([.control(.leftStick): .key(0x57, [])]))
        // A stick is whole or by direction, not both.
        XCTAssertNil(ControllerBindings([.control(.leftStick): .mouse(.move), .stickDirection(.leftStick, .up): .key(0x57, [])]))
        XCTAssertNotNil(ControllerBindings([.control(.leftStick): .pad(.rightStick), .control(.a): .pad(.b)]))
    }

    func testTheTableIsSavedByName() throws {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        let small = ControllerBindings([.control(.a): .key(0x20, []), .stickDirection(.leftStick, .up): .key(0x57, []),
                                        .control(.rightStick): .mouse(.move)])!
        XCTAssertEqual(String(decoding: try e.encode(small), as: UTF8.self),
                       #"{"a":"key:0x20","leftStick.up":"key:0x57","rightStick":"mouse:move"}"#)
        XCTAssertEqual(try JSONDecoder().decode(ControllerBindings.self, from: try e.encode(table)), table)
        for bad in [#"{"home":"key:0x20"}"#, #"{"a":"mouse:move"}"#, #"{"a":"key:0x00"}"#, #"[]"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(ControllerBindings.self, from: Data(bad.utf8)), bad)
        }
    }

    // MARK: MappedPad

    func testAButtonHoldsItsKey() {
        var m = MappedPad(bindings: table)
        XCTAssertEqual(m.update(pad(buttons: PadMapping.a)), [])
        XCTAssertEqual(m.keys, [.key(0x20, [])])
        XCTAssertEqual(m.pad, PadValues())   // the slot rests
        _ = m.update(pad())
        XCTAssertEqual(m.keys, [])
    }

    func testATriggerIsAMouseButtonWithHysteresis() {
        var m = MappedPad(bindings: table)
        _ = m.update(pad(rt: 120))   // 0.47: under pressAt
        XCTAssertEqual(m.buttons, [])
        _ = m.update(pad(rt: 128))   // 0.502
        XCTAssertEqual(m.buttons, [.left])
        _ = m.update(pad(rt: 110))   // 0.43: still over releaseAt
        XCTAssertEqual(m.buttons, [.left])
        _ = m.update(pad(rt: 100))   // 0.39
        XCTAssertEqual(m.buttons, [])
        _ = m.update(pad(rt: 110))   // up from below: not pressed again until pressAt
        XCTAssertEqual(m.buttons, [])
        _ = m.update(pad(lt: 255, rt: 255))
        XCTAssertEqual(m.buttons, [.left, .right])
    }

    func testAStickIsWASDWithDiagonalsAndHysteresis() {
        var m = MappedPad(bindings: table)
        _ = m.update(pad(ly: 0.49))
        XCTAssertEqual(m.keys, [])
        _ = m.update(pad(ly: 0.6))
        XCTAssertEqual(m.keys, [.key(0x57, [])])            // W
        _ = m.update(pad(ly: 0.45))
        XCTAssertEqual(m.keys, [.key(0x57, [])])            // held over releaseAt
        _ = m.update(pad(ly: 0.3))
        XCTAssertEqual(m.keys, [])
        _ = m.update(pad(lx: 0.707, ly: 0.707))
        XCTAssertEqual(m.keys, [.key(0x57, []), .key(0x44, [])])   // W + D
        _ = m.update(pad(lx: -0.707, ly: -0.707))
        XCTAssertEqual(m.keys, [.key(0x53, []), .key(0x41, [])])   // S + A
        _ = m.update(pad(lx: -1))
        XCTAssertEqual(m.keys, [.key(0x41, [])])
    }

    func testTheMouseCurve() {
        let t = MappedPad.Tuning.self
        XCTAssertEqual(t.velocity(x: 0.15, y: 0).dx, 0)
        XCTAssertEqual(t.velocity(x: 0.1, y: 0.1).dx, 0)              // 0.141: in the dead zone
        XCTAssertEqual(t.velocity(x: 1, y: 0).dx, t.mouseMaxSpeed, accuracy: 1e-9)
        XCTAssertEqual(t.velocity(x: 0, y: 1).dy, -t.mouseMaxSpeed, accuracy: 1e-9)   // stick up: mouse up (-y)
        XCTAssertEqual(t.velocity(x: -1, y: 0).dx, -t.mouseMaxSpeed, accuracy: 1e-9)
        let half = 0.15 + 0.85 / 2
        XCTAssertEqual(t.velocity(x: half, y: 0).dx, t.mouseMaxSpeed * pow(0.5, t.mouseCurve), accuracy: 1e-9)
        // Beyond the rim, no more.
        XCTAssertEqual(t.velocity(x: 1, y: 1).dx, t.mouseMaxSpeed / 2.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(t.velocity(x: .nan, y: 0).dx, 0)
    }

    func testAStickMovesTheMouseExactlyOverManyTicks() {
        var m = MappedPad(bindings: table)
        _ = m.update(pad(rx: 0.4, ry: -0.3))
        XCTAssertTrue(m.needsClock)
        let v = MappedPad.Tuning.velocity(x: MappedPad.unit(Int16(0.4 * 32767)), y: MappedPad.unit(Int16(-0.3 * 32767)))
        var sx = 0, sy = 0
        let dt = 1.0 / 120
        XCTAssertEqual(m.tick(time: 10), [])   // the first tick only starts the clock
        for i in 1...1200 {
            for case .move(let dx, let dy) in m.tick(time: 10 + Double(i) * dt) { sx += Int(dx); sy += Int(dy) }
        }
        // Ten seconds: every whole count out, under one carried.
        XCTAssertEqual(Double(sx), v.dx * 10, accuracy: 1)
        XCTAssertEqual(Double(sy), v.dy * 10, accuracy: 1)
        XCTAssertGreaterThan(sx, 0); XCTAssertGreaterThan(sy, 0)   // stick down: mouse down (+y)
        // A slow stick still moves, a count at a time.
        var slow = MappedPad(bindings: table)
        _ = slow.update(pad(rx: 0.2))
        var n = 0
        for i in 0...600 { for case .move(let dx, _) in slow.tick(time: Double(i) * dt) { n += Int(dx) } }
        XCTAssertEqual(Double(n), MappedPad.Tuning.velocity(x: MappedPad.unit(Int16(0.2 * 32767)), y: 0).dx * 5, accuracy: 1)
        XCTAssertGreaterThan(n, 0)
        // At rest: no clock, nothing moves.
        _ = slow.update(pad())
        XCTAssertFalse(slow.needsClock)
        XCTAssertEqual(slow.tick(time: 100), [])
    }

    func testLookSpeedScalesTheMouseOnly() {
        let t = MappedPad.Tuning.self
        XCTAssertEqual(t.velocity(x: 1, y: 0, lookSpeed: 2).dx, 2 * t.mouseMaxSpeed, accuracy: 1e-9)
        XCTAssertEqual(t.velocity(x: 0, y: 1, lookSpeed: 0.25).dy, -0.25 * t.mouseMaxSpeed, accuracy: 1e-9)
        XCTAssertEqual(t.velocity(x: 1, y: 0, lookSpeed: .nan).dx, t.mouseMaxSpeed, accuracy: 1e-9)
        XCTAssertEqual(t.velocity(x: 1, y: 0, lookSpeed: -1).dx, 0)
        // Two seconds at full right: 4000 counts at 1×, 12000 at 3×.
        func counts(_ speed: Double) -> Int {
            var m = MappedPad(bindings: table, lookSpeed: speed)
            _ = m.update(pad(rx: 1))
            var n = 0
            for i in 0...240 { for case .move(let dx, _) in m.tick(time: Double(i) / 120) { n += Int(dx) } }
            return n
        }
        XCTAssertEqual(Double(counts(1)), 2 * t.mouseMaxSpeed, accuracy: 1)
        XCTAssertEqual(Double(counts(3)), 6 * t.mouseMaxSpeed, accuracy: 1)
    }

    func testANewLookSpeedChangesTheMixerInPlace() {
        // Ticks 1/32 s apart (exact in binary): 62.5 counts a tick at full right, 1×.
        func moved(_ mixer: inout InputMixer, ticks: ClosedRange<Int>) -> Int {
            var n = 0
            for i in ticks {
                mixer.tick(time: Double(i) / 32)
                for case .move(let dx, _) in mixer.takeOutputs() { n += Int(dx) }
            }
            return n
        }
        var mixer = InputMixer()
        _ = mixer.setMap(table)
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.a, rx: 1))
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x20, down: true)])
        XCTAssertEqual(moved(&mixer, ticks: 0...4), 250)
        // The same table at 2×: Space stays down, the slot is not sent again, the speed doubles.
        XCTAssertEqual(mixer.setMap(table, lookSpeed: 2).count, 0)
        XCTAssertEqual(mixer.lookSpeed, 2)
        XCTAssertEqual(mixer.takeOutputs(), [])
        XCTAssertEqual(moved(&mixer, ticks: 5...8), 500)
        // A pad that connects later plays at the new speed too (its first tick only starts its clock).
        _ = mixer.physical(slot: 1, pad(rx: 1))
        _ = mixer.takeOutputs()
        XCTAssertEqual(moved(&mixer, ticks: 9...12), 500 + 375)
    }

    func testAStalledClockDoesNotJumpTheView() {
        var m = MappedPad(bindings: table)
        _ = m.update(pad(rx: 1))
        _ = m.tick(time: 0)
        let out = m.tick(time: 2)
        XCTAssertEqual(out, [.move(dx: Int32(MappedPad.Tuning.mouseMaxSpeed * MappedPad.Tuning.maxTickGap), dy: 0)])
    }

    func testTheWheelTurnsOnPressThenRepeats() {
        var m = MappedPad(bindings: table)
        XCTAssertEqual(m.update(pad(buttons: PadMapping.rightShoulder)), [.pointer(flags: Pointer.wheel, data: 120)])
        XCTAssertTrue(m.needsClock)
        XCTAssertEqual(m.tick(time: 0), [])
        XCTAssertEqual(m.tick(time: 0.3), [])
        XCTAssertEqual(m.tick(time: 0.36), [.pointer(flags: Pointer.wheel, data: 120)])
        XCTAssertEqual(m.tick(time: 0.40), [])
        XCTAssertEqual(m.tick(time: 0.46), [.pointer(flags: Pointer.wheel, data: 120)])
        XCTAssertEqual(m.update(pad()), [])
        XCTAssertFalse(m.needsClock)
        XCTAssertEqual(m.tick(time: 1), [])
    }

    func testPlayportsActionOnceAsItGoesDown() {
        var m = MappedPad(bindings: table)
        XCTAssertEqual(m.update(pad(buttons: PadMapping.leftShoulder)), [.playport(.menu)])
        XCTAssertEqual(m.update(pad(buttons: PadMapping.leftShoulder)), [])
    }

    func testPadActionsMakeTheSlotsValues() {
        let b = ControllerBindings([.control(.a): .pad(.b), .control(.lt): .pad(.rt), .control(.rt): .pad(.a),
                                    .control(.leftStick): .pad(.rightStick), .stickDirection(.rightStick, .up): .pad(.lb)])!
        var m = MappedPad(bindings: b)
        _ = m.update(pad(buttons: PadMapping.a | PadMapping.x, lt: 77, rt: 200, lx: 0.5, ly: -0.25, ry: 0.9))
        var want = pad(rx: 0.5, ry: -0.25)
        want.buttons = PadMapping.b | PadMapping.a | PadMapping.leftShoulder   // X is not bound: nothing
        want.rightTrigger = 77                                                 // a trigger to a trigger stays analogue
        XCTAssertEqual(m.pad, want)
        XCTAssertEqual(m.keys, [])
    }

    func testAnInputDownAsTheMapStartsWaitsUntilLetGo() {
        var m = MappedPad(bindings: table, values: pad(buttons: PadMapping.a))
        XCTAssertEqual(m.keys, [])
        _ = m.update(pad(buttons: PadMapping.a))
        XCTAssertEqual(m.keys, [])
        _ = m.update(pad())
        _ = m.update(pad(buttons: PadMapping.a))
        XCTAssertEqual(m.keys, [.key(0x20, [])])
    }

    func testHeldNothingActsAndWhatWasHeldWaitsForRelease() {
        var m = MappedPad(bindings: table)
        _ = m.update(pad(buttons: PadMapping.a, rx: 1))
        m.hold(.menu, true)
        XCTAssertEqual(m.keys, [])
        XCTAssertFalse(m.needsClock)
        XCTAssertEqual(m.update(pad(buttons: PadMapping.a | PadMapping.leftShoulder, rx: 1)), [])   // the menu's press
        m.hold(.menu, false)
        _ = m.update(pad(buttons: PadMapping.a | PadMapping.leftShoulder, rx: 1))
        XCTAssertEqual(m.keys, [])               // A held through the menu: not pressed again
        XCTAssertTrue(m.needsClock)              // a stick moves the mouse again at once
        _ = m.update(pad(rx: 1))
        XCTAssertEqual(m.update(pad(buttons: PadMapping.a | PadMapping.leftShoulder)), [.playport(.menu)])
        XCTAssertEqual(m.keys, [.key(0x20, [])])
    }

    // MARK: InputMixer with a map

    func testAMappedPadPublishesRestAndSendsActions() {
        var mixer = InputMixer()
        XCTAssertEqual(mixer.setMap(table).count, 0)
        XCTAssertEqual(mixer.physical(slot: 0, pad(buttons: PadMapping.a | PadMapping.dpadUp, rt: 255, lx: 1)), PadValues())
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x20, down: true), .key(0x31, down: true), .key(0x44, down: true),
                                             .pointer(flags: Pointer.leftDown, data: 0)])
        XCTAssertEqual(mixer.physical(slot: 2, pad(buttons: PadMapping.back)), PadValues())
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x09, down: true)])
        XCTAssertEqual(mixer.physical(slot: 0, pad(buttons: PadMapping.start)), PadValues())
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x44, down: false), .key(0x31, down: false), .key(0x20, down: false),
                                             .key(0x1B, down: true), .pointer(flags: Pointer.leftUp, data: 0)])
        // The pad leaves: what it held goes up.
        XCTAssertEqual(mixer.physicalLeft(slot: 2), .disconnect)
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x09, down: false)])
        XCTAssertEqual(mixer.slot0, PadValues())
        // Gyro aim's pause button still reads what the player holds.
        XCTAssertEqual(mixer.slot0Input, pad(buttons: PadMapping.start))
    }

    func testModifiersGoDownFirstAndAKeyHeldTwiceUpOnce() {
        var mixer = InputMixer()
        _ = mixer.setMap(table)
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.x))   // key:shift+0x31
        XCTAssertEqual(mixer.takeOutputs(), [.key(0xA0, down: true), .key(0x31, down: true)])
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.x | PadMapping.dpadUp))   // and 0x31 alone: held once
        XCTAssertEqual(mixer.takeOutputs(), [])
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.dpadUp))
        XCTAssertEqual(mixer.takeOutputs(), [.key(0xA0, down: false)])
        _ = mixer.physical(slot: 0, pad())
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x31, down: false)])
        // A key the controls and a mapped pad both hold goes up when neither does.
        var t = TouchOutput()
        t.keys = [.key(0x20, [])]
        XCTAssertEqual(mixer.touch(t).outputs, [.key(0x20, down: true)])
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.a))
        XCTAssertEqual(mixer.takeOutputs(), [])
        XCTAssertEqual(mixer.touch(TouchOutput()).outputs, [])
        _ = mixer.physical(slot: 0, pad())
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x20, down: false)])
    }

    /// A chord newly held while its key is down alone (0x31 from the d-pad, then
    /// X's shift+0x31): the key goes up, the modifier down, then the key again,
    /// so the game sees shift+0x31, not 0x31 then shift.
    func testAChordOverItsKeyAlreadyDownPressesTheKeyAgainAfterTheModifier() {
        var mixer = InputMixer()
        _ = mixer.setMap(table)
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.dpadUp))
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x31, down: true)])
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.dpadUp | PadMapping.x))
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x31, down: false), .key(0xA0, down: true), .key(0x31, down: true)])
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.dpadUp | PadMapping.x | PadMapping.a))
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x20, down: true)])   // the chord still held: nothing again
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.dpadUp))
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x20, down: false), .key(0xA0, down: false)])
        _ = mixer.physical(slot: 0, pad())
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x31, down: false)])
        // The touch controls' key under a mapped pad's chord: the same order.
        var t = TouchOutput()
        t.keys = [.key(0x31, [])]
        XCTAssertEqual(mixer.touch(t).outputs, [.key(0x31, down: true)])
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.x))
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x31, down: false), .key(0xA0, down: true), .key(0x31, down: true)])
    }

    /// The guest's windows before the first frame take the pads' presses
    /// (WindowKeys): a mapped pad holds nothing meanwhile, so A is Enter alone,
    /// not Enter and the map's Space; A held as they go waits until let go.
    func testTheGuestsWindowsHoldMappedPads() {
        XCTAssertTrue(WindowKeys.takesPads(windowsShown: true, menuUp: false))
        XCTAssertFalse(WindowKeys.takesPads(windowsShown: true, menuUp: true))
        XCTAssertFalse(WindowKeys.takesPads(windowsShown: false, menuUp: false))
        XCTAssertEqual(WindowKeys.events(for: .a).map(\.vk), [0x0D, 0x0D])

        var mixer = InputMixer()
        _ = mixer.setMap(table)
        _ = mixer.physical(slot: 0, pad())
        mixer.hold(.windows, WindowKeys.takesPads(windowsShown: true, menuUp: false))
        XCTAssertEqual(mixer.takeOutputs(), [])
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.a, rt: 255, rx: 1))
        mixer.tick(time: 0)
        mixer.tick(time: 0.016)
        XCTAssertEqual(mixer.takeOutputs(), [])   // no Space, no left button, no mouse motion
        mixer.hold(.windows, false)               // the game's first frame
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.a))
        XCTAssertEqual(mixer.takeOutputs(), [])   // A held through the windows
        _ = mixer.physical(slot: 0, pad())
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.a))
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x20, down: true)])
    }

    /// The menu opens with RT held: the left button goes up, and stays up until RT is pressed again.
    func testTheMenuReleasesAMappedPadsKeysAndButtons() {
        var mixer = InputMixer()
        _ = mixer.setMap(table)
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.a, rt: 255))
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x20, down: true), .pointer(flags: Pointer.leftDown, data: 0)])
        mixer.hold(.menu, true)
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x20, down: false), .pointer(flags: Pointer.leftUp, data: 0)])
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.a | PadMapping.b, rt: 255))
        XCTAssertEqual(mixer.takeOutputs(), [])
        mixer.hold(.dialog, true)
        mixer.hold(.menu, false)
        XCTAssertEqual(mixer.takeOutputs(), [])   // the dialog still holds it
        mixer.hold(.dialog, false)
        _ = mixer.physical(slot: 0, pad(rt: 255))
        XCTAssertEqual(mixer.takeOutputs(), [])   // RT held through the menu
        _ = mixer.physical(slot: 0, pad())
        _ = mixer.physical(slot: 0, pad(rt: 255))
        XCTAssertEqual(mixer.takeOutputs(), [.pointer(flags: Pointer.leftDown, data: 0)])
    }

    func testTheLifecycleReleasesWhatAMappedPadHolds() {
        // HostIO sends the mixer's downs through Lifecycle, as the controls' and a keyboard's.
        var mixer = InputMixer(), life = Lifecycle()
        _ = mixer.setMap(table)
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.a, rt: 255))
        for o in mixer.takeOutputs() {
            switch o {
            case .key(let vk, true): XCTAssertTrue(life.keyDown(vk))
            case .pointer(Pointer.leftDown, _): XCTAssertTrue(life.buttonDown(upFlag: Pointer.leftUp))
            default: XCTFail("\(o)")
            }
        }
        XCTAssertEqual(life.handle(.resignActive), [.focus(false), .releaseKeys([0x20]), .releaseButtons([Pointer.leftUp])])
        // Let go while away: the ups are not sent again.
        _ = mixer.physical(slot: 0, pad())
        for o in mixer.takeOutputs() {
            switch o {
            case .key(let vk, false): XCTAssertFalse(life.keyUp(vk))
            case .pointer(Pointer.leftUp, _): XCTAssertFalse(life.buttonUp(upFlag: Pointer.leftUp))
            default: XCTFail("\(o)")
            }
        }
    }

    func testTheControlsPadIsNeverMapped() {
        var mixer = InputMixer()
        _ = mixer.setMap(table)
        // No controller: slot 0 is the controls' pad, unmapped.
        var t = TouchOutput()
        t.pad.a = true
        t.pad.rightTrigger = 1
        let r = mixer.touch(t)
        XCTAssertEqual(r.slot0, .set(pad(buttons: PadMapping.a, rt: 255)))
        XCTAssertEqual(r.outputs, [])
        XCTAssertEqual(mixer.takeOutputs(), [])
        // A mapped pad joins slot 0: its rest merged with the controls' pad, its A a key.
        XCTAssertEqual(mixer.physical(slot: 0, pad(buttons: PadMapping.a)), pad(buttons: PadMapping.a, rt: 255))
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x20, down: true)])
    }

    func testChangingTheMapReleasesAndRepublishes() {
        var mixer = InputMixer()
        let held = pad(buttons: PadMapping.a, lx: 0.2)
        XCTAssertEqual(mixer.physical(slot: 0, held), held)
        XCTAssertEqual(mixer.physical(slot: 1, pad(buttons: PadMapping.b)), pad(buttons: PadMapping.b))
        let on = mixer.setMap(table)
        XCTAssertEqual(on.map(\.slot), [0, 1])
        XCTAssertEqual(on.map(\.values), [PadValues(), PadValues()])
        XCTAssertEqual(mixer.takeOutputs(), [])   // A held as the map came: not pressed until let go
        _ = mixer.physical(slot: 0, pad())
        _ = mixer.physical(slot: 0, pad(buttons: PadMapping.a))
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x20, down: true)])
        let off = mixer.setMap(nil)
        XCTAssertEqual(off.map(\.values), [pad(buttons: PadMapping.a), pad(buttons: PadMapping.b)])
        XCTAssertEqual(mixer.takeOutputs(), [.key(0x20, down: false)])
        XCTAssertEqual(mixer.setMap(nil).count, 0)
    }

    func testStickAndGyroMouseAddUp() {
        var mixer = InputMixer()
        _ = mixer.setMap(table)
        _ = mixer.physical(slot: 0, pad(rx: 1))
        _ = mixer.physical(slot: 1, pad(rx: 1))
        XCTAssertTrue(mixer.needsClock)
        mixer.tick(time: 0)
        mixer.tick(time: 0.01)
        XCTAssertEqual(mixer.takeOutputs(), [.move(dx: 40, dy: 0)])   // two pads, 20 counts each in 10 ms
        // Gyro aim's mouse motion goes out beside it: the guest adds every relative move.
        XCTAssertEqual(mixer.gyro(.mouse(dx: 3, dy: -1)).outputs, [.move(dx: 3, dy: -1)])
        _ = mixer.physical(slot: 0, pad())
        _ = mixer.physical(slot: 1, pad())
        XCTAssertFalse(mixer.needsClock)
    }
}
