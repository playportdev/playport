// SPDX-License-Identifier: GPL-3.0-or-later
// Play time: each game's total, the sum of its sessions, kept in the
// catalogue beside `lastPlayed` (InstalledTitle.playSeconds; Home's
// "Played 2 h ago · 14 h total", the game page's Play time).
//
// A session runs from Play to the game's end. Playport restarts itself after
// every game (decision 0029), and a process can also die with the game (a
// crash, the system, `pp ui` ending the app), so the session does not wait
// for its end to be counted: the app keeps it in a file
// (Library/Application Support/Playport/session.json, PlaySessionStore) and
// beats it every few seconds while the game runs. A clean end adds it to the
// catalogue at once; a session still on disk when a process starts is one
// whose process ended first, and is added then, up to its last beat.
//
// A beat counts the time since the one before, but never more than `maxGap`:
// a process the system suspended (the app in the background) does not beat,
// and that time is not play.

import Foundation

public struct PlaySession: Codable, Equatable, Sendable {
    /// The catalogue's title (`app-367520`).
    public var titleID: String
    public var started: Date
    public var lastBeat: Date
    /// Played so far, up to `lastBeat`.
    public var seconds: TimeInterval

    /// The most one beat counts: a few beats' interval.
    public static let maxGap: TimeInterval = 15

    public init(titleID: String, now: Date = Date()) {
        self.titleID = titleID
        started = now
        lastBeat = now
        seconds = 0
    }

    /// Counts the time since the last beat, capped at `maxGap`; a clock that went back counts nothing.
    public mutating func beat(now: Date = Date()) {
        let gap = now.timeIntervalSince(lastBeat)
        guard gap > 0 else { return }
        seconds += min(gap, Self.maxGap)
        lastBeat = now
    }
}

/// The running session on disk; nil when none runs or the file is unreadable.
public struct PlaySessionStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> PlaySession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? CatalogStore.decoder.decode(PlaySession.self, from: data)
    }

    public func save(_ s: PlaySession) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CatalogStore.encoder.encode(s).write(to: url, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

extension Catalog {
    /// Adds a session to its title's play time. False when the title is no longer catalogued.
    @discardableResult
    public mutating func addPlayTime(_ s: PlaySession) -> Bool {
        guard title(id: s.titleID) != nil else { return false }
        update(s.titleID) { $0.playSeconds = ($0.playSeconds ?? 0) + max(0, s.seconds) }
        return true
    }
}

public enum PlayTime {
    /// `14 h`, `2 h 5 min`, `25 min`, `less than a minute`: whole minutes up to ten hours, then hours.
    public static func format(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "less than a minute" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return h >= 10 || m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
