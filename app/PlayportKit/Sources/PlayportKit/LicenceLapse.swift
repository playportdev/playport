// SPDX-License-Identifier: GPL-3.0-or-later
// A copy's licence lapse (GLOSSARY "Licence"; an Xbox copy's, PLA-505, decision 0166):
// once the store definitively refuses a copy's licence (a Game Pass subscription ended,
// the title left Game Pass), the copy can't be played and its removal falls due a grace
// period after that first refusal. A licence granted again cancels the lapse. Only a
// verdict counts: a network or service problem, or a refusal of the device rather than the
// copy, neither starts nor cancels one. A removal that has fallen due waits while the
// copy has saves not yet in the cloud (or the app can't tell), and the player may remove
// the copy at any time. The removal keeps the saves; the app does it (Dev/XboxLapse.swift).
//
// The ledger is pure: callers pass the time and the saves' answer. It is kept in the
// state root (`lapses.json`) by title ID.

import Foundation
import SteamClientKit

/// What a licence check says about the copy itself.
public enum LicenceVerdict: Sendable, Equatable {
    /// The store granted the licence.
    case granted
    /// The store definitively refused this copy's licence.
    case refused
    /// No verdict on the copy: no connection, the service failing, a refusal of the device.
    case noVerdict
}

/// Whether a copy has saves not yet in the cloud; nil when that can't be told.
public protocol UnsyncedSaves {
    func unsynced(_ key: StoreGameKey) -> Bool?
}

/// No way to tell (no cloud saves for the store yet): every removal waits.
public struct UnknownSaves: UnsyncedSaves {
    public init() {}
    public func unsynced(_ key: StoreGameKey) -> Bool? { nil }
}

/// One copy's lapse: when the store first refused its licence.
public struct LicenceLapse: Codable, Equatable, Sendable {
    public var refusedAt: Date
    /// When its removal falls due.
    public var removeAt: Date { refusedAt.addingTimeInterval(LicenceLapses.grace) }
}

public struct LicenceLapses: Codable, Equatable, Sendable {
    /// From the first definitive refusal to the removal.
    public static let grace: TimeInterval = 7 * 86_400

    public enum State: Equatable, Sendable {
        case licensed
        /// Refused; removed at `removeAt` unless the licence returns.
        case lapsed(removeAt: Date)
        /// Past `removeAt`, waiting for the copy's saves to reach the cloud.
        case held(removeAt: Date)
        /// Past the grace, nothing holding it: remove the copy.
        case due

        /// Not playable: any state but licensed.
        public var isLapsed: Bool { self != .licensed }
    }

    /// By title ID (StoreGameKey.titleID).
    private var lapses: [String: LicenceLapse] = [:]

    public init() {}

    public func lapse(_ key: StoreGameKey) -> LicenceLapse? { lapses[key.titleID] }

    /// A licence check's verdict for `key` at `now`; true when the ledger changed. A
    /// refusal starts a lapse only if none is running (the first refusal's date stands).
    @discardableResult
    public mutating func record(_ verdict: LicenceVerdict, for key: StoreGameKey, at now: Date) -> Bool {
        switch verdict {
        case .noVerdict: return false
        case .granted: return lapses.removeValue(forKey: key.titleID) != nil
        case .refused:
            guard lapses[key.titleID] == nil else { return false }
            lapses[key.titleID] = LicenceLapse(refusedAt: now)
            return true
        }
    }

    public func state(_ key: StoreGameKey, at now: Date, saves: UnsyncedSaves) -> State {
        guard let lapse = lapses[key.titleID] else { return .licensed }
        if now < lapse.removeAt { return .lapsed(removeAt: lapse.removeAt) }
        // Unknown counts as unsynced: no removal on a guess.
        return saves.unsynced(key) == false ? .due : .held(removeAt: lapse.removeAt)
    }

    /// The copies to remove now, by title ID.
    public func due(at now: Date, saves: UnsyncedSaves) -> [StoreGameKey] {
        lapses.keys.sorted().compactMap(StoreGameKey.init(titleID:)).filter { state($0, at: now, saves: saves) == .due }
    }

    /// The copy was removed (when due, or earlier by the player); true if it had a lapse.
    @discardableResult
    public mutating func removed(_ key: StoreGameKey) -> Bool { lapses.removeValue(forKey: key.titleID) != nil }

    /// Drops the lapses of copies not in `installed`; true when one went.
    @discardableResult
    public mutating func keep(only installed: Set<StoreGameKey>) -> Bool {
        let titles = Set(installed.map(\.titleID))
        let before = lapses.count
        lapses = lapses.filter { titles.contains($0.key) }
        return lapses.count != before
    }

    /// The ledger in `file`; empty when there is none or it can't be read (nothing is removed on a guess).
    public static func load(_ file: URL) -> LicenceLapses {
        guard let data = try? Data(contentsOf: file) else { return LicenceLapses() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LicenceLapses.self, from: data)) ?? LicenceLapses()
    }

    public func save(_ file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}
