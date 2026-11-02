// SPDX-License-Identifier: GPL-3.0-or-later
import HostIOKit
import XCTest
@testable import PlayportKit

/// Phase 4's presets and control kinds (PLA-13;
/// TouchKeyboardMouse.dc.html, TouchPointer.dc.html).
final class TouchLayoutsTests: XCTestCase {
    func testThePresetsRoundTripAndAreUsable() throws {
        for l in [ControlLayout.keyboardMouse(), .pointClick()] {
            XCTAssertNil(l.problem)
            XCTAssertEqual(l.version, ControlLayout.currentVersion)
            let data = try JSONEncoder().encode(l)
            XCTAssertEqual(try JSONDecoder().decode(ControlLayout.self, from: data), l)
            XCTAssertFalse(l.controls.contains { $0.actions.contains(.playport(.menu)) })   // the menu is a three-finger tap
            XCTAssertEqual(l.controls.filter { $0.actions == [.playport(.keyboard)] }.map(\.id), ["keyboard"])
        }
        let kbm = ControlLayout.keyboardMouse()
        XCTAssertEqual(kbm.controls.map(\.id), ["look", "esc", "tab", "keyboard", "1", "2", "3", "4", "move", "use", "reload", "jump", "fire"])
        func actions(_ id: String, in l: ControlLayout) -> [InputAction]? { l.control(id)?.actions }
        XCTAssertEqual(actions("move", in: kbm), [.key(0x57, []), .key(0x53, []), .key(0x41, []), .key(0x44, [])])
        XCTAssertEqual(kbm.control("move")?.kind, .stick)
        XCTAssertNotNil(kbm.control("move")?.floatingZone)
        XCTAssertEqual(kbm.control("look")?.kind, .lookArea)
        XCTAssertEqual(actions("look", in: kbm), [.mouse(.move)])
        XCTAssertEqual(actions("fire", in: kbm), [.mouse(.left)])
        XCTAssertEqual(actions("jump", in: kbm), [.key(0x20, [])])
        XCTAssertEqual(actions("reload", in: kbm), [.key(0x52, [])])
        XCTAssertEqual(actions("use", in: kbm), [.key(0x45, [])])
        XCTAssertEqual(actions("esc", in: kbm), [.key(0x1B, [])])
        XCTAssertEqual(actions("tab", in: kbm), [.key(0x09, [])])
        XCTAssertEqual(["1", "2", "3", "4"].compactMap { actions($0, in: kbm) }, [[.key(0x31, [])], [.key(0x32, [])], [.key(0x33, [])], [.key(0x34, [])]])
        XCTAssertFalse(kbm.controls.contains { $0.actions.contains(.mouse(.right)) })   // no Aim: gyro aims by itself

        let pc = ControlLayout.pointClick()
        XCTAssertEqual(pc.controls.map(\.id), ["pointer", "mode", "rightClick", "hover", "scroll", "keyboard", "esc"])
        XCTAssertEqual(pc.control("pointer")?.kind, .pointer)
        XCTAssertEqual(actions("pointer", in: pc), [.mouse(.left)])
        XCTAssertEqual(["mode", "rightClick", "hover", "scroll"].map { pc.control($0)?.tool }, [.trackpad, .rightClick, .hover, .scroll])
        XCTAssertEqual(actions("esc", in: pc), [.key(0x1B, [])])

        XCTAssertEqual(OnScreenLayout.allCases, [.off, .gamepad, .keyboardMouse, .pointClick])
        XCTAssertEqual(OnScreenLayout.keyboardMouse.title, "Keyboard & mouse")
        XCTAssertEqual(OnScreenLayout.pointClick.title, "Point & click")
        XCTAssertEqual(OnScreenLayout.keyboardMouse.layout(dpad: .on, rightStick: .below), kbm)   // the Gamepad options do not apply
        XCTAssertEqual(OnScreenLayout.pointClick.layout(dpad: .on, rightStick: .below), pc)
        XCTAssertEqual(try JSONDecoder().decode(GameControls.self, from: Data(#"{"layout":"pointClick"}"#.utf8)).layout, .pointClick)
    }

    /// On every iPhone: the surfaces fill the safe area, every other control is inside it, none overlap,
    /// and the WASD zone keeps its gap to them.
    func testThePresetsFitEveryScreen() {
        func inside(_ r: TouchRect, _ a: TouchRect) -> Bool {
            r.x >= a.x - 1e-9 && r.y >= a.y - 1e-9 && r.x + r.width <= a.x + a.width + 1e-9 && r.y + r.height <= a.y + a.height + 1e-9
        }
        for s in ControlLayoutTests.screens {
            for (name, layout) in [("Keyboard & mouse", ControlLayout.keyboardMouse()), ("Point & click", .pointClick())] {
                let what = "\(name), \(s.name)"
                let area = s.insets.area(width: s.width, height: s.height)
                let targets = layout.targets(width: s.width, height: s.height, insets: s.insets)
                var zones: [TouchRect] = [], fixed: [TouchTarget] = []
                for t in targets {
                    switch t.kind {
                    case .look:
                        XCTAssertEqual(t.frame, area, what)
                    case .pointer(let view):
                        XCTAssertEqual(t.frame, area, what)
                        XCTAssertEqual(view, TouchRect(x: 0, y: 0, width: s.width, height: s.height), what)
                    case .keyStick(_, let zone?):
                        XCTAssertTrue(inside(zone, area), "\(what): \(t.id)'s zone")
                        XCTAssertTrue(zone.contains(t.frame.center), "\(what): \(t.id) rests in its zone")
                        zones.append(zone)
                    default:
                        XCTAssertTrue(inside(t.frame, area), "\(what): \(t.id) \(t.frame) is outside \(area)")
                        fixed.append(t)
                    }
                }
                for (i, t) in fixed.enumerated() {
                    for z in zones { XCTAssertGreaterThanOrEqual(ControlLayoutTests.gap(t.frame, z), 12, "\(what): \(t.id) is near the zone") }
                    for u in fixed[(i + 1)...] { XCTAssertFalse(ControlLayoutTests.overlap(t.frame, u.frame), "\(what): \(t.id) and \(u.id) overlap") }
                }
            }
        }
    }

    /// The Keyboard & mouse layout played through TouchControls: WASD in its zone, the look area anywhere
    /// free, Fire on its button; Point & click's tools over its surface.
    func testThePresetsPlayThroughTheTouchMachines() {
        let insets = ControlInsets(left: 62, bottom: 21, right: 62)
        let targets = ControlLayout.keyboardMouse().targets(width: 874, height: 402, insets: insets)
        var t = TouchControls(targets: targets)
        func owner(_ x: Double, _ y: Double) -> String? { t.target(at: TouchPoint(x: x, y: y)).map { targets[$0].id } }
        XCTAssertEqual(owner(100, 350), "move")
        XCTAssertEqual(owner(437, 200), "look")
        XCTAssertNil(owner(30, 200))   // under the island
        let fire = targets.first { $0.id == "fire" }!.frame.center
        XCTAssertEqual(owner(fire.x, fire.y), "fire")
        XCTAssertTrue(t.began(1, at: TouchPoint(x: 150, y: 330), time: 0))
        t.moved(1, at: TouchPoint(x: 150, y: 270), time: 0.1)
        XCTAssertTrue(t.began(2, at: TouchPoint(x: 437, y: 200), time: 0))
        t.moved(2, at: TouchPoint(x: 447, y: 200), time: 0.1)
        XCTAssertTrue(t.began(3, at: fire, time: 0.1))
        let out = t.takeOutput()
        XCTAssertEqual(out.keys, [.key(0x57, [])])
        XCTAssertEqual(out.mouse, [.left])
        XCTAssertEqual(out.events, [.move(dx: 30, dy: 0)])

        let pc = ControlLayout.pointClick().targets(width: 874, height: 402, insets: insets)
        var u = TouchControls(targets: pc)
        let hover = pc.first { $0.id == "hover" }!.frame.center
        XCTAssertTrue(u.began(1, at: hover, time: 0))
        u.ended(1, time: 0.05)
        XCTAssertEqual(u.tool, .hover)
        XCTAssertEqual(u.held, ["hover"])
        XCTAssertEqual(pc[u.target(at: TouchPoint(x: 437, y: 201))!].id, "pointer")
    }

    func testTheNewKindsAreCheckedAsTheyAreRead() {
        func decode(_ controls: String, version: Int = ControlLayout.currentVersion) -> ControlLayout? {
            try? JSONDecoder().decode(ControlLayout.self, from: Data(#"{"version":\#(version),"controls":[\#(controls)]}"#.utf8))
        }
        let place = #""anchor":"center","x":0,"y":0,"width":50,"height":50"#
        XCTAssertEqual(decode(#"{"id":"l","kind":"lookArea","actions":["mouse:move"],\#(place)}"#)?.controls.first?.kind, .lookArea)
        XCTAssertEqual(decode(#"{"id":"p","kind":"pointer","actions":["mouse:left"],\#(place)}"#)?.controls.first?.kind, .pointer)
        XCTAssertEqual(decode(#"{"id":"t","kind":"tool","tool":"hover","actions":[],\#(place)}"#)?.controls.first?.tool, .hover)
        XCTAssertEqual(decode(#"{"id":"w","kind":"stick","actions":["key:0x57","key:0x53","key:0x41","key:0x44"],\#(place)}"#)?
            .controls.first?.actions.count, 4)
        XCTAssertNil(decode(#"{"id":"l","kind":"lookArea","actions":["mouse:left"],\#(place)}"#))
        XCTAssertNil(decode(#"{"id":"p","kind":"pointer","actions":["mouse:move"],\#(place)}"#))
        XCTAssertNil(decode(#"{"id":"t","kind":"tool","actions":[],\#(place)}"#))                    // which tool
        XCTAssertNil(decode(#"{"id":"t","kind":"tool","tool":"scroll","actions":["key:0x20"],\#(place)}"#))
        XCTAssertNil(decode(#"{"id":"b","tool":"scroll","actions":["key:0x20"],\#(place)}"#))         // a tool on a button
        XCTAssertNil(decode(#"{"id":"t","kind":"tool","tool":"zoom","actions":[],\#(place)}"#))
        XCTAssertNil(decode(#"{"id":"w","kind":"stick","actions":["pad:leftStick","key:0x53","key:0x41","key:0x44"],\#(place)}"#))
        XCTAssertNil(decode(#"{"id":"w","kind":"stick","actions":["key:0x57","key:0x53"],\#(place)}"#))
        // The format grew: a version 2 layout is refused, so the preset is used.
        XCTAssertNil(decode(#"{"id":"j","actions":["key:0x20"],\#(place)}"#, version: 2))
    }

    /// A surface's size larger than the safe area is cut to it (any control's is).
    func testAControlLargerThanTheSafeAreaIsCutToIt() {
        let c = Control(id: "look", kind: .lookArea, actions: [.mouse(.move)], label: "Look", anchor: .center, x: 0, y: 0,
                        width: 4000, height: 4000)
        let insets = ControlInsets(left: 62, bottom: 21, right: 62)
        XCTAssertEqual(c.frame(width: 874, height: 402, insets: insets), TouchRect(x: 62, y: 0, width: 750, height: 381))
    }
}
