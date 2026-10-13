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
        XCTAssertEqual(ControllerMapRow.dpad.caps(in: preset), ["↑", "→", "↓", "←"])   // the arrow keys, clockwise from up
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

    /// Y on a game's map (the mode row, Game options' Controller row) over an edited
    /// Custom table asks first; keep changes nothing, reset follows Settings' map again.
    /// Reset all's keep changes nothing either (it does not make the map the game's own).
    func testYBackToTheDefaultAsksFirstOverAnEditedCustomTable() throws {
        let edited = try XCTUnwrap(ControllerMapEdit.setting(.control(.a), .key(0x31, []), in: preset))
        let mine = ControllerMap(mode: .custom, custom: edited)
        XCTAssertTrue(ControllerMapConfirm.neededForDefault(own: mine))
        XCTAssertFalse(ControllerMapConfirm.neededForDefault(own: nil))
        XCTAssertFalse(ControllerMapConfirm.neededForDefault(own: ControllerMap(mode: .custom)))
        XCTAssertFalse(ControllerMapConfirm.neededForDefault(own: ControllerMap(mode: .keyboardMouse, custom: edited)))
        let c = ControllerMapConfirm.useDefault
        XCTAssertEqual(c.options.map(\.id), ["keep", "reset"])
        XCTAssertEqual(c.options.first?.id, c.defaultChoice)
        XCTAssertEqual(c.options.map(\.label), ["Keep my changes", "Use Settings' map"])
        XCTAssertEqual(c.title, "Use the default controller map?")
        XCTAssertEqual(c.outcome("keep", for: mine), .unchanged)
        XCTAssertEqual(c.outcome("reset", for: mine), .useDefault)
        XCTAssertEqual(ControllerMapConfirm.resetAll.outcome("keep", for: mine), .unchanged)
        XCTAssertEqual(ControllerMapConfirm.resetAll.outcome("reset", for: mine), .save(ControllerMap(mode: .custom)))
        let km = ControllerMap(mode: .keyboardMouse, custom: edited)
        XCTAssertEqual(ControllerMapConfirm.copyPreset.outcome("keep", for: km), .save(mine))
    }

    /// The ring (touch controls U, replacing 3b's press-an-input-to-ring-its-row): down alone
    /// reaches every item in every mode, up walks back, and left and right cross the header or
    /// the columns at the same row.
    func testTheRingReachesEveryInputInEveryMode() {
        let inputs = Set(ControllerMapRow.allCases.map(\.itemID))
        for mode in ControllerMap.Mode.allCases {
            var seen: [String] = []
            var at = ControllerMapNav.next(from: nil, .up, mode: mode)
            XCTAssertEqual(at, ControllerMapNav.modeID, "the ring starts on the mode switch")
            at = ControllerMapNav.header(mode).first!
            while seen.last != at {
                seen.append(at)
                at = ControllerMapNav.next(from: at, .down, mode: mode)
            }
            XCTAssertEqual(seen, ControllerMapNav.order(mode), mode.rawValue)
            XCTAssertTrue(inputs.isSubset(of: Set(seen)), "every input in \(mode.rawValue)")
            XCTAssertEqual(seen.count, Set(seen).count)
            // Up walks back to the header's first item.
            var back = seen.last!
            for _ in seen { back = ControllerMapNav.next(from: back, .up, mode: mode) }
            XCTAssertEqual(back, seen.first)
            XCTAssertEqual(seen.contains(ControllerMapNav.lookSpeedID), mode != .controller, mode.rawValue)
        }
        // Columns down, then across: the header, LT…Menu, Look speed, RT…R3.
        XCTAssertEqual(ControllerMapNav.order(.custom),
                       ["ctl:resetAll", "ctl:mode", "ctl:lt", "ctl:lb", "ctl:leftStick", "ctl:ls", "ctl:dpad", "ctl:back", "ctl:start",
                        "ctl:lookSpeed", "ctl:rt", "ctl:rb", "ctl:y", "ctl:x", "ctl:b", "ctl:a", "ctl:rightStick", "ctl:rs"])
        XCTAssertEqual(ControllerMapNav.header(.keyboardMouse), ["ctl:copy", "ctl:mode"])
        XCTAssertEqual(ControllerMapNav.header(.controller), ["ctl:mode"])
        // Across: the same row of the other column; the header's two; the edges stay.
        XCTAssertEqual(ControllerMapNav.next(from: "ctl:lt", .right, mode: .custom), "ctl:rt")
        XCTAssertEqual(ControllerMapNav.next(from: "ctl:start", .right, mode: .custom), "ctl:rightStick")
        XCTAssertEqual(ControllerMapNav.next(from: "ctl:rs", .left, mode: .custom), "ctl:start")
        XCTAssertEqual(ControllerMapNav.next(from: "ctl:b", .left, mode: .controller), "ctl:dpad")
        XCTAssertEqual(ControllerMapNav.next(from: "ctl:lt", .left, mode: .custom), "ctl:lt")
        XCTAssertEqual(ControllerMapNav.next(from: "ctl:rt", .right, mode: .custom), "ctl:rt")
        XCTAssertEqual(ControllerMapNav.next(from: "ctl:mode", .left, mode: .keyboardMouse), "ctl:copy")
        XCTAssertEqual(ControllerMapNav.next(from: "ctl:copy", .right, mode: .keyboardMouse), "ctl:mode")
        XCTAssertEqual(ControllerMapNav.next(from: "ctl:mode", .down, mode: .controller), "ctl:lt")
        // An item of another mode's page (Reset all after a switch to Controller): the mode switch.
        XCTAssertEqual(ControllerMapNav.next(from: "ctl:resetAll", .down, mode: .controller), "ctl:mode")
        XCTAssertEqual(ControllerMapRow(itemID: "ctl:rt"), .rt)
        XCTAssertNil(ControllerMapRow(itemID: "ctl:mode"))
    }

    /// LB and RB cycle the mode from anywhere, going round; Custom keeps its table across them.
    func testLBAndRBCycleTheMode() throws {
        XCTAssertEqual(ControllerMapNav.cycle(.controller, by: 1), .keyboardMouse)
        XCTAssertEqual(ControllerMapNav.cycle(.keyboardMouse, by: 1), .custom)
        XCTAssertEqual(ControllerMapNav.cycle(.custom, by: 1), .controller)
        XCTAssertEqual(ControllerMapNav.cycle(.controller, by: -1), .custom)
        let edited = try XCTUnwrap(ControllerMapEdit.setting(.control(.b), .key(0x31, []), in: preset))
        var m = ControllerMap(mode: .custom, custom: edited)
        for _ in 0..<3 { m.mode = ControllerMapNav.cycle(m.mode, by: 1) }
        XCTAssertEqual(m, ControllerMap(mode: .custom, custom: edited))
    }

    /// A on an input: in Custom its editor at once; in Keyboard & mouse "Edit a copy?" first; in
    /// As a controller "Switch to Custom?" first. Either way the first choice changes nothing, and
    /// the other saves Custom (the input's editor then opens).
    func testAOnAnInputPerMode() throws {
        XCTAssertNil(ControllerMapConfirm.forEditing(ControllerMap(mode: .custom)))
        XCTAssertEqual(ControllerMapConfirm.forEditing(ControllerMap(mode: .keyboardMouse)), .editCopy)
        XCTAssertEqual(ControllerMapConfirm.forEditing(ControllerMap(mode: .controller)), .useCustom)
        let edited = try XCTUnwrap(ControllerMapEdit.setting(.control(.b), .key(0x31, []), in: preset))
        XCTAssertEqual(ControllerMapConfirm.forEditing(ControllerMap(mode: .keyboardMouse, custom: edited)), .copyPreset)
        XCTAssertEqual(ControllerMapConfirm.forEditing(ControllerMap(mode: .controller, custom: edited)), .useCustom)

        let km = ControllerMap(mode: .keyboardMouse)
        let copy = ControllerMapConfirm.editCopy
        XCTAssertEqual(copy.title, "Edit a copy of Keyboard & mouse?")
        XCTAssertEqual(copy.options.map(\.id), ["keep", "reset"])
        XCTAssertEqual(copy.options.first?.id, copy.defaultChoice)
        XCTAssertEqual(copy.outcome("keep", for: km), .unchanged)
        XCTAssertEqual(copy.outcome("reset", for: km), .save(ControllerMap(mode: .custom)))

        let pad = ControllerMap(mode: .controller, custom: edited)
        let custom = ControllerMapConfirm.useCustom
        XCTAssertEqual(custom.options.map(\.id), ["keep", "custom"])
        XCTAssertEqual(custom.options.first?.id, custom.defaultChoice)
        XCTAssertEqual(custom.outcome("keep", for: pad), .unchanged)
        // Its own table kept.
        XCTAssertEqual(custom.outcome("custom", for: pad), .save(ControllerMap(mode: .custom, custom: edited)))
    }

    func testTheModesTitles() {
        XCTAssertEqual(ControllerMap.Mode.allCases.map(\.title), ["As a controller", "As keyboard & mouse", "Custom"])
    }
}
