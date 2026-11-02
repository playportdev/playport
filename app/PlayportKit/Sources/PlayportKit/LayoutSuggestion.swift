// SPDX-License-Identifier: GPL-3.0-or-later
// The suggested starting layout's run-time half (PLA-13,
// phase 4 item 3; the table half is CompatDefaults' `controls`). A game on the Gamepad layout
// that has asked for no XInput state within 20 s of play after its first frame most likely
// reads only a keyboard and mouse: a toast offers Keyboard & mouse, and accepting saves it as
// the game's own layout.
//
// - The count is every XInput state read the game made (HostIO's host_pad_state_reads, from
//   win32u's ios_gamepad_query through patches/madeira-unix), from the process's start: the app
//   restarts after each game (decision 0029), so it is this game's. One read ends it, no offer.
// - Only play counts: from the first frame, while the game runs (not paused by the in-game menu,
//   a guest dialog or the background) and the controls are shown (a controller hides them;
//   then there is nothing to replace). A gap between two samples counts as `maxStep` at most.
// - Only a starting Gamepad nobody chose: the game's own layout (Gamepad too), Settings'
//   Starting layout (Gamepad too; only "Suggested for the game" is open to the offer, `chosen`)
//   or any other layout (a compatibility default's, Off) ends it, as does a change of layout
//   mid-window.
// - Once per game, kept in UserDefaults by catalogue id (`offeredKey`), marked when offered:
//   a game the person turned down is not asked again.

import Foundation

public struct LayoutSuggestion: Equatable, Sendable {
    /// Play after the first frame with no state read before the offer.
    public static let window: TimeInterval = 20
    /// The most one interval between samples counts (the app samples about once a second).
    public static let maxStep: TimeInterval = 2
    /// The catalogue ids already offered, a string array.
    public static let offeredKey = "controls.suggestedLayoutOffered"
    /// What the offer sets.
    public static let layout = OnScreenLayout.keyboardMouse

    /// Nothing more to decide: offered, or ruled out.
    public private(set) var done: Bool
    /// Play counted so far.
    public private(set) var played: TimeInterval = 0
    private var last: TimeInterval?

    /// `offered`: the game was offered before (`offered(_:in:)`).
    public init(offered: Bool) { done = offered }

    /// One sample, at `now` (any monotonic seconds). `reads`: the game's XInput state reads so
    /// far; `running`: the first frame is shown and the game is not paused; `state`: its controls
    /// now; `chosen`: someone chose the layout (`chosen(_:defaults:)`). True once, when the offer is due.
    public mutating func sample(at now: TimeInterval, reads: UInt64, running: Bool, state: ControlsState,
                                chosen: Bool) -> Bool {
        guard !done else { return false }
        if reads > 0 || chosen || state.layout != .gamepad {
            done = true
            return false
        }
        let counting = running && state.visible
        if counting, let last { played += min(max(now - last, 0), Self.maxStep) }
        last = counting ? now : nil
        guard played >= Self.window else { return false }
        done = true
        return true
    }

    /// The layout is someone's choice: the game's own, or Settings' Starting layout rather than
    /// "Suggested for the game".
    public static func chosen(_ game: GameControls?, defaults: ControlsDefaults) -> Bool {
        game?.layout != nil || defaults.startingLayout != nil
    }

    public static func offered(_ id: String, in defaults: UserDefaults) -> Bool {
        defaults.stringArray(forKey: offeredKey)?.contains(id) ?? false
    }

    public static func markOffered(_ id: String, in defaults: UserDefaults) {
        let ids = defaults.stringArray(forKey: offeredKey) ?? []
        if !ids.contains(id) { defaults.set(ids + [id], forKey: offeredKey) }
    }

    /// The game's record with the offer accepted.
    public static func accepted(_ game: GameControls?) -> GameControls {
        var c = game ?? GameControls()
        c.layout = layout
        return c
    }
}
