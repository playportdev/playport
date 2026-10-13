// SPDX-License-Identifier: GPL-3.0-or-later
import HostIOKit
import XCTest
@testable import PlayportKit

final class GyroSettingsTests: XCTestCase {
    func testTheDefaultsAreOffAndPlainly() {
        let d = GyroSettings()
        XCTAssertEqual(d.output, .off)
        XCTAssertEqual(d.source, .auto)
        XCTAssertEqual(d.sensitivity, 1)
        XCTAssertEqual(d.verticalRatio, 1)
        XCTAssertEqual(d.turnAxis, .playerSpace)
        XCTAssertFalse(d.invertX)
        XCTAssertFalse(d.invertY)
        XCTAssertEqual(d.pauseButton, .none)
        XCTAssertEqual(d.aimConfig, GyroAim.Config())
    }

    func testSettingsRoundTripAndMissingKeysFallBack() throws {
        let mine = GyroSettings(output: .rightStick, source: .controller, sensitivity: 2.5, verticalRatio: 0.6, turnAxis: .roll,
                                invertX: true, invertY: true, pauseButton: .pad(.lb))
        let data = try JSONEncoder().encode(mine)
        XCTAssertEqual(try JSONDecoder().decode(GyroSettings.self, from: data), mine)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""pauseButton":"pad:lb""#))
        XCTAssertEqual(mine.aimConfig, GyroAim.Config(output: .rightStick, turnAxis: .roll, sensitivity: 2.5, verticalRatio: 0.6,
                                                      invertX: true, invertY: true))

        func decode(_ s: String) throws -> GyroSettings { try JSONDecoder().decode(GyroSettings.self, from: Data(s.utf8)) }
        XCTAssertEqual(try decode("{}"), GyroSettings())
        XCTAssertEqual(try decode(#"{"output":"mouse","sensitivity":3}"#), GyroSettings(output: .mouse, sensitivity: 3))
        // A number out of range is its default; an unknown choice is refused.
        XCTAssertEqual(try decode(#"{"sensitivity":-1,"verticalRatio":99}"#), GyroSettings())
        XCTAssertThrowsError(try decode(#"{"output":"keyboard"}"#))
        XCTAssertThrowsError(try decode(#"{"turnAxis":"pitch"}"#))
        XCTAssertThrowsError(try decode(#"{"pauseButton":"pad:leftStick"}"#))
        XCTAssertThrowsError(try decode(#"{"pauseButton":"key:0x20"}"#))
        XCTAssertEqual(try decode(#"{"pauseButton":"none"}"#).pauseButton, GyroPauseButton.none)
        XCTAssertEqual(try decode(#"{"pauseButton":"pad:rt"}"#).pauseButton, .pad(.rt))
    }

    func testAGameFollowsTheDefaultsWhereItSetsNothing() throws {
        let defaults = GyroSettings(output: .mouse, sensitivity: 1.5, pauseButton: .pad(.lb))
        XCTAssertEqual(GameGyro().resolved(over: defaults), defaults)
        XCTAssertTrue(GameGyro().isEmpty)
        let mine = GameGyro(output: .rightStick, verticalRatio: 0.5, pauseButton: GyroPauseButton.none)
        XCTAssertFalse(mine.isEmpty)
        XCTAssertEqual(mine.resolved(over: defaults),
                       GyroSettings(output: .rightStick, sensitivity: 1.5, verticalRatio: 0.5, pauseButton: .none))
        XCTAssertEqual(GameGyro(sensitivity: .nan).resolved(over: defaults).sensitivity, 1.5)
        // Saved JSON: missing keys follow the defaults; an explicit "none" pause button is the game's own.
        let data = try JSONEncoder().encode(mine)
        XCTAssertEqual(try JSONDecoder().decode(GameGyro.self, from: data), mine)
        XCTAssertEqual(try JSONDecoder().decode(GameGyro.self, from: Data("{}".utf8)), GameGyro())
        XCTAssertEqual(try JSONDecoder().decode(GameGyro.self, from: Data(#"{"pauseButton":"none","invertY":true}"#.utf8)),
                       GameGyro(invertY: true, pauseButton: GyroPauseButton.none))
        XCTAssertThrowsError(try JSONDecoder().decode(GameGyro.self, from: Data(#"{"source":"watch"}"#.utf8)))
    }

    func testTheDefaultsFromStorage() {
        let d = UserDefaults(suiteName: "GyroSettingsTests")!
        d.removePersistentDomain(forName: "GyroSettingsTests")
        XCTAssertEqual(GyroSettings(d), GyroSettings())
        d.set("rightStick", forKey: GyroSettings.outputKey)
        d.set("phone", forKey: GyroSettings.sourceKey)
        d.set(2.0, forKey: GyroSettings.sensitivityKey)
        d.set(0.5, forKey: GyroSettings.verticalRatioKey)
        d.set("yaw", forKey: GyroSettings.turnAxisKey)
        d.set(true, forKey: GyroSettings.invertXKey)
        d.set(false, forKey: GyroSettings.invertYKey)
        d.set("pad:rb", forKey: GyroSettings.pauseButtonKey)
        XCTAssertEqual(GyroSettings(d), GyroSettings(output: .rightStick, source: .phone, sensitivity: 2, verticalRatio: 0.5,
                                                     turnAxis: .yaw, invertX: true, pauseButton: .pad(.rb)))
        // Anything not understood is its default.
        d.set("sideways", forKey: GyroSettings.outputKey)
        d.set(1000.0, forKey: GyroSettings.sensitivityKey)
        d.set("pad:rightStick", forKey: GyroSettings.pauseButtonKey)
        let read = GyroSettings(d)
        XCTAssertEqual(read.output, .off)
        XCTAssertEqual(read.sensitivity, 1)
        XCTAssertEqual(read.pauseButton, .none)
        d.removePersistentDomain(forName: "GyroSettingsTests")
    }

    func testThePauseButtonIsReadFromAPad() {
        var v = PadValues()
        v.buttons = PadMapping.leftShoulder
        XCTAssertTrue(GyroSettings(pauseButton: .pad(.lb)).paused(by: v))
        XCTAssertFalse(GyroSettings(pauseButton: .pad(.rb)).paused(by: v))
        XCTAssertFalse(GyroSettings().paused(by: v))
        XCTAssertFalse(GyroSettings(pauseButton: .pad(.lb)).paused(by: nil))
        XCTAssertEqual(GyroPauseButton.pad(.lt).name, "pad:lt")
        XCTAssertNil(GyroPauseButton(name: "pad:rightStick"))
        XCTAssertNil(GyroPauseButton(name: "mouse:left"))
    }
}
