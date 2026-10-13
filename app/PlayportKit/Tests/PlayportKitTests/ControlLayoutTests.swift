// SPDX-License-Identifier: GPL-3.0-or-later
import HostIOKit
import XCTest
@testable import PlayportKit

final class ControlLayoutTests: XCTestCase {
    func testTheGamepadPresetRoundTripsAndIsUsable() throws {
        let g = ControlLayout.gamepad
        XCTAssertNil(g.problem)
        XCTAssertEqual(g.version, 1)
        let data = try JSONEncoder().encode(g)
        XCTAssertEqual(try JSONDecoder().decode(ControlLayout.self, from: data), g)
        XCTAssertEqual(g.controls.map(\.id), ["playport", "view", "menu", "lt", "lb", "rt", "rb", "dpad",
                                              "leftStick", "rightStick", "y", "x", "b", "a"])
        XCTAssertEqual(g.control("playport")?.actions, [.playport(.menu)])
    }

    /// At the board's size (874 × 402) the controls land where TouchGamepad.dc.html draws them.
    func testThePresetMatchesTheBoard() {
        let g = ControlLayout.gamepad
        func frame(_ id: String) -> TouchRect { g.control(id)!.frame(width: 874, height: 402) }
        XCTAssertEqual(frame("playport"), TouchRect(x: 387, y: 8, width: 100, height: 26))
        XCTAssertEqual(frame("view"), TouchRect(x: 330, y: 8, width: 48, height: 26))
        XCTAssertEqual(frame("menu"), TouchRect(x: 496, y: 8, width: 48, height: 26))
        XCTAssertEqual(frame("lt"), TouchRect(x: 44, y: 82, width: 66, height: 34))
        XCTAssertEqual(frame("rb"), TouchRect(x: 764, y: 124, width: 66, height: 34))
        XCTAssertEqual(frame("dpad"), TouchRect(x: 132, y: 168, width: 92, height: 92))
        XCTAssertEqual(frame("leftStick"), TouchRect(x: 52, y: 256, width: 116, height: 116))
        XCTAssertEqual(frame("rightStick"), TouchRect(x: 552, y: 284, width: 92, height: 92))
        XCTAssertEqual(frame("a").center, TouchPoint(x: 748, y: 342))
        XCTAssertEqual(frame("y").center, TouchPoint(x: 748, y: 238))
        XCTAssertEqual(frame("x").center, TouchPoint(x: 696, y: 290))
        XCTAssertEqual(frame("b").center, TouchPoint(x: 800, y: 290))
    }

    func testTargetsDriveTouchControls() {
        let targets = ControlLayout.gamepad.targets(width: 874, height: 402)
        var t = TouchControls(targets: targets)
        // The floating stick: anywhere in the lower left third not on another control.
        XCTAssertEqual(t.target(at: TouchPoint(x: 260, y: 380)).map { targets[$0].id }, "leftStick")
        XCTAssertEqual(t.target(at: TouchPoint(x: 178, y: 214)).map { targets[$0].id }, "dpad")
        XCTAssertNil(t.target(at: TouchPoint(x: 437, y: 200)))   // the middle is the game's
        XCTAssertTrue(t.began(1, at: TouchPoint(x: 748, y: 342), time: 0))
        XCTAssertTrue(t.began(2, at: TouchPoint(x: 437, y: 20), time: 0))
        XCTAssertTrue(t.output.pad.a)
        XCTAssertEqual(t.output.playport, [.menu])
        guard case .stick(.leftStick, let zone?) = targets[8].kind else { return XCTFail("left stick floats") }
        XCTAssertEqual(zone.width, 874.0 / 3, accuracy: 0.001)
        XCTAssertEqual(zone.y, 134, accuracy: 0.001)
    }

    func testANewerOrBrokenLayoutIsRefused() {
        func decode(_ s: String) -> ControlLayout? { try? JSONDecoder().decode(ControlLayout.self, from: Data(s.utf8)) }
        let button = #"{"id":"jump","actions":["key:0x20"],"anchor":"bottomTrailing","x":-60,"y":-60,"width":50,"height":50}"#
        let ok = decode(#"{"version":1,"controls":[\#(button)]}"#)
        XCTAssertEqual(ok?.controls.first?.label, "jump")          // label and behaviour may be left out
        XCTAssertEqual(ok?.controls.first?.behaviour, .hold)
        XCTAssertEqual(ok?.controls.first?.kind, .button)
        XCTAssertNil(decode(#"{"version":2,"controls":[\#(button)]}"#))
        XCTAssertNil(decode(#"{"controls":[\#(button)]}"#))
        XCTAssertNil(decode(#"{"version":1,"controls":[\#(button),\#(button)]}"#))   // one id twice
        XCTAssertNil(decode(#"{"version":1,"controls":[{"id":"s","kind":"stick","actions":["pad:a"],"anchor":"center","x":0,"y":0,"width":50,"height":50}]}"#))
        XCTAssertNil(decode(#"{"version":1,"controls":[{"id":"d","kind":"dpad","actions":["pad:up"],"anchor":"center","x":0,"y":0,"width":50,"height":50}]}"#))
        XCTAssertNil(decode(#"{"version":1,"controls":[{"id":"z","actions":["pad:a"],"anchor":"center","x":0,"y":0,"width":0,"height":50}]}"#))
        XCTAssertNil(decode(#"{"version":1,"controls":[{"id":"a b","actions":["pad:a"],"anchor":"center","x":0,"y":0,"width":5,"height":50}]}"#))
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
        // Off without a controller keeps the Playport button: the menu stays in reach by touch.
        XCTAssertTrue(off.menuButtonOnly)
        XCTAssertEqual(off.drawnLayout?.controls.map(\.id), ["playport"])
        XCTAssertTrue(ControlsState.resolve(game: nil, defaults: never, controllerConnected: false).menuButtonOnly)
        let pad = ControlsState.resolve(game: GameControls(layout: .off), defaults: ControlsDefaults(), controllerConnected: true)
        XCTAssertFalse(pad.menuButtonOnly)
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
