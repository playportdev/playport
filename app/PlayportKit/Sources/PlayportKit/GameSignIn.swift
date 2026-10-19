// SPDX-License-Identifier: GPL-3.0-or-later
// A game's own sign-in through the publisher launcher its Play starts (decision 0124): the line
// the game writes to its log once it has signed in. RDR2 logs `Signed in online to profile …` to
// its Social Club log (UTF-16LE, `[<ms since start>] text` lines under a `[00000000] <start time>`
// header) each time it signs in. At this Play's first such line LaunchCoordinator ends the
// launcher (decision 0130, amending 0125; LauncherEndTrigger). Only the fixed text is matched; the
// rest of the line (the profile) is never read out, logged or kept.

import Foundation

public struct GameSignIn: Equatable, Sendable {
    /// The game's log, relative to the prefix user's profile folder (`drive_c/users/<user>`).
    public let log: String
    /// The text a line starts with, after its `[…] ` stamp, once the game has signed in.
    public let line: String

    public init(log: String, line: String) {
        self.log = log
        self.line = line
    }

    /// The log's file under `profile` (the prefix's `drive_c/users/<user>`).
    public func file(profile: URL) -> URL {
        log.split(separator: "/").reduce(profile) { $0.appendingPathComponent(String($1)) }
    }

    /// Watches one Play's log. `baseline` is the file as the Play started (nil when there was
    /// none): what it already held is an earlier start's. A file that starts otherwise was
    /// written anew (a new header line) and is all this Play's; one that starts with the
    /// baseline counts only what was appended after it.
    public struct Watch: Sendable {
        public let signIn: GameSignIn
        public let baseline: Data?

        public init(signIn: GameSignIn, baseline: Data?) {
            self.signIn = signIn
            self.baseline = baseline
        }

        /// Whether the log as read now holds the sign-in line written in this Play.
        public func signedIn(_ data: Data) -> Bool {
            var fresh = data
            if let baseline, data.count >= baseline.count, data.prefix(baseline.count) == baseline {
                // From the character the baseline ended in: one it held half of is read whole.
                fresh = data.dropFirst(baseline.count & ~1)
            }
            guard !fresh.isEmpty else { return false }
            // UTF-16LE: an odd byte left at the end is the start of a character still being written.
            let bytes = [UInt8](fresh.prefix(fresh.count & ~1))
            let units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
            let text = String(decoding: units, as: UTF16.self)
            for line in text.split(whereSeparator: { $0.isNewline }) {
                var rest = line.drop { $0 == "\u{FEFF}" }
                if rest.first == "[", let close = rest.firstIndex(of: "]") {
                    rest = rest[rest.index(after: close)...].drop { $0 == " " }
                }
                if rest.hasPrefix(signIn.line) { return true }
            }
            return false
        }
    }
}
