// SPDX-License-Identifier: GPL-3.0-or-later
import HostIOKit
import XCTest
@testable import PlayportKit

final class ControlLayoutTests: XCTestCase {
    /// Every d-pad and right-stick choice.
    static let options: [(dpad: OnScreenDpad, rightStick: OnScreenRightStick)] =
        OnScreenDpad.allCases.flatMap { d in OnScreenRightStick.allCases.map { (d, $0) } }

    func testTheGamepadPresetRoundTripsAndIsUsable() throws {
        for o in Self.options {
            let g = ControlLayout.gamepad(dpad: o.dpad, rightStick: o.rightStick)
            XCTAssertNil(g.problem)
            XCTAssertEqual(g.version, 2)
            let data = try JSONEncoder().encode(g)
            XCTAssertEqual(try JSONDecoder().decode(ControlLayout.self, from: data), g)
            XCTAssertFalse(g.controls.contains { $0.actions.contains(.playport(.menu)) })   // the menu is a three-finger tap
        }
        // The d-pad and the right stick are off by default.
        XCTAssertEqual(ControlLayout.gamepad().controls.map(\.id), ["view", "menu", "lt", "lb", "rt", "rb", "leftStick", "y", "x", "b", "a"])
        XCTAssertEqual(ControlLayout.gamepad(dpad: .on, rightStick: .below).controls.map(\.id),
                       ["view", "menu", "lt", "lb", "rt", "rb", "dpad", "leftStick", "rightStick", "y", "x", "b", "a"])
        XCTAssertEqual(OnScreenLayout.gamepad.layout(dpad: .off, rightStick: .above), .gamepad(rightStick: .above))
        XCTAssertNil(OnScreenLayout.off.layout(dpad: .on, rightStick: .below))
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

    static func overlap(_ a: TouchRect, _ b: TouchRect) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
    }

    static func gap(_ a: TouchRect, _ b: TouchRect) -> Double {
        let dx = max(b.x - (a.x + a.width), a.x - (b.x + b.width), 0)
        let dy = max(b.y - (a.y + a.height), a.y - (b.y + b.height), 0)
        return max(dx, dy)
    }

    /// The smallest rectangle around them.
    static func bounds(_ rs: [TouchRect]) -> TouchRect {
        let x0 = rs.map(\.x).min()!, y0 = rs.map(\.y).min()!
        let x1 = rs.map { $0.x + $0.width }.max()!, y1 = rs.map { $0.y + $0.height }.max()!
        return TouchRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func testThePresetFitsEveryScreenWithZonesClearOfTheControls() {
        func inside(_ r: TouchRect, _ a: TouchRect) -> Bool {
            r.x >= a.x - 1e-9 && r.y >= a.y - 1e-9 && r.x + r.width <= a.x + a.width + 1e-9 && r.y + r.height <= a.y + a.height + 1e-9
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
        for s in Self.screens {
            for o in Self.options {
                let name = "\(s.name), d-pad \(o.dpad.rawValue), right stick \(o.rightStick.rawValue)"
                let area = s.insets.area(width: s.width, height: s.height)
                let targets = ControlLayout.gamepad(dpad: o.dpad, rightStick: o.rightStick)
                    .targets(width: s.width, height: s.height, insets: s.insets)
                func frame(_ id: String) -> TouchRect? { targets.first { $0.id == id }?.frame }
                var zones: [String: TouchRect] = [:]
                var fixed: [TouchTarget] = []
                for t in targets {
                    XCTAssertTrue(inside(t.frame, area), "\(name): \(t.id) \(t.frame) is outside \(area)")
                    if case .stick(_, let zone?) = t.kind {
                        XCTAssertTrue(inside(zone, area), "\(name): \(t.id)'s zone")
                        XCTAssertTrue(zone.contains(t.frame.center), "\(name): \(t.id) rests in its zone")   // where touch: lands
                        zones[t.id] = zone
                    } else {
                        fixed.append(t)
                    }
                }
                XCTAssertEqual(zones.count, o.rightStick == .off ? 1 : 2, name)
                XCTAssertEqual(frame("dpad") != nil, o.dpad == .on, name)
                for (i, t) in fixed.enumerated() {
                    for (id, z) in zones { XCTAssertGreaterThanOrEqual(Self.gap(t.frame, z), 12, "\(name): \(t.id) is near \(id)'s zone") }
                    for u in fixed[(i + 1)...] { XCTAssertFalse(Self.overlap(t.frame, u.frame), "\(name): \(t.id) and \(u.id) overlap") }
                }
                if let l = zones["leftStick"], let r = zones["rightStick"] {
                    XCTAssertGreaterThanOrEqual(Self.gap(l, r), 12, "\(name): the zones")
                }
                // The left zone takes the lower left corner; the d-pad is centred above it.
                let left = zones["leftStick"]!
                XCTAssertTrue(near(left.x, area.x) && near(left.y + left.height, area.y + area.height), "\(name): the left zone")
                if let d = frame("dpad") {
                    XCTAssertTrue(near(d.center.x, left.center.x), "\(name): the d-pad is centred over the left zone")
                    XCTAssertLessThan(d.y + d.height, left.y, "\(name): the d-pad is above the left zone")
                }
                // A/B/X/Y: the d-pad's size, and the right zone centred on them, below or above.
                let faces = Self.bounds(["y", "x", "b", "a"].map { frame($0)! })
                XCTAssertEqual(faces.width, 126, name)
                XCTAssertEqual(faces.height, 126, name)
                if let d = frame("dpad") { XCTAssertEqual(d.width, faces.width, name) }
                XCTAssertTrue(near(frame("y")!.center.x, faces.center.x) && near(frame("a")!.center.x, faces.center.x), name)
                let bottom = area.y + area.height, right = area.x + area.width
                switch o.rightStick {
                case .off, .above:
                    XCTAssertTrue(near(faces.y + faces.height, bottom), "\(name): A/B/X/Y keep the lower right corner")
                case .below:
                    XCTAssertLessThan(faces.y + faces.height, bottom, "\(name): A/B/X/Y move up")
                }
                if let z = zones["rightStick"] {
                    XCTAssertTrue(near(z.center.x, faces.center.x), "\(name): the right zone is centred on A/B/X/Y")
                    if o.rightStick == .below {
                        XCTAssertTrue(near(z.y + z.height, bottom) && near(z.x + z.width, right), "\(name): the right zone takes the corner")
                        XCTAssertLessThan(faces.y + faces.height, z.y, "\(name): A/B/X/Y over the zone")
                    } else {
                        XCTAssertLessThan(z.y + z.height, faces.y, "\(name): the zone over A/B/X/Y")
                    }
                }
            }
        }
    }

    /// At 874 × 402 with the island on the left and right: the left zone and the
    /// d-pad over it, the right zone in the corner with A B X Y over it (Below),
    /// or A B X Y in the corner with the zone over them (Above); each control's
    /// edge nearest a zone is its own, the gap and the middle the game's.
    func testTheZonesAndTheirNeighboursHitWhereTheyAreDrawn() {
        let insets = ControlInsets(left: 62, bottom: 21, right: 62)
        let targets = ControlLayout.gamepad(dpad: .on, rightStick: .below).targets(width: 874, height: 402, insets: insets)
        func target(_ id: String) -> TouchTarget { targets.first { $0.id == id }! }
        guard case .stick(.leftStick, let lz?) = target("leftStick").kind,
              case .stick(.rightStick, let rz?) = target("rightStick").kind else { return XCTFail("both sticks float") }
        XCTAssertEqual(lz, TouchRect(x: 62, y: 255, width: 210, height: 126))
        XCTAssertEqual(rz, TouchRect(x: 602, y: 255, width: 210, height: 126))
        XCTAssertEqual(target("dpad").frame, TouchRect(x: 104, y: 117, width: 126, height: 126))
        XCTAssertEqual(target("a").frame, TouchRect(x: 686, y: 201, width: 42, height: 42))
        XCTAssertEqual(target("y").frame.center, TouchPoint(x: 707, y: 138))
        XCTAssertEqual(target("x").frame.center, TouchPoint(x: 665, y: 180))
        XCTAssertEqual(target("b").frame.center, TouchPoint(x: 749, y: 180))
        XCTAssertEqual(target("lt").frame, TouchRect(x: 68, y: 4, width: 64, height: 40))
        XCTAssertEqual(target("lb").frame, TouchRect(x: 68, y: 50, width: 64, height: 40))
        XCTAssertEqual(target("view").frame, TouchRect(x: 138, y: 7, width: 44, height: 30))
        XCTAssertEqual(target("menu").frame, TouchRect(x: 692, y: 7, width: 44, height: 30))

        var t = TouchControls(targets: targets)
        func owner(_ x: Double, _ y: Double) -> String? { t.target(at: TouchPoint(x: x, y: y)).map { targets[$0].id } }
        // Each zone is its stick's, edge to edge.
        XCTAssertEqual(owner(63, 380), "leftStick")
        XCTAssertEqual(owner(271, 256), "leftStick")
        XCTAssertEqual(owner(811, 380), "rightStick")
        XCTAssertEqual(owner(603, 256), "rightStick")
        // The d-pad's and A's edges nearest the zones are theirs, not a stick's; the gap is the game's.
        XCTAssertEqual(owner(167, 242), "dpad")
        XCTAssertEqual(owner(707, 242), "a")
        XCTAssertNil(owner(167, 249))
        XCTAssertNil(owner(707, 249))
        // A/B/X/Y side by side: each its own square, the corners between them and the middle the game's.
        XCTAssertEqual(owner(685, 180), "x")
        XCTAssertEqual(owner(729, 180), "b")
        XCTAssertNil(owner(707, 180))
        XCTAssertNil(owner(667, 143))
        XCTAssertNil(owner(437, 300))
        XCTAssertNil(owner(437, 30))
        // Out of the safe area (under the island) is the game's.
        XCTAssertNil(owner(30, 380))
        // A face button and the d-pad with both sticks, all at once.
        XCTAssertTrue(t.began(1, at: TouchPoint(x: 707, y: 223), time: 0))
        XCTAssertTrue(t.began(2, at: TouchPoint(x: 167, y: 130), time: 0))
        XCTAssertTrue(t.began(3, at: TouchPoint(x: 150, y: 330), time: 0))
        XCTAssertTrue(t.began(4, at: TouchPoint(x: 700, y: 330), time: 0))
        t.moved(3, at: TouchPoint(x: 150, y: 278), time: 0.05)
        t.moved(4, at: TouchPoint(x: 648, y: 330), time: 0.05)
        let pad = t.output.pad
        XCTAssertTrue(pad.a)
        XCTAssertTrue(pad.up)
        XCTAssertEqual(pad.ly, 1, accuracy: 0.001)
        XCTAssertEqual(pad.rx, -1, accuracy: 0.001)
        XCTAssertEqual(t.held, ["a", "dpad", "leftStick", "rightStick"])

        // Above: A B X Y in the corner, the zone over them; the gap between is the game's.
        let above = ControlLayout.gamepad(rightStick: .above).targets(width: 874, height: 402, insets: insets)
        guard case .stick(.rightStick, let az?) = above.first(where: { $0.id == "rightStick" })!.kind else { return XCTFail("floats") }
        XCTAssertEqual(az, TouchRect(x: 602, y: 129, width: 210, height: 114))
        XCTAssertEqual(above.first { $0.id == "a" }!.frame, TouchRect(x: 686, y: 339, width: 42, height: 42))
        XCTAssertEqual(above.first { $0.id == "y" }!.frame, TouchRect(x: 686, y: 255, width: 42, height: 42))
        let u = TouchControls(targets: above)
        func aboveOwner(_ x: Double, _ y: Double) -> String? { u.target(at: TouchPoint(x: x, y: y)).map { above[$0].id } }
        XCTAssertEqual(aboveOwner(707, 242), "rightStick")
        XCTAssertNil(aboveOwner(707, 249))
        XCTAssertEqual(aboveOwner(707, 256), "y")
        XCTAssertNil(above.first { $0.id == "dpad" })
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
        // A zone's offset (1c) may be left out: 0, as a layout saved before it reads.
        XCTAssertEqual(decode(#"{"version":2,"controls":[\#(stick),"floatingZone":{"anchor":"bottomTrailing","y":-132,"width":210,"height":120}}]}"#)?
            .controls.first?.floatingZone, ControlZone(anchor: .bottomTrailing, y: -132, width: 210, height: 120))
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
                       .gamepad())
    }

    /// The controls' pad is player 1 whenever no controller is connected, Off too,
    /// so turning the controls on in-game connects nothing new (1c).
    func testTheControlsPadIsConnectedWhileNoControllerIs() {
        let d = ControlsDefaults()
        let off = GameControls(layout: .off)
        XCTAssertTrue(ControlsState.resolve(game: off, defaults: d, controllerConnected: false).padConnected)
        XCTAssertTrue(ControlsState.resolve(game: nil, defaults: ControlsDefaults(show: .never), controllerConnected: false).padConnected)
        XCTAssertTrue(ControlsState.resolve(game: nil, defaults: d, controllerConnected: false).padConnected)
        // A controller connected is player 1 instead, unless Always shows the controls with it.
        XCTAssertFalse(ControlsState.resolve(game: off, defaults: d, controllerConnected: true).padConnected)
        XCTAssertFalse(ControlsState.resolve(game: nil, defaults: d, controllerConnected: true).padConnected)
        XCTAssertTrue(ControlsState.resolve(game: nil, defaults: ControlsDefaults(show: .always), controllerConnected: true).padConnected)
        XCTAssertFalse(ControlsState.resolve(game: off, defaults: ControlsDefaults(show: .always), controllerConnected: true).padConnected)
    }

    /// The d-pad and the right stick: the game's own, else Settings › Controls' (both Off by default).
    func testTheDpadAndRightStickFollowTheGameThenTheDefaults() {
        let plain = ControlsState.resolve(game: nil, defaults: ControlsDefaults(), controllerConnected: false)
        XCTAssertEqual(plain.dpad, .off)
        XCTAssertEqual(plain.rightStick, .off)
        XCTAssertEqual(plain.drawnLayout, .gamepad(dpad: .off, rightStick: .off))
        let defaults = ControlsDefaults(dpad: .on, rightStick: .above)
        let withDefaults = ControlsState.resolve(game: GameControls(layout: .gamepad), defaults: defaults, controllerConnected: false)
        XCTAssertEqual(withDefaults.drawnLayout, .gamepad(dpad: .on, rightStick: .above))
        let mine = ControlsState.resolve(game: GameControls(rightStick: .below), defaults: defaults, controllerConnected: false)
        XCTAssertEqual(mine.dpad, .on)
        XCTAssertEqual(mine.rightStick, .below)
        XCTAssertEqual(mine.drawnLayout, .gamepad(dpad: .on, rightStick: .below))
        XCTAssertFalse(GameControls(dpad: .off).isEmpty)
        XCTAssertEqual(OnScreenRightStick.allCases.map(\.title), ["Off", "Below A/B/X/Y", "Above A/B/X/Y"])
        XCTAssertEqual(OnScreenDpad.allCases.map(\.title), ["Off", "On"])
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
        d.set("on", forKey: ControlsDefaults.dpadKey)
        d.set("below", forKey: ControlsDefaults.rightStickKey)
        XCTAssertEqual(ControlsDefaults(d), ControlsDefaults(show: .automatic, opacity: 0.6, haptics: false, dpad: .on, rightStick: .below))
        d.set("sideways", forKey: ControlsDefaults.rightStickKey)
        XCTAssertEqual(ControlsDefaults(d).rightStick, .off)
        d.removePersistentDomain(forName: "ControlsSettingsTests")
        let g = try JSONDecoder().decode(GameControls.self, from: Data(#"{"layout":"off"}"#.utf8))
        XCTAssertEqual(g, GameControls(layout: .off))
        // A game saved before the d-pad and right stick options reads them as the defaults'.
        XCTAssertEqual(try JSONDecoder().decode(GameControls.self, from: Data(#"{"layout":"gamepad","opacity":0.8}"#.utf8)),
                       GameControls(layout: .gamepad, opacity: 0.8))
        XCTAssertEqual(try JSONDecoder().decode(GameControls.self, from: Data(#"{"dpad":"on","rightStick":"above"}"#.utf8)),
                       GameControls(dpad: .on, rightStick: .above))
        XCTAssertThrowsError(try JSONDecoder().decode(GameControls.self, from: Data(#"{"rightStick":"left"}"#.utf8)))
        XCTAssertTrue(try JSONDecoder().decode(GameControls.self, from: Data("{}".utf8)).isEmpty)
        XCTAssertThrowsError(try JSONDecoder().decode(GameControls.self, from: Data(#"{"layout":"tank"}"#.utf8)))
    }
}
