// SPDX-License-Identifier: GPL-3.0-or-later
/// What the controller does around Playport's in-game menu (QuickMenu.dc.html,
/// S1Probe's UI/InGameMenuView.swift): the Home button held opens it, and
/// while it is up the pad's presses are the menu's and the guest's pads are at rest.
public enum QuickMenuEvent: Equatable, Sendable {
    /// Home was held `longPress` seconds: open the menu.
    case open
    /// Home pressed while the menu is up: back to the game.
    case close
    /// A press for the menu (PadNavigation: a button as it goes down, a held direction repeating).
    case press(NavButton)
}

/// The Home button and the menu's presses, from every pad's snapshots.
///
/// - Closed: Home going down starts the hold; still down `longPress` seconds
///   later (`update` or `tick`) is `.open`. A shorter press does nothing.
/// - Open: the snapshot that opened it counts as held, so the buttons already
///   down are not presses; after it, each press is `.press`, and Home going
///   down again is `.close`. The hold that opened the menu does not close it
///   when it is let go.
/// - `closed()`: the UI closed the menu (Resume, B); the next Home press starts a new hold.
public struct QuickMenuControl: Sendable {
    public var longPress = 0.5
    public private(set) var isOpen = false
    private var homeDownAt: Double?
    private var homeHeld = false
    private var nav = PadNavigation()

    public init() {}

    public mutating func update(_ p: PadInput, at t: Double) -> [QuickMenuEvent] {
        let wentDown = p.home && !homeHeld
        homeHeld = p.home
        if isOpen {
            if wentDown {
                isOpen = false
                nav.reset()
                return [.close]
            }
            var q = p
            q.home = false
            return nav.update(q, at: t).map { .press($0) }
        }
        if wentDown { homeDownAt = t }
        if !p.home { homeDownAt = nil }
        return due(p, at: t)
    }

    /// Between snapshots: the long press coming due, and the menu's held direction repeating.
    public mutating func tick(at t: Double) -> [QuickMenuEvent] {
        if isOpen { return nav.tick(at: t).map { .press($0) } }
        guard homeHeld else { return [] }
        var p = PadInput()
        p.home = true
        return due(p, at: t)
    }

    /// Whether the caller should keep calling `tick`: Home is held toward a
    /// long press, or a direction repeats in the menu.
    public var needsClock: Bool { isOpen ? nav.isRepeating : homeDownAt != nil }

    /// The menu was closed from the UI.
    public mutating func closed() {
        isOpen = false
        homeDownAt = nil
        nav.reset()
    }

    private mutating func due(_ p: PadInput, at t: Double) -> [QuickMenuEvent] {
        guard let d = homeDownAt, t - d >= longPress else { return [] }
        homeDownAt = nil
        isOpen = true
        nav.reset()
        var q = p
        q.home = false
        _ = nav.update(q, at: t)   // what is held now is not a press
        return [.open]
    }
}

/// What the guest's four XInput slots get while the menu comes and goes.
/// Every pad source (GameController pads, the scripted pad) passes its values
/// through here, under one lock, on its own thread.
///
/// - Held (the menu is up): nothing reaches the guest; `hold` puts every
///   slot that had values at rest once.
/// - Released: each slot gets its last values again, except the buttons that
///   are still down from the menu (the A that chose Resume): those stay up
///   for the guest until they are let go, so the game does not see a press
///   the player made in the menu.
public struct GuestPadGate: Sendable {
    public private(set) var held = false
    private var last: [PadValues?] = [nil, nil, nil, nil]
    private var mask: [UInt16] = [0, 0, 0, 0]

    public init() {}

    /// A pad's new values: what its slot gets now, nil for nothing.
    public mutating func input(slot: Int, _ v: PadValues) -> PadValues? {
        guard last.indices.contains(slot) else { return nil }
        last[slot] = v
        if held { return nil }
        return filtered(slot, v)
    }

    /// The menu opens: the slots to put at rest.
    public mutating func hold() -> [Int] {
        guard !held else { return [] }
        held = true
        return last.indices.filter { last[$0] != nil }
    }

    /// The menu closes: each slot's values for the guest now.
    public mutating func release() -> [(slot: Int, values: PadValues)] {
        guard held else { return [] }
        held = false
        return last.indices.compactMap { s in
            guard let v = last[s] else { return nil }
            mask[s] = v.buttons
            return (s, filtered(s, v))
        }
    }

    /// A pad gave up its slot.
    public mutating func disconnect(slot: Int) {
        guard last.indices.contains(slot) else { return }
        last[slot] = nil
        mask[slot] = 0
    }

    private mutating func filtered(_ s: Int, _ v: PadValues) -> PadValues {
        mask[s] &= v.buttons   // a masked button let go is the game's again
        var out = v
        out.buttons &= ~mask[s]
        return out
    }
}
