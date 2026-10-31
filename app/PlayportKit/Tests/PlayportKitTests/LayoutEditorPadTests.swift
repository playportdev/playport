// SPDX-License-Identifier: GPL-3.0-or-later
import HostIOKit
import XCTest
@testable import PlayportKit

/// The layout editor by controller (LayoutEditor.dc.html; PlayportKit LayoutEditorPad):
/// the ringed control on the canvas, the bar and the inspector behind A, B back.
final class LayoutEditorPadTests: XCTestCase {
    let a = Control(id: "a", actions: [.key(0x41, [])], label: "A", anchor: .topLeading, x: 40, y: 40, width: 48, height: 48)
    let b = Control(id: "b", actions: [.key(0x42, [])], label: "B", anchor: .topLeading, x: 200, y: 200, width: 48, height: 48)

    func editor() -> LayoutEditor {
        LayoutEditor(preset: .keyboardMouse, copies: [.keyboardMouse: ControlLayout(controls: [a, b])], width: 800, height: 400)
    }

    func testLBAndRBRingTheControlsInTurnAndGoRound() {
        var e = editor(), pad = LayoutEditorPad()
        XCTAssertEqual(pad.press(.rb, editor: &e), LayoutEditorPadEffect.none)
        XCTAssertEqual(e.selection, "a")                     // nothing ringed yet: the first
        _ = pad.press(.rb, editor: &e)
        XCTAssertEqual(e.selection, "b")
        _ = pad.press(.rb, editor: &e)
        XCTAssertEqual(e.selection, "a")                     // round to the first
        _ = pad.press(.lb, editor: &e)
        XCTAssertEqual(e.selection, "b")
        var fresh = editor()
        _ = pad.press(.lb, editor: &fresh)
        XCTAssertEqual(fresh.selection, "b")                 // nothing ringed: LB the last
        XCTAssertFalse(e.canUndo)                            // ringing changes nothing
    }

    func testTheDirectionsMoveTheRingedControlAGridStepEachAsOneUndoStep() throws {
        var e = editor(), pad = LayoutEditorPad()
        // Nothing ringed: a direction rings the first control and moves nothing.
        _ = pad.press(.right, editor: &e)
        XCTAssertEqual(e.selection, "a")
        XCTAssertEqual(e.frame(of: "a"), TouchRect(x: 16, y: 16, width: 48, height: 48))
        _ = pad.press(.right, editor: &e)
        XCTAssertEqual(e.frame(of: "a"), TouchRect(x: 24, y: 16, width: 48, height: 48))
        _ = pad.press(.down, editor: &e)
        _ = pad.press(.down, editor: &e)
        XCTAssertEqual(e.frame(of: "a"), TouchRect(x: 24, y: 32, width: 48, height: 48))
        _ = pad.press(.left, editor: &e)
        _ = pad.press(.up, editor: &e)
        XCTAssertEqual(e.frame(of: "a"), TouchRect(x: 16, y: 24, width: 48, height: 48))
        XCTAssertEqual(e.guides, [])                         // each press is a whole gesture
        e.undo()
        XCTAssertEqual(e.frame(of: "a"), TouchRect(x: 16, y: 32, width: 48, height: 48))
        // At the safe area's edge it stays.
        var edge = editor()
        edge.select("a")
        for _ in 0..<5 { _ = pad.press(.up, editor: &edge) }
        XCTAssertEqual(edge.frame(of: "a")?.y, 0)
    }

    func testAOpensThePanelWhereTheDirectionsAndAAreTheRingsAndBComesBack() {
        var e = editor(), pad = LayoutEditorPad()
        XCTAssertEqual(pad.press(.a, editor: &e), LayoutEditorPadEffect.none)
        XCTAssertEqual(e.selection, "a")                     // nothing ringed: A rings the first
        XCTAssertEqual(pad.focus, .canvas)
        XCTAssertEqual(pad.press(.a, editor: &e), .openPanel)
        XCTAssertEqual(pad.focus, .panel)
        XCTAssertEqual(pad.press(.down, editor: &e), .moveRing(.down))
        XCTAssertEqual(pad.press(.a, editor: &e), .activate)
        XCTAssertEqual(e.frame(of: "a"), TouchRect(x: 16, y: 16, width: 48, height: 48))   // nothing moved
        // LB and RB still ring another control from the panel, which stays.
        _ = pad.press(.rb, editor: &e)
        XCTAssertEqual(e.selection, "b")
        XCTAssertEqual(pad.focus, .panel)
        XCTAssertEqual(pad.press(.b, editor: &e), LayoutEditorPadEffect.none)
        XCTAssertEqual(pad.focus, .canvas)
        XCTAssertEqual(pad.press(.b, editor: &e), .done)     // B on the canvas: Done
    }

    func testYResetsXAddsAndViewAndMenuUndoAndRedo() {
        var e = editor(), pad = LayoutEditorPad()
        e.select("b")
        let before = e.layout
        _ = pad.press(.right, editor: &e)
        let moved = e.layout
        XCTAssertNotEqual(moved, before)
        _ = pad.press(.view, editor: &e)
        XCTAssertEqual(e.layout, before)
        _ = pad.press(.menu, editor: &e)
        XCTAssertEqual(e.layout, moved)
        XCTAssertEqual(pad.press(.x, editor: &e), .add)
        _ = pad.press(.y, editor: &e)
        XCTAssertEqual(e.layout, ControlLayout.keyboardMouse())   // the bare preset
        XCTAssertTrue(e.canUndo)
        // From the panel too.
        pad.focus = .panel
        XCTAssertEqual(pad.press(.x, editor: &e), .add)
        _ = pad.press(.view, editor: &e)
        XCTAssertEqual(e.layout.controls.map(\.id), ["a", "b"])
    }

    func testAHandleResizesByItsDistanceFromTheCentre() {
        let c = TouchPoint(x: 100, y: 100)
        XCTAssertEqual(LayoutEditorPad.handleScale(centre: c, from: TouchPoint(x: 130, y: 140), to: TouchPoint(x: 160, y: 180)), 2)
        XCTAssertEqual(LayoutEditorPad.handleScale(centre: c, from: TouchPoint(x: 130, y: 140), to: TouchPoint(x: 115, y: 120)), 0.5)
        // A grab on the centre itself scales nothing.
        XCTAssertEqual(LayoutEditorPad.handleScale(centre: c, from: c, to: TouchPoint(x: 160, y: 180)), 1)
    }
}
