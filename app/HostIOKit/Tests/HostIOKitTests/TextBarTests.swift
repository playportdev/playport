// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import HostIOKit

/// The text bar over a running game (PLA-267; docs/plans/2026-10-12-launchers.md, "Signing in on
/// the phone"): what its field's edits send to the focused guest window.
final class TextBarTests: XCTestCase {
    let backspace = TextBar.Input.key(0x08), tab = TextBar.Input.key(0x09), enter = TextBar.Input.key(0x0D)

    func chars(_ s: String) -> [TextBar.Input] { s.utf16.map { .char($0) } }

    func testTypingSendsEachNewCharacter() {
        var bar = TextBar()
        XCTAssertEqual(bar.change(to: "a"), [.char(0x61)])
        XCTAssertEqual(bar.change(to: "ab"), [.char(0x62)])
        XCTAssertEqual(bar.text, "ab")
    }

    func testAutoFillOrAPasteSendsTheWholeValueInOrder() {
        var bar = TextBar(secure: true)
        XCTAssertEqual(bar.change(to: "p@ss wörd€"),
                       [0x70, 0x40, 0x73, 0x73, 0x20, 0x77, 0xF6, 0x72, 0x64, 0x20AC].map { .char($0) })
    }

    func testAnEditSendsBackspacesToWhereItDiffersThenTheRest() {
        var bar = TextBar()
        _ = bar.change(to: "abc")
        XCTAssertEqual(bar.change(to: "abd"), [backspace, .char(0x64)])
        XCTAssertEqual(bar.change(to: "a"), [backspace, backspace])
        XCTAssertEqual(bar.change(to: ""), [backspace])
    }

    func testACharacterBeyondTheBMPIsTwoUnitsAndOneBackspace() {
        var bar = TextBar()
        XCTAssertEqual(bar.change(to: "😀"), [.char(0xD83D), .char(0xDE00)])
        XCTAssertEqual(bar.change(to: ""), [backspace])
    }

    func testEnterAndTabReachTheGuestAndStartTheFieldEmpty() {
        var bar = TextBar()
        _ = bar.change(to: "name")
        XCTAssertEqual(bar.press(.tab), [tab])
        XCTAssertEqual(bar.text, "")
        XCTAssertEqual(bar.change(to: "x"), [.char(0x78)])
        XCTAssertEqual(bar.press(.enter), [enter])
        XCTAssertEqual(bar.text, "")
    }

    func testBackspaceOnAnEmptyFieldStillReachesTheGuest() {
        var bar = TextBar()
        XCTAssertEqual(bar.press(.backspace), [backspace])
        _ = bar.change(to: "ab")
        XCTAssertEqual(bar.press(.backspace), [backspace])
        XCTAssertEqual(bar.text, "a")
    }

    func testTabsAndLineBreaksInAPasteAreTheirKeysAndOtherControlsAreDropped() {
        var bar = TextBar()
        XCTAssertEqual(bar.change(to: "a\tb\r\nc\u{7}"), [.char(0x61), tab, .char(0x62), enter, .char(0x63)])
    }

    func testTypeAppendsAsTypingWould() {
        var bar = TextBar()
        _ = bar.change(to: "user")
        XCTAssertEqual(bar.type("@x.y"), chars("@x.y"))
        XCTAssertEqual(bar.text, "user@x.y")
    }

    func testTheSummaryNeverHoldsTheTextNorItsLength() {
        for secure in [false, true] {
            var bar = TextBar(secure: secure)
            _ = bar.change(to: "hunter2")
            XCTAssertFalse(bar.summary.contains("hunter2"))
            XCTAssertFalse(bar.summary.contains("7"))
            XCTAssertTrue(bar.summary.contains(secure ? "secret" : "plain"), bar.summary)
        }
    }
}
