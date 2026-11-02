// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import HostIOKit

/// The text bar over a running game (PLA-267; PLA-616, "Signing in on
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

    /// The field holds only what the guest's field got: a dropped control character is not in
    /// it, so deleting it takes back nothing the guest has.
    func testADroppedControlIsNotInTheFieldAndTakesNothingBack() {
        var bar = TextBar()
        XCTAssertEqual(bar.change(to: "a\u{7}"), [.char(0x61)])
        XCTAssertEqual(bar.text, "a")
        XCTAssertEqual(bar.change(to: "a"), [])
        XCTAssertEqual(bar.change(to: ""), [backspace])
    }

    /// A pasted Tab or line break moves on in the guest as the bar's own keys do: the field then
    /// holds what follows the last of them, and Backspace takes back only that.
    func testAPastedTabOrLineBreakStartsTheFieldAgain() {
        var bar = TextBar()
        XCTAssertEqual(bar.change(to: "name\tpw"), chars("name") + [tab] + chars("pw"))
        XCTAssertEqual(bar.text, "pw")
        XCTAssertEqual(bar.change(to: "p"), [backspace])
        XCTAssertEqual(bar.change(to: "p\r\n"), [enter])
        XCTAssertEqual(bar.text, "")
        XCTAssertEqual(bar.change(to: ""), [])
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

    func testEnterAfterAPasswordIsItsOwnBatchAfterTheCharacters() {
        var bar = TextBar(secure: true)
        let typed = bar.type("Test-Pass_123!")
        let all = typed + bar.press(.enter)
        XCTAssertEqual(TextBarPacing.batches(all), [typed, [enter]])
    }

    func testCharactersAfterAKeyWaitForIt() {
        var bar = TextBar()
        let sent = bar.change(to: "name\tpw\r\nx")
        XCTAssertEqual(TextBarPacing.batches(sent),
                       [chars("name"), [tab], chars("pw"), [enter], chars("x")])
        // An edit's Backspaces are one batch, before the characters that replace them.
        XCTAssertEqual(TextBarPacing.batches(bar.change(to: "y")), [[backspace], chars("y")])
    }

    func testLongTextGoesInBatchesTheRingHolds() {
        let long = chars(String(repeating: "a", count: 150))
        let batches = TextBarPacing.batches(long)
        XCTAssertEqual(batches.map(\.count), [64, 64, 22])
        XCTAssertEqual(Array(batches.joined()), long)
        XCTAssertTrue(batches.allSatisfy { $0.count * 2 <= TextBarPacing.room })
        XCTAssertEqual(TextBarPacing.batches([]), [])
    }
}
