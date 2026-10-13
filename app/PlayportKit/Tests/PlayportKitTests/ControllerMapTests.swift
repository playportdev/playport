// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import HostIOKit
@testable import PlayportKit

/// ControllerMap (docs/plans/2026-10-09-touch-controls.md, phase 3): the
/// keyboardMouse preset, its storage, and the preset played through InputMixer.
final class ControllerMapTests: XCTestCase {
    func testThePresetIsThePlansTable() {
        let want: [String: String] = [
            "leftStick.up": "key:0x57", "leftStick.left": "key:0x41", "leftStick.down": "key:0x53", "leftStick.right": "key:0x44",
            "rightStick": "mouse:move", "rt": "mouse:left", "lt": "mouse:right",
            "a": "key:0x20", "b": "key:0x43", "x": "key:0x52", "y": "key:0x46", "lb": "key:0x51", "rb": "key:0x45",
            "up": "key:0x26", "right": "key:0x27", "down": "key:0x28", "left": "key:0x25",   // the arrow keys
            "back": "key:0x09", "start": "key:0x1B",
        ]
        XCTAssertEqual(ControllerMap.keyboardMouse.names, want)
        // ls and rs (the sticks' buttons) are not bound; nothing is Home.
        XCTAssertNil(ControllerMap.keyboardMouse[.control(.ls)])
        XCTAssertNil(ControllerMap.keyboardMouse[.control(.rs)])
    }

    func testModesAndTheirTables() {
        XCTAssertNil(ControllerMap().bindings)
        XCTAssertEqual(ControllerMap(mode: .keyboardMouse).bindings, ControllerMap.keyboardMouse)
        // custom starts as a copy of the preset, and is kept while another mode is chosen.
        var m = ControllerMap(mode: .custom)
        XCTAssertEqual(m.bindings, ControllerMap.keyboardMouse)
        var t = ControllerMap.keyboardMouse.table
        t[.control(.a)] = .pad(.a)
        m.custom = ControllerBindings(t)!
        m.mode = .keyboardMouse
        XCTAssertEqual(m.bindings, ControllerMap.keyboardMouse)
        m.mode = .custom
        XCTAssertEqual(m.bindings?[.control(.a)], .pad(.a))
        XCTAssertEqual(m.summary, "custom (19 inputs)")
        XCTAssertEqual(ControllerMap(mode: .keyboardMouse).summary, "keyboardMouse")
    }

    func testCodableRoundTripAndVersion() throws {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        XCTAssertEqual(String(decoding: try e.encode(ControllerMap(mode: .keyboardMouse)), as: UTF8.self),
                       #"{"mode":"keyboardMouse","version":1}"#)
        let custom = ControllerMap(mode: .custom, custom: ControllerBindings([.control(.a): .key(0x20, []), .control(.rightStick): .mouse(.move)])!)
        XCTAssertEqual(String(decoding: try e.encode(custom), as: UTF8.self),
                       #"{"mode":"custom","table":{"a":"key:0x20","rightStick":"mouse:move"},"version":1}"#)
        for m in [ControllerMap(), ControllerMap(mode: .keyboardMouse), ControllerMap(mode: .custom), custom] {
            XCTAssertEqual(try JSONDecoder().decode(ControllerMap.self, from: try e.encode(m)), m)
        }
        // The driver's form, with no version; custom with no table is the preset.
        XCTAssertEqual(try JSONDecoder().decode(ControllerMap.self, from: Data(#"{"mode":"keyboardMouse"}"#.utf8)),
                       ControllerMap(mode: .keyboardMouse))
        XCTAssertEqual(try JSONDecoder().decode(ControllerMap.self, from: Data(#"{"mode":"custom"}"#.utf8)).bindings,
                       ControllerMap.keyboardMouse)
        for bad in [#"{"mode":"keyboardMouse","version":2}"#, #"{"mode":"mouse"}"#, #"{}"#,
                    #"{"mode":"custom","table":{"home":"key:0x20"}}"#, #"{"mode":"custom","table":{"a":"mouse:move"}}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(ControllerMap.self, from: Data(bad.utf8)), bad)
        }
    }

    func testAGamesMapInItsControlsRecord() throws {
        // Saved before controller maps: none, the default.
        let old = try JSONDecoder().decode(GameControls.self, from: Data(#"{"layout":"off","gyro":{"output":"mouse"}}"#.utf8))
        XCTAssertNil(old.controllerMap)
        XCTAssertEqual(old.controllerMap(over: ControlsDefaults()), ControllerMap())
        let mine = GameControls(controllerMap: ControllerMap(mode: .keyboardMouse))
        XCTAssertFalse(mine.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(GameControls.self, from: try JSONEncoder().encode(mine)), mine)
        XCTAssertEqual(mine.controllerMap(over: ControlsDefaults(controllerMap: ControllerMap(mode: .custom))),
                       ControllerMap(mode: .keyboardMouse))
        XCTAssertEqual(GameControls().controllerMap(over: ControlsDefaults(controllerMap: ControllerMap(mode: .custom))),
                       ControllerMap(mode: .custom))
        // A map of another version: the record still loads, the map follows the default.
        let later = try JSONDecoder().decode(GameControls.self,
                                             from: Data(#"{"opacity":0.8,"controllerMap":{"version":9,"mode":"keyboardMouse"}}"#.utf8))
        XCTAssertEqual(later, GameControls(opacity: 0.8))
        let custom = try JSONDecoder().decode(GameControls.self, from: Data(
            #"{"controllerMap":{"mode":"custom","table":{"a":"key:0x20","leftStick":"pad:leftStick"}}}"#.utf8))
        XCTAssertEqual(custom.controllerMap?.bindings?.names, ["a": "key:0x20", "leftStick": "pad:leftStick"])
    }

    func testSettingsDefault() throws {
        let d = UserDefaults(suiteName: "ControllerMapTests")!
        d.removePersistentDomain(forName: "ControllerMapTests")
        XCTAssertEqual(ControlsDefaults(d).controllerMap, ControllerMap())
        d.set("keyboardMouse", forKey: ControlsDefaults.controllerMapKey)   // the driver's set:controls.controllerMap=keyboardMouse
        XCTAssertEqual(ControlsDefaults(d).controllerMap, ControllerMap(mode: .keyboardMouse))
        d.set(#"{"mode":"custom","table":{"a":"key:0x20"}}"#, forKey: ControlsDefaults.controllerMapKey)
        XCTAssertEqual(ControlsDefaults(d).controllerMap.bindings?.names, ["a": "key:0x20"])
        d.set("tank", forKey: ControlsDefaults.controllerMapKey)
        XCTAssertEqual(ControlsDefaults(d).controllerMap, ControllerMap())
        d.removePersistentDomain(forName: "ControllerMapTests")
    }

    func testLookSpeedPerGameOverTheDefault() throws {
        let d = UserDefaults(suiteName: "ControllerMapTests.look")!
        d.removePersistentDomain(forName: "ControllerMapTests.look")
        XCTAssertEqual(ControlsDefaults(d).lookSpeed, 1)
        d.set(2, forKey: ControlsDefaults.lookSpeedKey)                  // an Int, as set: stores 2
        XCTAssertEqual(ControlsDefaults(d).lookSpeed, 2)
        d.set("1.5", forKey: ControlsDefaults.lookSpeedKey)              // a String, as set: stores 1.5
        XCTAssertEqual(ControlsDefaults(d).lookSpeed, 1.5)
        d.set(50.0, forKey: ControlsDefaults.lookSpeedKey)               // out of range: the default
        XCTAssertEqual(ControlsDefaults(d).lookSpeed, 1)
        d.removePersistentDomain(forName: "ControllerMapTests.look")
        let defaults = ControlsDefaults(lookSpeed: 0.5)
        XCTAssertEqual(GameControls().lookSpeed(over: defaults), 0.5)
        XCTAssertEqual(GameControls(lookSpeed: 3).lookSpeed(over: defaults), 3)
        XCTAssertEqual(GameControls(lookSpeed: 0).lookSpeed(over: defaults), 0.5)
        XCTAssertFalse(GameControls(lookSpeed: 2).isEmpty)
        // Saved in the game's record; older records read as none.
        let c = try JSONDecoder().decode(GameControls.self, from: Data(#"{"lookSpeed":2.5,"controllerMap":{"mode":"keyboardMouse"}}"#.utf8))
        XCTAssertEqual(c.lookSpeed, 2.5)
        XCTAssertEqual(try JSONDecoder().decode(GameControls.self, from: try JSONEncoder().encode(c)), c)
        XCTAssertNil(try JSONDecoder().decode(GameControls.self, from: Data(#"{"layout":"off"}"#.utf8)).lookSpeed)
        // The row's steps: 0.25× to 4×, stopping at the ends, from the nearest step.
        XCTAssertEqual(LookSpeed.step(1, by: 1), 1.25)
        XCTAssertEqual(LookSpeed.step(4, by: 1), 4)
        XCTAssertEqual(LookSpeed.step(0.25, by: -1), 0.25)
        XCTAssertEqual(LookSpeed.step(1.1, by: 1), 1.25)
        XCTAssertEqual(LookSpeed.label(1), "1.0×")
        XCTAssertEqual(LookSpeed.label(0.25), "0.25×")
    }

    // MARK: the preset through the mixer

    func pad(_ input: (inout PadInput) -> Void) -> PadValues {
        var p = PadInput()
        input(&p)
        return PadMapping.values(p)
    }

    func mixer() -> InputMixer {
        var m = InputMixer()
        _ = m.setMap(ControllerMap(mode: .keyboardMouse).bindings)
        return m
    }

    func testEveryButtonOfThePreset() {
        let presses: [(String, (inout PadInput) -> Void, UInt8)] = [
            ("A", { $0.a = true }, 0x20), ("B", { $0.b = true }, 0x43), ("X", { $0.x = true }, 0x52), ("Y", { $0.y = true }, 0x46),
            ("LB", { $0.leftShoulder = true }, 0x51), ("RB", { $0.rightShoulder = true }, 0x45),
            ("up", { $0.up = true }, 0x26), ("right", { $0.right = true }, 0x27), ("down", { $0.down = true }, 0x28),
            ("left", { $0.left = true }, 0x25), ("View", { $0.options = true }, 0x09), ("Menu", { $0.menu = true }, 0x1B),
        ]
        var m = mixer()
        for (name, press, vk) in presses {
            XCTAssertEqual(m.physical(slot: 0, pad(press)), PadValues(), name)
            XCTAssertEqual(m.takeOutputs(), [.key(vk, down: true)], name)
            _ = m.physical(slot: 0, PadValues())
            XCTAssertEqual(m.takeOutputs(), [.key(vk, down: false)], name)
        }
    }

    func testHomeIsNeverMapped() {
        var m = mixer()
        XCTAssertEqual(m.physical(slot: 0, pad { $0.home = true }), PadValues())
        XCTAssertEqual(m.takeOutputs(), [])
        XCTAssertFalse(ControllerInput.all.contains { $0.name == "home" })
    }

    func testTriggersAreMouseButtonsAndSticksWASDAndLook() {
        var m = mixer()
        _ = m.physical(slot: 0, pad { $0.rightTrigger = 0.9; $0.leftTrigger = 0.6 })
        XCTAssertEqual(m.takeOutputs(), [.pointer(flags: Pointer.leftDown, data: 0), .pointer(flags: Pointer.rightDown, data: 0)])
        _ = m.physical(slot: 0, pad { $0.lx = 0.8; $0.ly = 0.8 })
        XCTAssertEqual(m.takeOutputs(), [.key(0x44, down: true), .key(0x57, down: true),
                                         .pointer(flags: Pointer.leftUp, data: 0), .pointer(flags: Pointer.rightUp, data: 0)])
        _ = m.physical(slot: 0, pad { $0.rx = -1 })
        XCTAssertEqual(m.takeOutputs(), [.key(0x57, down: false), .key(0x44, down: false)])
        XCTAssertTrue(m.needsClock)
        m.tick(time: 1)
        m.tick(time: 1.016)
        XCTAssertEqual(m.takeOutputs(), [.move(dx: -32, dy: 0)])
    }
}
