// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import HostIOKit
@testable import PlayportKit

/// The Controller page (ControllerMapping.dc.html): its rows, a Custom table's
/// edits, Y on a row, Reset all and Edit a copy, and the presses that ring a row.
final class ControllerMapPageTests: XCTestCase {
    let preset = ControllerMap.keyboardMouse

    func testTheRowsCoverEveryInputOnce() {
        XCTAssertEqual(ControllerMapRow.left + ControllerMapRow.right, ControllerMapRow.allCases)
        let covered = ControllerMapRow.allCases.flatMap(\.inputs)
        XCTAssertEqual(Set(covered), Set(ControllerInput.all))
        XCTAssertEqual(covered.count, ControllerInput.all.count)
        for i in ControllerInput.all { XCTAssertTrue(ControllerMapRow.row(of: i).inputs.contains(i), i.name) }
        XCTAssertEqual(ControllerMapRow.a.itemID, "ctl:a")
        XCTAssertEqual(ControllerMapRow.left.map(\.title), ["LT", "LB", "L stick", "L3", "D-pad", "View", "Menu"])
        XCTAssertEqual(ControllerMapRow.right.map(\.title), ["RT", "RB", "Y", "X", "B", "A", "R stick", "R3"])
    }

    func testThePresetsRowsAsTheBoardShowsThem() {
        XCTAssertEqual(ControllerMapRow.leftStick.caps(in: preset), ["W", "A", "S", "D"])
        XCTAssertEqual(ControllerMapRow.dpad.caps(in: preset), ["1", "2", "3", "4"])   // clockwise from up
        XCTAssertEqual(ControllerMapRow.rightStick.caps(in: preset), ["Mouse"])
        XCTAssertEqual(ControllerMapRow.rt.caps(in: preset), ["Left"])
        XCTAssertEqual(ControllerMapRow.lt.caps(in: preset), ["Right"])
        XCTAssertEqual(ControllerMapRow.a.caps(in: preset), ["Space"])
        XCTAssertEqual(ControllerMapRow.back.caps(in: preset), ["Tab"])
        XCTAssertEqual(ControllerMapRow.start.caps(in: preset), ["Esc"])
        XCTAssertEqual(ControllerMapRow.ls.caps(in: preset), ["–"])
        for row in ControllerMapRow.allCases { XCTAssertFalse(ControllerMapEdit.differs(row, in: preset), row.rawValue) }
    }

    func testSettingAnInputAndYPuttingJustItsRowBack() throws {
        var t = try XCTUnwrap(ControllerMapEdit.setting(.control(.a), .key(0x31, .shift), in: preset))
        t = try XCTUnwrap(ControllerMapEdit.setting(.control(.b), nil, in: t))
        XCTAssertEqual(t[.control(.a)], .key(0x31, .shift))
        XCTAssertNil(t[.control(.b)])
        XCTAssertTrue(ControllerMapEdit.differs(.a, in: t))
        XCTAssertTrue(ControllerMapEdit.differs(.b, in: t))
        XCTAssertFalse(ControllerMapEdit.differs(.x, in: t))
        // Y on A: A is Space again, B stays unbound.
        let back = ControllerMapEdit.reset(.a, in: t)
        XCTAssertEqual(back[.control(.a)], .key(0x20, []))
        XCTAssertNil(back[.control(.b)])
        XCTAssertFalse(ControllerMapEdit.differs(.a, in: back))
        // What an input does not take is refused.
        XCTAssertNil(ControllerMapEdit.setting(.control(.a), .mouse(.move), in: preset))
        XCTAssertNil(ControllerMapEdit.setting(.control(.leftStick), .key(0x57, []), in: preset))
    }

    func testAStickWholeOrByDirection() throws {
        // The left stick is W A S D by direction; whole, it is the pad's own stick (the preset has no whole action for it).
        XCTAssertFalse(ControllerMapEdit.isWhole(.leftStick, in: preset))
        let whole = ControllerMapEdit.usingWhole(.leftStick, in: preset)
        XCTAssertEqual(whole[.control(.leftStick)], .pad(.leftStick))
        XCTAssertTrue(StickDirection.allCases.allSatisfy { whole[.stickDirection(.leftStick, $0)] == nil })
        XCTAssertEqual(ControllerMapRow.leftStick.caps(in: whole), ["Pad Left stick"])
        XCTAssertTrue(ControllerMapEdit.differs(.leftStick, in: whole))
        // The right stick by direction: the arrow keys (the preset has none for it).
        let arrows = ControllerMapEdit.usingDirections(.rightStick, in: preset)
        XCTAssertNil(arrows[.control(.rightStick)])
        XCTAssertEqual(ControllerMapRow.rightStick.caps(in: arrows), ["↑", "←", "↓", "→"])
        // Back by direction: W A S D again; Y on the row restores whole and directions as the preset has them.
        XCTAssertEqual(ControllerMapEdit.usingDirections(.leftStick, in: whole), preset)
        XCTAssertEqual(ControllerMapEdit.reset(.rightStick, in: arrows), preset)
        // Binding one direction drops a whole binding; binding the whole stick drops the directions.
        let one = try XCTUnwrap(ControllerMapEdit.setting(.stickDirection(.rightStick, .up), .key(0x26, []), in: preset))
        XCTAssertNil(one[.control(.rightStick)])
        let again = try XCTUnwrap(ControllerMapEdit.setting(.control(.leftStick), .mouse(.move), in: preset))
        XCTAssertEqual(ControllerMapRow.leftStick.shown(in: again), [.control(.leftStick)])
        // An unbound stick counts as whole (its row shows one `–`).
        let none = try XCTUnwrap(ControllerMapEdit.setting(.control(.rightStick), nil, in: preset))
        XCTAssertTrue(ControllerMapEdit.isWhole(.rightStick, in: none))
        XCTAssertEqual(ControllerMapRow.rightStick.caps(in: none), ["–"])
    }

    func testAStickRowsAndTheDpadsParts() throws {
        let parts = try XCTUnwrap(ControllerMapEdit.parts(.leftStick, in: preset))
        XCTAssertEqual(parts.map(\.id), ["whole", "directions", "leftStick.up", "leftStick.left", "leftStick.down", "leftStick.right"])
        XCTAssertEqual(parts.map(\.on), [false, true, false, false, false, false])
        XCTAssertEqual(parts[2].detail, "W")
        let switched = ControllerMapEdit.choose(parts[0], of: .leftStick, in: preset)
        XCTAssertNil(switched.pick)
        XCTAssertEqual(ControllerMapEdit.parts(.leftStick, in: switched.table)?.map(\.id), ["whole", "directions", "leftStick"])
        XCTAssertEqual(ControllerMapEdit.choose(parts[3], of: .leftStick, in: preset).pick, .stickDirection(.leftStick, .left))
        XCTAssertEqual(ControllerMapEdit.parts(.dpad, in: preset)?.map(\.label), ["Up", "Right", "Down", "Left"])
        XCTAssertNil(ControllerMapEdit.parts(.a, in: preset))
        XCTAssertEqual(ControllerMapEdit.pickerTitle(.control(.a)), "What A presses")
        XCTAssertEqual(ControllerMapEdit.pickerTitle(.stickDirection(.leftStick, .up)), "What L stick up presses")
        XCTAssertEqual(ControllerMapEdit.pickerTitle(.control(.up)), "What D-pad up presses")
    }

    func testResetAllAndEditACopyAskFirstAndKeepByDefault() throws {
        let edited = try XCTUnwrap(ControllerMapEdit.setting(.control(.a), .key(0x31, []), in: preset))
        let mine = ControllerMap(mode: .custom, custom: edited)
        XCTAssertTrue(ControllerMapConfirm.needed(for: mine))
        XCTAssertFalse(ControllerMapConfirm.needed(for: ControllerMap(mode: .custom)))
        for c in [ControllerMapConfirm.resetAll, .copyPreset] {
            XCTAssertEqual(c.options.first?.id, c.defaultChoice)
            XCTAssertEqual(c.options.map(\.id), ["keep", "reset"])
        }
        // Reset all: keep changes nothing; reset is the preset, still Custom.
        XCTAssertEqual(ControllerMapConfirm.resetAll.apply("keep", to: mine), mine)
        XCTAssertEqual(ControllerMapConfirm.resetAll.apply("reset", to: mine), ControllerMap(mode: .custom))
        // Edit a copy from Keyboard & mouse: Custom with the player's table, or a fresh copy.
        let km = ControllerMap(mode: .keyboardMouse, custom: edited)
        XCTAssertEqual(ControllerMapConfirm.copyPreset.apply("keep", to: km), mine)
        XCTAssertEqual(ControllerMapConfirm.copyPreset.apply("reset", to: km), ControllerMap(mode: .custom))
    }

    func testThePressesThatRingARow() {
        XCTAssertEqual(ControllerMapRow.row(for: .lb), .lb)
        XCTAssertEqual(ControllerMapRow.row(for: .view), .back)
        XCTAssertEqual(ControllerMapRow.row(for: .menu), .start)
        // The page moves with these.
        for b in [NavButton.a, .b, .y, .up, .down, .left, .right] { XCTAssertNil(ControllerMapRow.row(for: b), b.rawValue) }
        var rest = PadInput(), p = PadInput()
        p.rightTrigger = 0.6
        XCTAssertEqual(ControllerMapRow.pressed(from: rest, to: p), .rt)
        XCTAssertNil(ControllerMapRow.pressed(from: p, to: p))          // held: once
        p = PadInput(); p.leftTrigger = 0.4
        XCTAssertNil(ControllerMapRow.pressed(from: rest, to: p))
        p = PadInput(); p.rightThumb = true
        XCTAssertEqual(ControllerMapRow.pressed(from: rest, to: p), .rs)
        p = PadInput(); p.rx = 0.4; p.ry = -0.4
        XCTAssertEqual(ControllerMapRow.pressed(from: rest, to: p), .rightStick)
        p = PadInput(); p.lx = 1                                         // the left stick moves the ring
        XCTAssertNil(ControllerMapRow.pressed(from: rest, to: p))
        rest.leftThumb = true
        p = rest
        XCTAssertNil(ControllerMapRow.pressed(from: rest, to: p))
        XCTAssertEqual(ControllerMap.Mode.allCases.map(\.title), ["As a controller", "As keyboard & mouse", "Custom"])
    }
}
