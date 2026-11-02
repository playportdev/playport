// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import HostIOKit

/// Point & click's side bar (TouchPointer.dc.html): one plate behind the column of
/// controls the tools are stacked in.
final class SideBarTests: XCTestCase {
    func rect(_ x: Double, _ y: Double, _ w: Double = 44, _ h: Double = 44) -> TouchRect { TouchRect(x: x, y: y, width: w, height: h) }

    func testThePlateHoldsTheToolsColumn() {
        let targets = [
            TouchTarget(id: "pointer", kind: .pointer(view: rect(0, 0, 874, 402)), frame: rect(62, 0, 750, 381)),
            TouchTarget(id: "mode", kind: .tool(.trackpad), frame: rect(600, 8, 210, 32)),
            TouchTarget(id: "rightClick", kind: .tool(.rightClick), frame: rect(70, 70)),
            TouchTarget(id: "hover", kind: .tool(.hover), frame: rect(70, 122)),
            TouchTarget(id: "scroll", kind: .tool(.scroll), frame: rect(70, 174)),
            TouchTarget(id: "keyboard", kind: .button(.playport(.keyboard), .hold), frame: rect(70, 226)),
            TouchTarget(id: "esc", kind: .button(.key(0x1B, []), .hold), frame: rect(70, 278)),
            // In line but apart from the column, and a button beside it: not on the plate.
            TouchTarget(id: "far", kind: .button(.key(0x20, []), .hold), frame: rect(70, 340)),
            TouchTarget(id: "beside", kind: .button(.key(0x21, []), .hold), frame: rect(122, 122)),
        ]
        XCTAssertEqual(SideBar.plates(targets), [rect(63, 62, 58, 268)])
    }

    /// The trackpad switch is no side-bar tool; a tool moved off on its own has its own plate.
    func testEachToolColumnHasOnePlate() {
        let targets = [
            TouchTarget(id: "mode", kind: .tool(.trackpad), frame: rect(600, 8, 210, 32)),
            TouchTarget(id: "hover", kind: .tool(.hover), frame: rect(70, 122)),
            TouchTarget(id: "scroll", kind: .tool(.scroll), frame: rect(300, 300)),
        ]
        XCTAssertEqual(SideBar.plates(targets), [rect(63, 114, 58, 60), rect(293, 292, 58, 60)])
        XCTAssertEqual(SideBar.plates([targets[0]]), [])
    }
}
