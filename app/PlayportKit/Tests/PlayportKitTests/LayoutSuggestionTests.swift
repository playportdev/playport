// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit

final class LayoutSuggestionTests: XCTestCase {
    let gamepad = ControlsState(layout: .gamepad, visible: true, opacity: 0.6)

    /// Samples once a second from `from` to `to` (seconds after the first frame), the last
    /// sample's verdict.
    func run(_ s: inout LayoutSuggestion, from: Int, to: Int, reads: UInt64 = 0, running: Bool = true,
             state: ControlsState? = nil, chosen: Bool = false) -> [Int] {
        (from...to).filter { t in
            s.sample(at: TimeInterval(t), reads: reads, running: running, state: state ?? gamepad, chosen: chosen)
        }
    }

    func testAGameOnGamepadThatReadsNoPadIsOfferedKeyboardAndMouseOnceAfter20Seconds() {
        var s = LayoutSuggestion(offered: false)
        XCTAssertEqual(run(&s, from: 0, to: 60), [20])
        XCTAssertTrue(s.done)
    }

    func testOneStateReadEndsItWithoutAnOffer() {
        var s = LayoutSuggestion(offered: false)
        XCTAssertEqual(run(&s, from: 0, to: 10), [])
        XCTAssertEqual(run(&s, from: 11, to: 11, reads: 1), [])
        XCTAssertTrue(s.done)
        XCTAssertEqual(run(&s, from: 12, to: 60), [])
    }

    /// The menu (or a guest dialog, or the background) pauses the game's threads: its time does
    /// not count, and the window resumes where it stopped.
    func testPausedTimeDoesNotCount() {
        var s = LayoutSuggestion(offered: false)
        XCTAssertEqual(run(&s, from: 0, to: 10), [])
        XCTAssertEqual(run(&s, from: 11, to: 100, running: false), [])
        XCTAssertEqual(run(&s, from: 101, to: 130), [111])
    }

    /// Hidden controls (a controller is connected) pause it as well: there is nothing to replace.
    func testHiddenControlsPauseIt() {
        var s = LayoutSuggestion(offered: false)
        let hidden = ControlsState(layout: .gamepad, visible: false, opacity: 0.6, padConnected: false)
        XCTAssertEqual(run(&s, from: 0, to: 15), [])
        XCTAssertEqual(run(&s, from: 16, to: 60, state: hidden), [])
        XCTAssertEqual(run(&s, from: 61, to: 70), [66])
    }

    /// A long gap between two samples (the app was suspended) counts as one step at most.
    func testAGapBetweenSamplesCountsAtMostOneStep() {
        var s = LayoutSuggestion(offered: false)
        XCTAssertFalse(s.sample(at: 0, reads: 0, running: true, state: gamepad, chosen: false))
        XCTAssertFalse(s.sample(at: 300, reads: 0, running: true, state: gamepad, chosen: false))
        XCTAssertEqual(s.played, LayoutSuggestion.maxStep)
    }

    /// Only a game on Gamepad that nobody chose it for: another layout (the person's, a
    /// compatibility default's, Off) or the person's own Gamepad ends it.
    func testOnlyAStartingGamepadIsReplaced() {
        for state in [ControlsState(layout: .keyboardMouse, visible: true, opacity: 0.6),
                      ControlsState(layout: .off, visible: false, opacity: 0.6)] {
            var s = LayoutSuggestion(offered: false)
            XCTAssertEqual(run(&s, from: 0, to: 60, state: state), [])
            XCTAssertTrue(s.done)
        }
        var mine = LayoutSuggestion(offered: false)
        XCTAssertEqual(run(&mine, from: 0, to: 60, chosen: true), [])
        // Switching away mid-window ends it too, even if the game comes back to Gamepad.
        var switched = LayoutSuggestion(offered: false)
        XCTAssertEqual(run(&switched, from: 0, to: 10), [])
        XCTAssertEqual(run(&switched, from: 11, to: 11, state: ControlsState(layout: .pointClick, visible: true, opacity: 0.6)), [])
        XCTAssertEqual(run(&switched, from: 12, to: 60), [])
    }

    /// A layout someone chose: the game's own, or Settings' Starting layout (Gamepad too); only a
    /// game following "Suggested for the game" is open to the offer.
    func testALayoutChosenInSettingsOrForTheGameIsNotReplaced() {
        XCTAssertFalse(LayoutSuggestion.chosen(nil, defaults: ControlsDefaults()))
        XCTAssertFalse(LayoutSuggestion.chosen(GameControls(opacity: 0.5), defaults: ControlsDefaults()))
        XCTAssertTrue(LayoutSuggestion.chosen(GameControls(layout: .gamepad), defaults: ControlsDefaults()))
        XCTAssertTrue(LayoutSuggestion.chosen(nil, defaults: ControlsDefaults(startingLayout: .gamepad)))
        var s = LayoutSuggestion(offered: false)
        XCTAssertEqual(run(&s, from: 0, to: 60, chosen: LayoutSuggestion.chosen(nil, defaults: ControlsDefaults(startingLayout: .gamepad))),
                       [])
    }

    func testAGameOfferedBeforeIsNotOfferedAgain() {
        var s = LayoutSuggestion(offered: true)
        XCTAssertEqual(run(&s, from: 0, to: 60), [])
    }

    /// The app restarts after each game (decision 0029): the games already offered are kept in
    /// UserDefaults by catalogue id.
    func testOfferedGamesAreKeptByID() {
        let d = UserDefaults(suiteName: "LayoutSuggestionTests")!
        d.removeObject(forKey: LayoutSuggestion.offeredKey)
        XCTAssertFalse(LayoutSuggestion.offered("app-1", in: d))
        LayoutSuggestion.markOffered("app-1", in: d)
        LayoutSuggestion.markOffered("app-1", in: d)
        LayoutSuggestion.markOffered("epic-Buffalo", in: d)
        XCTAssertTrue(LayoutSuggestion.offered("app-1", in: d))
        XCTAssertTrue(LayoutSuggestion.offered("epic-Buffalo", in: d))
        XCTAssertFalse(LayoutSuggestion.offered("epic-buffalo", in: d))
        XCTAssertEqual(d.stringArray(forKey: LayoutSuggestion.offeredKey), ["app-1", "epic-Buffalo"])
        // The driver's set:controls.suggestedLayoutOffered= stores "": no game offered, and offering starts again.
        d.set("", forKey: LayoutSuggestion.offeredKey)
        XCTAssertFalse(LayoutSuggestion.offered("app-1", in: d))
        LayoutSuggestion.markOffered("app-1", in: d)
        XCTAssertEqual(d.stringArray(forKey: LayoutSuggestion.offeredKey), ["app-1"])
        d.removeObject(forKey: LayoutSuggestion.offeredKey)
    }

    /// Accepting saves Keyboard & mouse as the game's own layout, keeping the rest of its record.
    func testAcceptingSavesKeyboardAndMouseForTheGame() {
        XCTAssertEqual(LayoutSuggestion.accepted(nil), GameControls(layout: .keyboardMouse))
        XCTAssertEqual(LayoutSuggestion.accepted(GameControls(opacity: 0.9, lookSpeed: 1.5)),
                       GameControls(layout: .keyboardMouse, opacity: 0.9, lookSpeed: 1.5))
    }
}
