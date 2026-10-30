// SPDX-License-Identifier: GPL-3.0-or-later
import HostIOKit
import XCTest
@testable import PlayportKit

/// The note Point & click shows as a side-bar tool or the trackpad switch is pressed (TouchPointer.dc.html).
final class PointerHintTests: XCTestCase {
    func testATurnedOnToolSaysWhatTheFingerDoesNow() {
        XCTAssertEqual(PointerHint.text(from: (nil, false), to: (.hover, false)),
                       "Hover is on: your finger moves the pointer without clicking")
        XCTAssertEqual(PointerHint.text(from: (.hover, false), to: (.rightClick, false)),
                       "Right click is on: your next tap right-clicks")
        XCTAssertEqual(PointerHint.text(from: (nil, true), to: (.scroll, true)), "Scroll is on: drag to scroll")
        XCTAssertEqual(PointerHint.text(from: (nil, false), to: (nil, true)), "Trackpad: drag to move the pointer, tap to click")
        XCTAssertEqual(PointerHint.text(from: (.hover, true), to: (.hover, false)), "Tap to click: the pointer goes where you touch")
    }

    /// A tool turned off, or nothing changed: no note.
    func testOffSaysNothing() {
        XCTAssertNil(PointerHint.text(from: (.hover, false), to: (nil, false)))
        XCTAssertNil(PointerHint.text(from: (nil, false), to: (nil, false)))
    }
}
