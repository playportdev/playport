// SPDX-License-Identifier: GPL-3.0-or-later
// After Playport ends the game's own Social Club (decisions 0133, 0141, 0153), RDR2 sometimes
// takes it for a sign-out: it signs in again at once and starts a reload that needs the helper,
// which ntdll refuses (decision 0138), and sits on its own loading screen (4 of 9 runs, PLA-413).
// Decision 0155: the app watches for that re-sign-in after each end and then allows the
// helper's restarts until the new sign-in is done, at most `maxAllows` times a Play; 0141's
// end may then run again `LauncherEndTrigger.gameSocialClubAfterSignInS` after it.
//
// Two detectors, the first that fires wins:
// - socialclub.log: a sign-in line (GameSignIn.Watch.signIns) beyond those it held at the end;
// - steam-language: `languageBurst` or more ISteamApps GetCurrentGameLanguage calls within
//   `languageWindowS` of the end (a dev build's steamclient trace summaries, `languageCalls`).
//   The game makes that burst as it signs in; in runs x8, qp1, qe2c and xs1 it came 21-32 s
//   after the end, and in no run that played on (qd1b, qe4, qe2d, g1, n2) within 60 s of it.
// Once allowed, the allow lasts until a sign-in line beyond those the log held at the allow,
// or `allowCapS`, whichever comes first. The steps are pure; LaunchCoordinator.LauncherEnd
// sends the session root its ALLOW and calls ntdll's allow (wine_host_game_sc_allow_restarts).

import Foundation

public struct GameSocialClubReSignIn: Equatable, Sendable {
    public enum Detector: String, Equatable, Sendable {
        case socialClubLog = "socialclub.log"
        case steamLanguage = "steam-language"
    }

    /// What the app does after a slice.
    public enum Step: Equatable, Sendable {
        /// Allow the restarts: the root's ALLOW first, then ntdll's.
        case allow(Detector)
        /// A re-sign-in after the last allow: restarts stay refused.
        case noAllowLeft(Detector)
        /// Refuse restarts again: at a new sign-in line (`signedIn`), or at the cap.
        case refuseAgain(signedIn: Bool)
    }

    public enum Phase: Equatable, Sendable {
        /// The game's Social Club has not been ended yet.
        case beforeEnd
        /// Ended at `at`, the log holding `signIns` sign-in lines; `languageCalls` since.
        case ended(at: Double, signIns: Int, languageCalls: Int)
        /// Restarts allowed since `at`, the log holding `signIns`; `signedInAt` the re-sign-in's
        /// line, when one came.
        case allowed(at: Double, signIns: Int, signedInAt: Double?)
        /// Restarts refused again; the game signed in again at `at`, so the end may run again
        /// 0141's 120 s after it.
        case reSignedIn(at: Double)
        /// Nothing more this Play: no allow left, or the root did not allow.
        case finished
    }

    /// Allows a Play, the session root's PP_GAME_SC_MAX_ALLOWS.
    public static let maxAllows = 2
    /// GetCurrentGameLanguage calls after the end that mean a re-sign-in.
    public static let languageBurst = 4
    /// How long after the end the burst counts.
    public static let languageWindowS: Double = 60
    /// The longest an allow lasts without a new sign-in line.
    public static let allowCapS: Double = 90

    public private(set) var phase: Phase = .beforeEnd
    public private(set) var allows = 0

    public init() {}

    /// The end was sent at `elapsed`, the log holding `signIns` sign-in lines. Whether it was a
    /// re-end, after a re-sign-in.
    @discardableResult
    public mutating func ended(at elapsed: Double, signIns: Int) -> Bool {
        let reEnd: Bool
        if case .reSignedIn = phase { reEnd = true } else { reEnd = false }
        phase = .ended(at: elapsed, signIns: signIns, languageCalls: 0)
        return reEnd
    }

    /// The root did not stop its sweep: restarts stay refused for the rest of the Play.
    public mutating func allowFailed() { phase = .finished }

    /// Whether the slices read the game's log for this: from the end until nothing more can come.
    public var watching: Bool {
        switch phase {
        case .beforeEnd, .finished: return false
        case .ended, .allowed, .reSignedIn: return true
        }
    }

    /// The sign-in 0141's 120 s count from for an end again: set once restarts are refused
    /// again after a re-sign-in.
    public var reEndSignInAt: Double? {
        if case let .reSignedIn(at) = phase { return at }
        return nil
    }

    /// One slice after the end: `signIns` the log's sign-in lines now, `languageCalls` the
    /// GetCurrentGameLanguage calls since the last slice.
    public mutating func slice(at elapsed: Double, signIns: Int, languageCalls: Int) -> Step? {
        switch phase {
        case .beforeEnd, .finished:
            return nil
        case let .ended(at, endSignIns, calls):
            let detector: Detector
            if signIns > endSignIns {
                detector = .socialClubLog
            } else if elapsed - at <= Self.languageWindowS {
                let total = calls + languageCalls
                phase = .ended(at: at, signIns: endSignIns, languageCalls: total)
                guard total >= Self.languageBurst else { return nil }
                detector = .steamLanguage
            } else {
                return nil
            }
            guard allows < Self.maxAllows else {
                phase = .finished
                return .noAllowLeft(detector)
            }
            allows += 1
            phase = .allowed(at: elapsed, signIns: signIns, signedInAt: detector == .socialClubLog ? elapsed : nil)
            return .allow(detector)
        case let .allowed(at, allowSignIns, signedInAt):
            if signIns > allowSignIns {
                phase = .reSignedIn(at: elapsed)
                return .refuseAgain(signedIn: true)
            }
            if elapsed - at >= Self.allowCapS {
                phase = .reSignedIn(at: signedInAt ?? at)
                return .refuseAgain(signedIn: false)
            }
            return nil
        case .reSignedIn:
            return nil
        }
    }

    /// The GetCurrentGameLanguage calls a steamclient trace line counts: the sum of its
    /// `<interface>.GetCurrentGameLanguagex<N>` entries when it is a summary, else 0 (a call's
    /// own line is in the next summary too).
    public static func languageCalls(inTraceLine line: String) -> Int {
        guard line.hasPrefix("trace +"), line.contains(" summary") else { return 0 }
        var total = 0
        for word in line.split(separator: " ") {
            guard let dot = word.firstIndex(of: "."),
                  word[word.index(after: dot)...].hasPrefix("GetCurrentGameLanguagex") else { continue }
            let count = word[word.index(after: dot)...].dropFirst("GetCurrentGameLanguagex".count)
            total += Int(count) ?? 0
        }
        return total
    }
}
