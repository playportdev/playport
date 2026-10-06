// SPDX-License-Identifier: GPL-3.0-or-later
// First run (Setup.dc.html): what a game needs from this phone, as four
// steps: the pairing JIT uses (on iOS 27 made on the phone, decision 0033;
// on iOS 26 a file chosen from Files), LocalDevVPN's tunnel, the Increased
// Memory Limit entitlement in the signature (a signer chose it, so a player
// may only be able to put it off with "Not now"; docs/DISTRIBUTION.md
// section 6), and Steam (optional: signed in, or "Not now"). The app shows them once, on a first
// run, which cannot be left until every step is settled (`complete`), and in
// Settings › Setup check; the same facts are checked by themselves before
// every launch (`beforeLaunch`), which names the fix when one fails. A
// controller is no step: a launch only notes its absence (`notes`).
//
// The app reads the facts (UI/SetupView.swift); this is what they mean.

import Foundation

public enum SetupStep: String, CaseIterable, Sendable {
    case pairing, vpn, memory, steam
}

/// What the app reads from the phone for the checks.
public struct SetupFacts: Equatable, Sendable {
    /// The controller connected, by name; nil for none.
    public var controller: String?
    /// A pairing is stored (the Keychain).
    public var pairing: Bool
    /// The pairing is made on this phone (iOS 27); else it is a file from Files.
    public var pairsOnPhone: Bool
    /// LocalDevVPN's tunnel is up; nil before the first read.
    public var tunnelUp: Bool?
    /// Paired with Steam; nil while the stored session is still being read.
    public var steamSignedIn: Bool?
    /// The player chose "Not now" on the Steam step.
    public var steamSkipped: Bool
    /// The signature carries Increased Memory Limit; nil when it cannot be read.
    public var memoryEntitled: Bool?
    /// The player chose "Not now" on the Memory step.
    public var memorySkipped: Bool

    public init(controller: String? = nil, pairing: Bool = false, pairsOnPhone: Bool = true,
                tunnelUp: Bool? = nil, steamSignedIn: Bool? = false, steamSkipped: Bool = false,
                memoryEntitled: Bool? = nil, memorySkipped: Bool = false) {
        self.controller = controller
        self.pairing = pairing
        self.pairsOnPhone = pairsOnPhone
        self.tunnelUp = tunnelUp
        self.steamSignedIn = steamSignedIn
        self.steamSkipped = steamSkipped
        self.memoryEntitled = memoryEntitled
        self.memorySkipped = memorySkipped
    }
}

/// One step's card: done or not, its text, and what A does on it (nil: nothing to do).
public struct SetupItem: Equatable, Sendable {
    public let step: SetupStep
    public let done: Bool
    public let title: String
    public let detail: String
    public let action: String?
}

public enum SetupChecklist {
    public static func item(_ step: SetupStep, _ f: SetupFacts) -> SetupItem {
        switch step {
        case .pairing:
            if f.pairsOnPhone {
                return SetupItem(step: step, done: f.pairing, title: "Pairing",
                                 detail: f.pairing ? "This iPhone is paired with itself, so games run fast."
                                     : "Lets Playport run games fast. Made on this iPhone; iOS asks you to approve it.",
                                 action: f.pairing ? "Pair again" : "Pair this iPhone")
            }
            return SetupItem(step: step, done: f.pairing, title: "Pairing file",
                             detail: f.pairing ? "Imported, so games run fast."
                                 : "Lets Playport run games fast. Made once on a computer; pick it from Files.",
                             action: f.pairing ? "Choose another file" : "Choose file")
        case .vpn:
            let up = f.tunnelUp == true
            return SetupItem(step: step, done: up, title: "LocalDevVPN",
                             detail: up ? "Connected. Keep it on while you play."
                                 : f.tunnelUp == nil ? "Checking…" : "Install it and turn it on. Keep it on while you play.",
                             action: up ? nil : "Turn it on")
        case .memory:
            let on = f.memoryEntitled == true
            let detail: String
            if on {
                detail = "Increased Memory Limit is on: games get all the memory this iPhone gives."
            } else if f.memorySkipped {
                detail = "Not now. Smaller games play; bigger ones need Increased Memory Limit."
            } else if f.memoryEntitled == nil {
                detail = "Playport could not read its signature. Bigger games need Increased Memory Limit."
            } else {
                detail = "This copy was signed without Increased Memory Limit, so bigger games will not start."
            }
            return SetupItem(step: step, done: on || f.memorySkipped, title: "Memory", detail: detail,
                             action: on ? nil : "How to fix")
        case .steam:
            let done = f.steamSignedIn == true
            return SetupItem(step: step, done: done || f.steamSkipped, title: "Steam",
                             detail: done ? "Signed in: your library, cloud saves and achievements."
                                 : f.steamSkipped ? "Not now. Sign in any time for your library, cloud saves and achievements."
                                 : "Optional. Sign in for your library, cloud saves and achievements.",
                             action: done ? nil : "Sign in")
        }
    }

    public static func items(_ f: SetupFacts) -> [SetupItem] { SetupStep.allCases.map { item($0, f) } }

    /// Where the ring starts: the first step not done, else the first.
    public static func firstTodo(_ f: SetupFacts) -> SetupStep {
        items(f).first { !$0.done }?.step ?? .pairing
    }

    /// Every step settled: the pairing and LocalDevVPN done, Increased Memory
    /// Limit on or put off, Steam signed in or put off ("Not now"). A first
    /// run's checklist cannot be left before this.
    public static func complete(_ f: SetupFacts) -> Bool {
        f.pairing && f.tunnelUp == true && (f.memoryEntitled == true || f.memorySkipped)
            && (f.steamSignedIn == true || f.steamSkipped)
    }

    /// Later visits can always leave; a first run must settle every step first.
    public static func canLeave(_ f: SetupFacts, firstRun: Bool) -> Bool {
        !firstRun || complete(f)
    }

    /// Whether a step offers "Not now": on a first run, the Memory step while the
    /// entitlement is not on, the Steam step while signed out, and neither once put off.
    public static func offersNotNow(_ step: SetupStep, _ f: SetupFacts, firstRun: Bool) -> Bool {
        guard firstRun else { return false }
        switch step {
        case .memory: return f.memoryEntitled != true && !f.memorySkipped
        case .steam: return f.steamSignedIn != true && !f.steamSkipped
        case .pairing, .vpn: return false
        }
    }

    /// Steps done, for Settings' summary ("2 of 4 done").
    public static func doneCount(_ f: SetupFacts) -> Int { items(f).filter(\.done).count }

    /// Start on an unpaired phone, and resume an unfinished first run even if
    /// pairing was completed before the app closed. Already-paired phones that
    /// never started this flow keep their existing setup.
    public static func showsAtStart(left: Bool, pairing: Bool, started: Bool = false) -> Bool {
        !left && (started || !pairing)
    }

    /// What the check before a launch finds.
    public enum LaunchCheck: Equatable, Sendable {
        /// Everything a game needs is there.
        case go
        /// Playport fixes it itself: pairs this iPhone (iOS 27) or turns
        /// LocalDevVPN on, then goes on with the Play (JitSetup).
        case fixesItself(SetupStep)
        /// The player has to act first: the checklist on that step, with the fix.
        case needs(SetupStep, String)
    }

    /// The check a Play runs before JIT: the pairing, then LocalDevVPN. A
    /// controller and Steam never stop a launch; `notes` names them.
    public static func beforeLaunch(_ f: SetupFacts) -> LaunchCheck {
        if !f.pairing {
            return f.pairsOnPhone ? .fixesItself(.pairing)
                : .needs(.pairing, "Playport needs a pairing file to run games. Choose it from Files on the Pairing file step.")
        }
        if f.tunnelUp != true { return .fixesItself(.vpn) }
        return .go
    }

    /// The launch screen drops it once a controller connects.
    public static let noController = "No controller connected. Connect one now to play with it."

    /// What does not stop a launch but is worth saying on its launch screen.
    public static func notes(_ f: SetupFacts, steamGame: Bool) -> [String] {
        var n: [String] = []
        if f.controller == nil { n.append(noController) }
        if steamGame, f.steamSignedIn == false { n.append("Steam is signed out: cloud saves and achievements wait until you sign in.") }
        return n
    }

    /// The check as one log line (`setup: before play …`).
    public static func summary(_ f: SetupFacts) -> String {
        "controller=\(f.controller ?? "none") pairing=\(f.pairing ? (f.pairsOnPhone ? "on-phone" : "file") : "missing")"
            + " vpn=\(f.tunnelUp.map { $0 ? "up" : "down" } ?? "unknown")"
            + " memory=\(f.memoryEntitled.map { $0 ? "on" : "off" } ?? "unknown")"
            + (f.memorySkipped ? " (not now)" : "")
            + " steam=\(f.steamSignedIn.map { $0 ? "signed-in" : "signed-out" } ?? "unknown")"
            + (f.steamSkipped ? " (not now)" : "")
    }
}
