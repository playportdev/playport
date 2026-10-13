// SPDX-License-Identifier: GPL-3.0-or-later
import HostIOKit
import XCTest
@testable import PlayportKit

final class ControlLayoutTests: XCTestCase {
    func testTheGamepadPresetRoundTripsAndIsUsable() throws {
        let g = ControlLayout.gamepad
        XCTAssertNil(g.problem)
        XCTAssertEqual(g.version, 2)
        let data = try JSONEncoder().encode(g)
        XCTAssertEqual(try JSONDecoder().decode(ControlLayout.self, from: data), g)
        XCTAssertEqual(g.controls.map(\.id), ["view", "menu", "lt", "lb", "rt", "rb", "dpad",
                                              "leftStick", "rightStick", "y", "x", "b", "a"])
        XCTAssertFalse(g.controls.contains { $0.actions.contains(.playport(.menu)) })   // the menu is a three-finger tap
    }

    /// Anchor + offset + size, placed in the safe area: the anchor is the safe
    /// area's corner, and a control that would reach outside it is moved back in.
    func testAControlIsPlacedInTheSafeArea() {
        let c = Control(id: "a", actions: [.pad(.a)], label: "A", anchor: .bottomTrailing, x: -40, y: -30, width: 50, height: 40)
        XCTAssertEqual(c.frame(width: 874, height: 402), TouchRect(x: 809, y: 352, width: 50, height: 40))
        // The Dynamic Island on the left: only the right edge and the home indicator move it.
        let left = ControlInsets(left: 62, bottom: 21, right: 0)
        XCTAssertEqual(c.frame(width: 874, height: 402, insets: left), TouchRect(x: 809, y: 331, width: 50, height: 40))
        // Rotated: the island on the right.
        let right = ControlInsets(left: 0, bottom: 21, right: 62)
        XCTAssertEqual(c.frame(width: 874, height: 402, insets: right), TouchRect(x: 747, y: 331, width: 50, height: 40))
        // An offset that would leave the safe area is kept in it.
        let out = Control(id: "o", actions: [.pad(.b)], label: "B", anchor: .topLeading, x: 0, y: 0, width: 50, height: 40)
        XCTAssertEqual(out.frame(width: 874, height: 402, insets: ControlInsets(top: 10, left: 62)),
                       TouchRect(x: 62, y: 10, width: 50, height: 40))
        let centre = Control(id: "c", actions: [.pad(.x)], label: "X", anchor: .center, x: 0, y: 0, width: 100, height: 20)
        XCTAssertEqual(centre.frame(width: 874, height: 402, insets: left), TouchRect(x: 418, y: 180.5, width: 100, height: 20))
        // A zone is its corner of the safe area, cut to it.
        let area = left.area(width: 874, height: 402)
        XCTAssertEqual(area, TouchRect(x: 62, y: 0, width: 812, height: 381))
        XCTAssertEqual(ControlZone(anchor: .bottomLeading, width: 210, height: 150).frame(in: area),
                       TouchRect(x: 62, y: 231, width: 210, height: 150))
        XCTAssertEqual(ControlZone(anchor: .bottomTrailing, width: 1000, height: 150).frame(in: area),
                       TouchRect(x: 62, y: 231, width: 812, height: 150))
    }

    /// The screens the preset must fit (landscape points, safe-area insets with the
    /// island or notch on either side): every control and zone inside the safe area,
    /// no two controls overlapping, and a clear gap between every fixed control and
    /// either floating stick's zone, so no touch there is the other's.
    static let screens: [(name: String, width: Double, height: Double, insets: ControlInsets)] = [
        ("4.7-inch", 667, 375, ControlInsets()),
        ("5.4-inch notch left", 812, 375, ControlInsets(left: 50, bottom: 21, right: 50)),
        ("6.3-inch island", 874, 402, ControlInsets(left: 62, bottom: 21, right: 62)),
        ("6.1-inch notch", 844, 390, ControlInsets(left: 47, bottom: 21, right: 47)),
        ("6.9-inch island", 956, 440, ControlInsets(left: 62, bottom: 21, right: 62)),
        ("left inset only", 874, 402, ControlInsets(left: 62, bottom: 21, right: 0)),
        ("right inset only", 874, 402, ControlInsets(left: 0, bottom: 21, right: 62)),
    ]

    func testThePresetFitsEveryScreenWithZonesClearOfTheControls() {
        func inside(_ r: TouchRect, _ a: TouchRect) -> Bool {
            r.x >= a.x - 1e-9 && r.y >= a.y - 1e-9 && r.x + r.width <= a.x + a.width + 1e-9 && r.y + r.height <= a.y + a.height + 1e-9
        }
        func overlap(_ a: TouchRect, _ b: TouchRect) -> Bool {
            a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
        }
        func gap(_ a: TouchRect, _ b: TouchRect) -> Double {
            let dx = max(b.x - (a.x + a.width), a.x - (b.x + b.width), 0)
            let dy = max(b.y - (a.y + a.height), a.y - (b.y + b.height), 0)
            return max(dx, dy)
        }
        for s in Self.screens {
            let area = s.insets.area(width: s.width, height: s.height)
            let targets = ControlLayout.gamepad.targets(width: s.width, height: s.height, insets: s.insets)
            var zones: [TouchRect] = []
            var fixed: [TouchTarget] = []
            for t in targets {
                XCTAssertTrue(inside(t.frame, area), "\(s.name): \(t.id) \(t.frame) is outside \(area)")
                if case .stick(_, let zone?) = t.kind {
                    XCTAssertTrue(inside(zone, area), "\(s.name): \(t.id)'s zone")
                    XCTAssertTrue(zone.contains(t.frame.center), "\(s.name): \(t.id) rests in its zone")   // where touch: lands
                    zones.append(zone)
                } else {
                    fixed.append(t)
                }
            }
            XCTAssertEqual(zones.count, 2, s.name)
            XCTAssertGreaterThanOrEqual(gap(zones[0], zones[1]), 12, "\(s.name): the zones")
            for (i, t) in fixed.enumerated() {
                for z in zones { XCTAssertGreaterThanOrEqual(gap(t.frame, z), 12, "\(s.name): \(t.id) is near a zone") }
                for u in fixed[(i + 1)...] { XCTAssertFalse(overlap(t.frame, u.frame), "\(s.name): \(t.id) and \(u.id) overlap") }
            }
        }
    }

    /// The left zone is the lower left corner, the right zone mirrors it, and the
    /// d-pad and A B X Y are above and inward of them.
    func testTheZonesAreMirroredAndTheirOwnersHitThere() {
        let insets = ControlInsets(left: 62, bottom: 21, right: 62)
        let targets = ControlLayout.gamepad.targets(width: 874, height: 402, insets: insets)
        func target(_ id: String) -> TouchTarget { targets.first { $0.id == id }! }
        guard case .stick(.leftStick, let lz?) = target("leftStick").kind,
              case .stick(.rightStick, let rz?) = target("rightStick").kind else { return XCTFail("both sticks float") }
        XCTAssertEqual(lz, TouchRect(x: 62, y: 241, width: 210, height: 140))
        XCTAssertEqual(rz, TouchRect(x: 602, y: 241, width: 210, height: 140))
        XCTAssertEqual(target("dpad").frame, TouchRect(x: 158, y: 113, width: 116, height: 116))
        XCTAssertEqual(target("a").frame.center, TouchPoint(x: 656, y: 203))
        XCTAssertEqual(target("y").frame.center, TouchPoint(x: 656, y: 99))
        XCTAssertEqual(target("x").frame.center, TouchPoint(x: 604, y: 151))
        XCTAssertEqual(target("b").frame.center, TouchPoint(x: 708, y: 151))
        XCTAssertEqual(target("lt").frame, TouchRect(x: 68, y: 4, width: 64, height: 40))
        XCTAssertEqual(target("view").frame, TouchRect(x: 138, y: 7, width: 44, height: 30))
        XCTAssertEqual(target("menu").frame, TouchRect(x: 692, y: 7, width: 44, height: 30))

        var t = TouchControls(targets: targets)
        func owner(_ x: Double, _ y: Double) -> String? { t.target(at: TouchPoint(x: x, y: y)).map { targets[$0].id } }
        // Each zone is its stick's, edge to edge.
        XCTAssertEqual(owner(63, 380), "leftStick")
        XCTAssertEqual(owner(271, 242), "leftStick")
        XCTAssertEqual(owner(811, 380), "rightStick")
        XCTAssertEqual(owner(603, 242), "rightStick")
        // The d-pad's and A's edges nearest the zones are theirs, not a stick's.
        XCTAssertEqual(owner(216, 228), "dpad")
        XCTAssertEqual(owner(656, 228), "a")
        // Between them, and the middle, are the game's.
        XCTAssertNil(owner(216, 235))
        XCTAssertNil(owner(437, 300))
        XCTAssertNil(owner(437, 30))
        // Out of the safe area (under the island) is the game's.
        XCTAssertNil(owner(30, 380))
        // A face button and the d-pad with both sticks, all at once.
        XCTAssertTrue(t.began(1, at: TouchPoint(x: 656, y: 203), time: 0))
        XCTAssertTrue(t.began(2, at: TouchPoint(x: 216, y: 130), time: 0))
        XCTAssertTrue(t.began(3, at: TouchPoint(x: 150, y: 320), time: 0))
        XCTAssertTrue(t.began(4, at: TouchPoint(x: 700, y: 320), time: 0))
        t.moved(3, at: TouchPoint(x: 150, y: 268), time: 0.05)
        t.moved(4, at: TouchPoint(x: 648, y: 320), time: 0.05)
        let pad = t.output.pad
        XCTAssertTrue(pad.a)
        XCTAssertTrue(pad.up)
        XCTAssertEqual(pad.ly, 1, accuracy: 0.001)
        XCTAssertEqual(pad.rx, -1, accuracy: 0.001)
        XCTAssertEqual(t.held, ["a", "dpad", "leftStick", "rightStick"])
    }

    func testANewerOlderOrBrokenLayoutIsRefused() {
        func decode(_ s: String) -> ControlLayout? { try? JSONDecoder().decode(ControlLayout.self, from: Data(s.utf8)) }
        let button = #"{"id":"jump","actions":["key:0x20"],"anchor":"bottomTrailing","x":-60,"y":-60,"width":50,"height":50}"#
        let ok = decode(#"{"version":2,"controls":[\#(button)]}"#)
        XCTAssertEqual(ok?.controls.first?.label, "jump")          // label and behaviour may be left out
        XCTAssertEqual(ok?.controls.first?.behaviour, .hold)
        XCTAssertEqual(ok?.controls.first?.kind, .button)
        let stick = #"{"id":"s","kind":"stick","actions":["pad:leftStick"],"anchor":"bottomLeading","x":100,"y":-80,"width":100,"height":100"#
        XCTAssertEqual(decode(#"{"version":2,"controls":[\#(stick),"floatingZone":{"anchor":"bottomLeading","width":200,"height":150}}]}"#)?
            .controls.first?.floatingZone, ControlZone(anchor: .bottomLeading, width: 200, height: 150))
        // Version 1 (before the safe area; zones as fractions of the view): refused, so the preset is used.
        XCTAssertNil(decode(#"{"version":1,"controls":[\#(button)]}"#))
        XCTAssertNil(decode(#"{"version":2,"controls":[\#(stick),"floatingZone":{"x":0,"y":0.33,"width":0.33,"height":0.67}}]}"#))
        XCTAssertNil(decode(#"{"version":2,"controls":[\#(stick),"floatingZone":{"anchor":"bottomLeading","width":0,"height":150}}]}"#))
        XCTAssertNil(decode(#"{"version":3,"controls":[\#(button)]}"#))
        XCTAssertNil(decode(#"{"controls":[\#(button)]}"#))
        XCTAssertNil(decode(#"{"version":2,"controls":[\#(button),\#(button)]}"#))   // one id twice
        XCTAssertNil(decode(#"{"version":2,"controls":[{"id":"s","kind":"stick","actions":["pad:a"],"anchor":"center","x":0,"y":0,"width":50,"height":50}]}"#))
        XCTAssertNil(decode(#"{"version":2,"controls":[{"id":"d","kind":"dpad","actions":["pad:up"],"anchor":"center","x":0,"y":0,"width":50,"height":50}]}"#))
        XCTAssertNil(decode(#"{"version":2,"controls":[{"id":"z","actions":["pad:a"],"anchor":"center","x":0,"y":0,"width":0,"height":50}]}"#))
        XCTAssertNil(decode(#"{"version":2,"controls":[{"id":"a b","actions":["pad:a"],"anchor":"center","x":0,"y":0,"width":5,"height":50}]}"#))
    }
}

final class ControlsSettingsTests: XCTestCase {
    func testAutomaticHidesTheControlsWhileAControllerIsConnected() {
        let d = ControlsDefaults()
        XCTAssertEqual(ControlsState.resolve(game: nil, defaults: d, controllerConnected: false),
                       ControlsState(layout: .gamepad, visible: true, opacity: 0.6))
        let hidden = ControlsState.resolve(game: nil, defaults: d, controllerConnected: true)
        XCTAssertFalse(hidden.visible)
        XCTAssertNil(hidden.drawnLayout)   // Home opens the menu then
        XCTAssertTrue(ControlsState.resolve(game: nil, defaults: ControlsDefaults(show: .always), controllerConnected: true).visible)
    }

    func testNeverIsOffByDefaultAndAGameCanStillChooseGamepad() {
        let never = ControlsDefaults(show: .never)
        XCTAssertEqual(ControlsState.resolve(game: nil, defaults: never, controllerConnected: false).layout, .off)
        XCTAssertFalse(ControlsState.resolve(game: nil, defaults: never, controllerConnected: false).visible)
        let mine = GameControls(layout: .gamepad, opacity: 0.9)
        XCTAssertEqual(ControlsState.resolve(game: mine, defaults: never, controllerConnected: false),
                       ControlsState(layout: .gamepad, visible: true, opacity: 0.9))
        let off = ControlsState.resolve(game: GameControls(layout: .off), defaults: ControlsDefaults(show: .always),
                                        controllerConnected: false)
        XCTAssertFalse(off.visible)
        // Off draws nothing, controller or not: the three-finger tap opens the menu.
        XCTAssertNil(off.drawnLayout)
        XCTAssertNil(ControlsState.resolve(game: nil, defaults: never, controllerConnected: false).drawnLayout)
        let pad = ControlsState.resolve(game: GameControls(layout: .off), defaults: ControlsDefaults(), controllerConnected: true)
        XCTAssertNil(pad.drawnLayout)
        XCTAssertEqual(ControlsState.resolve(game: nil, defaults: ControlsDefaults(), controllerConnected: false).drawnLayout,
                       .gamepad)
    }

    func testTheSummaryAndOpacitySteps() {
        XCTAssertEqual(ControlsState(layout: .gamepad, visible: true, opacity: 0.6).summary, "Gamepad · 60%")
        XCTAssertEqual(ControlsState(layout: .gamepad, visible: false, opacity: 0.6).summary, "Gamepad · controller connected")
        XCTAssertEqual(ControlsState(layout: .off, visible: false, opacity: 0.6).summary, "Off")
        XCTAssertEqual(ControlsOpacity.step(0.6, by: 1), 0.7)
        XCTAssertEqual(ControlsOpacity.step(1.0, by: 1), 1.0)
        XCTAssertEqual(ControlsOpacity.step(0.2, by: -1), 0.2)
        XCTAssertEqual(ControlsOpacity.step(0.64, by: -1), 0.5)
        XCTAssertEqual(ControlsOpacity.label(0.7), "70%")
    }

    func testDefaultsAndGameControlsFromStorage() throws {
        let d = UserDefaults(suiteName: "ControlsSettingsTests")!
        d.removePersistentDomain(forName: "ControlsSettingsTests")
        XCTAssertEqual(ControlsDefaults(d), ControlsDefaults())
        d.set("always", forKey: ControlsDefaults.showKey)
        d.set(0.8, forKey: ControlsDefaults.opacityKey)
        d.set(false, forKey: ControlsDefaults.hapticsKey)
        XCTAssertEqual(ControlsDefaults(d), ControlsDefaults(show: .always, opacity: 0.8, haptics: false))
        d.set("sometimes", forKey: ControlsDefaults.showKey)
        d.set(7.0, forKey: ControlsDefaults.opacityKey)
        XCTAssertEqual(ControlsDefaults(d), ControlsDefaults(show: .automatic, opacity: 0.6, haptics: false))
        d.removePersistentDomain(forName: "ControlsSettingsTests")
        let g = try JSONDecoder().decode(GameControls.self, from: Data(#"{"layout":"off"}"#.utf8))
        XCTAssertEqual(g, GameControls(layout: .off))
        XCTAssertTrue(try JSONDecoder().decode(GameControls.self, from: Data("{}".utf8)).isEmpty)
        XCTAssertThrowsError(try JSONDecoder().decode(GameControls.self, from: Data(#"{"layout":"tank"}"#.utf8)))
    }
}
