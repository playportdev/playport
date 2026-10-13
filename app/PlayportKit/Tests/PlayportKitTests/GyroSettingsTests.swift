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
        // The driver's set: stores "1.5" as a String and 2 as an Int: both read as numbers.
        d.set("1.5", forKey: GyroSettings.sensitivityKey)
        d.set(2, forKey: GyroSettings.verticalRatioKey)
        XCTAssertEqual(GyroSettings(d).sensitivity, 1.5)
        XCTAssertEqual(GyroSettings(d).verticalRatio, 2)
        d.set("fast", forKey: GyroSettings.sensitivityKey)
        XCTAssertEqual(GyroSettings(d).sensitivity, 1)
        d.removePersistentDomain(forName: "GyroSettingsTests")
    }

    /// A game's gyro aim lives in its GameControls record (ControlsStore): controls
    /// saved before it load unchanged, and a gyro that sets nothing is not kept.
    func testAGamesGyroIsPartOfItsControls() throws {
        func decode(_ s: String) throws -> GameControls { try JSONDecoder().decode(GameControls.self, from: Data(s.utf8)) }
        XCTAssertEqual(try decode(#"{"layout":"gamepad","opacity":0.8,"dpad":"on"}"#),
                       GameControls(layout: .gamepad, opacity: 0.8, dpad: .on))
        XCTAssertNil(try decode(#"{"layout":"off"}"#).gyro)
        let mine = try decode(#"{"layout":"off","gyro":{"output":"mouse","sensitivity":2,"pauseButton":"pad:lb"}}"#)
        XCTAssertEqual(mine, GameControls(layout: .off, gyro: GameGyro(output: .mouse, sensitivity: 2, pauseButton: .pad(.lb))))
        XCTAssertEqual(try decode(String(decoding: try JSONEncoder().encode(mine), as: UTF8.self)), mine)
        XCTAssertThrowsError(try decode(#"{"gyro":{"output":"keyboard"}}"#))
        // Only gyro set is not empty; an empty gyro is.
        XCTAssertFalse(GameControls(gyro: GameGyro(output: .rightStick)).isEmpty)
        XCTAssertTrue(GameControls(gyro: GameGyro()).isEmpty)
        XCTAssertNil(GameControls(layout: .off, gyro: GameGyro()).normalized.gyro)
        XCTAssertEqual(GameControls(gyro: GameGyro(invertY: true)).normalized.gyro, GameGyro(invertY: true))
        // Resolved over the gyro.* defaults.
        let defaults = GyroSettings(output: .rightStick, sensitivity: 1.5)
        XCTAssertEqual(GameControls().gyroSettings(over: defaults), defaults)
        XCTAssertEqual(mine.gyroSettings(over: defaults), GyroSettings(output: .mouse, sensitivity: 2, pauseButton: .pad(.lb)))
        XCTAssertEqual(GyroSettings(output: .mouse, invertY: true, pauseButton: .pad(.lb)).summary,
                       "output=mouse source=auto sensitivity=1.0 verticalRatio=1.0 turnAxis=playerSpace invert=-y pause=pad:lb")
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

    /// The sensors run only while the output is not Off and the game is in front, taking input.
    func testTheSensorsRunOnlyWhileTheGameTakesInput() {
        let mouse = GyroSettings(output: .mouse)
        let on = GyroConditions(settings: mouse, gameDrawing: true, appActive: true)
        XCTAssertEqual(GyroRun.decide(on), .running(.phone, .mouse))
        var c = on
        c.settings.output = .off
        XCTAssertEqual(GyroRun.decide(c), .stopped("output off"))
        c = on; c.gameDrawing = false
        XCTAssertEqual(GyroRun.decide(c), .stopped("no game in front"))
        c = on; c.appActive = false
        XCTAssertEqual(GyroRun.decide(c), .stopped("app not active"))
        c = on; c.guestHeld = true
        XCTAssertEqual(GyroRun.decide(c), .stopped("menu"))
        c = on; c.dialog = true
        XCTAssertEqual(GyroRun.decide(c), .stopped("dialog"))
        XCTAssertNil(GyroRun.decide(c).device)
        // Off wins over everything else: nothing runs for a game that has none.
        XCTAssertEqual(GyroRun.decide(GyroConditions(settings: GyroSettings(), gameDrawing: false, appActive: false, guestHeld: true)),
                       .stopped("output off"))
    }

    func testTheSourceAutomaticPrefersAControllersGyro() {
        XCTAssertEqual(GyroSource.auto.device(phone: true, controller: true), .controller)
        XCTAssertEqual(GyroSource.auto.device(phone: true, controller: false), .phone)
        XCTAssertNil(GyroSource.auto.device(phone: false, controller: false))
        XCTAssertEqual(GyroSource.phone.device(phone: true, controller: true), .phone)
        XCTAssertEqual(GyroSource.controller.device(phone: true, controller: true), .controller)
        // An explicit Controller does not fall back to the iPhone.
        XCTAssertNil(GyroSource.controller.device(phone: true, controller: false))
        let stick = GyroSettings(output: .rightStick, source: .controller)
        XCTAssertEqual(GyroRun.decide(GyroConditions(settings: stick, gameDrawing: true, appActive: true, controllerHasGyro: true)),
                       .running(.controller, .rightStick))
        XCTAssertEqual(GyroRun.decide(GyroConditions(settings: stick, gameDrawing: true, appActive: true)),
                       .stopped("no controller with a gyro"))
        XCTAssertEqual(GyroRun.decide(GyroConditions(settings: GyroSettings(output: .mouse), gameDrawing: true, appActive: true,
                                                     phoneHasGyro: false)), .stopped("no gyro"))
    }

    /// The Gyro aim page's test area runs the sensors only outside a game, with
    /// its output for the dot; a running game's run always wins and alone reaches the guest.
    func testThePreviewNeverTakesTheGuest() {
        let mouse = GyroSettings(output: .mouse)
        let noGame = GyroConditions(settings: mouse, gameDrawing: false, appActive: true)
        let page = GyroPreviewConditions(settings: mouse)
        XCTAssertEqual(GyroRun.decide(noGame, preview: page), .previewing(.phone, .mouse))
        XCTAssertFalse(GyroRun.decide(noGame, preview: page).toGuest)
        XCTAssertEqual(GyroRun.decide(noGame, preview: page).device, .phone)
        // No page: as before.
        XCTAssertEqual(GyroRun.decide(noGame, preview: nil), .stopped("no game in front"))
        // A game running (even before its first frame, or under its menu): never the page's.
        var running = page
        running.gameRunning = true
        XCTAssertEqual(GyroRun.decide(noGame, preview: running), .stopped("no game in front"))
        var menu = GyroConditions(settings: mouse, gameDrawing: true, appActive: true, guestHeld: true)
        XCTAssertEqual(GyroRun.decide(menu, preview: running), .stopped("menu"))
        menu.guestHeld = false
        XCTAssertEqual(GyroRun.decide(menu, preview: page), .running(.phone, .mouse))
        XCTAssertTrue(GyroRun.decide(menu, preview: page).toGuest)
        // The page's own conditions.
        var p = page
        p.settings.output = .off
        XCTAssertEqual(GyroRun.decide(noGame, preview: p), .stopped("preview: output off"))
        p = page
        p.appActive = false
        XCTAssertEqual(GyroRun.decide(noGame, preview: p), .stopped("preview: app not active"))
        p = GyroPreviewConditions(settings: GyroSettings(output: .rightStick, source: .controller))
        XCTAssertEqual(GyroRun.decide(noGame, preview: p), .stopped("preview: no controller with a gyro"))
        p.controllerHasGyro = true
        XCTAssertEqual(GyroRun.decide(noGame, preview: p), .previewing(.controller, .rightStick))
    }

    /// A game's row: its value over the default, the amber dot while the game sets it, Y back to the default.
    func testAGyroRowResolvesAndResets() {
        let defaults = GyroSettings(output: .mouse, sensitivity: 2)
        var own: GameGyro? = GameGyro(sensitivity: 1.5, invertY: true)
        let s = GameControls(gyro: own).gyroSettings(over: defaults)
        XCTAssertEqual(GyroRow.output.text(s), "Mouse")
        XCTAssertFalse(GyroRow.output.isSet(in: own))
        XCTAssertEqual(GyroRow.sensitivity.text(s), "1.5×")
        XCTAssertTrue(GyroRow.sensitivity.isSet(in: own))
        XCTAssertEqual(GyroRow.invertY.text(s), "On")
        own = GyroRow.sensitivity.cleared(own)
        XCTAssertEqual(own, GameGyro(invertY: true))
        XCTAssertEqual(GameControls(gyro: own).gyroSettings(over: defaults).sensitivity, 2)
        XCTAssertNil(GyroRow.invertY.cleared(own))           // nothing left set
        XCTAssertNil(GyroRow.output.cleared(nil))
        // Choosing sets the field, by the choice's id.
        own = GyroRow.output.setting("rightStick", in: nil)
        own = GyroRow.pauseButton.setting("pad:lb", in: own)
        own = GyroRow.verticalRatio.setting("0.8", in: own)
        XCTAssertEqual(own, GameGyro(output: .rightStick, verticalRatio: 0.8, pauseButton: .pad(.lb)))
        let r = GameControls(gyro: own).gyroSettings(over: defaults)
        XCTAssertEqual(GyroRow.pauseButton.text(r), "LB")
        XCTAssertEqual(GyroRow.verticalRatio.text(r), "0.8× of across")
        XCTAssertEqual(GyroText.summary(r), "Right stick · 2.0×")
        XCTAssertEqual(GyroText.summary(GyroSettings()), "Off")
        // Every row's current choice is one of its choices, and each choice's id sets it back.
        for row in GyroRow.allCases {
            let id = row.choices[row.index(in: r)].id
            XCTAssertEqual(GameControls(gyro: row.setting(id, in: nil)).gyroSettings(over: r), r, row.rawValue)
        }
    }

    func testAGyroRowStepsAlongItsChoices() {
        let s = GyroSettings(output: .rightStick, sensitivity: 1.7)
        XCTAssertEqual(GyroRow.output.step(s, by: 1), "rightStick")             // stops at the end
        XCTAssertEqual(GyroRow.output.step(s, by: 1, wrapping: true), "off")    // A goes round
        XCTAssertEqual(GyroRow.sensitivity.text(s), "1.7×")                      // between the steps: as it is
        XCTAssertEqual(GyroRow.sensitivity.step(s, by: 1), "2.0")               // from the nearest, 1.5
        XCTAssertEqual(GyroRow.sensitivity.step(s, by: -1), "1.25")
        XCTAssertEqual(GyroText.sensitivity(0.25), "0.25×")
        XCTAssertEqual(GyroRow.invertX.step(s, by: 1, wrapping: true), "true")
        XCTAssertEqual(GyroRow.invertX.stored("true") as? Bool, true)
        XCTAssertEqual(GyroRow.sensitivity.stored("2.5") as? Double, 2.5)
        XCTAssertEqual(GyroRow.output.stored("mouse") as? String, "mouse")
        XCTAssertEqual(GyroSteps.pauseButtons.first, GyroPauseButton.none)
        XCTAssertTrue(GyroSteps.pauseButtons.allSatisfy { GyroPauseButton(name: $0.name) == $0 })
    }

    /// The source row shows the gyro in use, and why there is none.
    func testTheSourceRowSaysWhichGyro() {
        XCTAssertEqual(GyroText.sourceInUse(.auto, device: .phone).value, "Auto · iPhone")
        XCTAssertEqual(GyroText.sourceInUse(.auto, device: .controller).value, "Auto · Controller")
        XCTAssertEqual(GyroText.sourceInUse(.phone, device: .phone).value, "iPhone")
        XCTAssertNil(GyroText.sourceInUse(.phone, device: .phone).why)
        XCTAssertEqual(GyroText.sourceInUse(.controller, device: nil).why, "No controller with a gyro is connected")
    }
}
