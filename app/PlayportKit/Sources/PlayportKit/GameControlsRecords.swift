// SPDX-License-Identifier: GPL-3.0-or-later
// Every game's own controls as S1Probe's ControlsStore keeps them under one
// UserDefaults key (`controls.games`): a JSON object, catalogue id to
// GameControls. Each record is read on its own: one this build cannot read (a
// later build's layout, a hand-written typo) is kept as its JSON and written
// back as it came, so it never costs the other games theirs.

import Foundation

public struct GameControlsRecords: Equatable, Sendable {
    /// The records this build reads, by catalogue id.
    public private(set) var games: [String: GameControls] = [:]
    /// The records it cannot read, by catalogue id: their JSON (keys sorted), kept for `json()`.
    public private(set) var unreadable: [String: Data] = [:]

    public init() {}

    /// The stored JSON, record by record; nil when it is not a JSON object at
    /// all (then nothing can be kept record by record, and the caller must not
    /// write over it).
    public init?(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]),
              let records = object as? [String: Any] else { return nil }
        for (id, value) in records {
            guard let raw = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            else { return nil }
            if let c = try? JSONDecoder().decode(GameControls.self, from: raw) {
                games[id] = c
            } else {
                unreadable[id] = raw
            }
        }
    }

    /// A game's own controls; nil when it has none (or only a record this build cannot read).
    public subscript(id: String) -> GameControls? { games[id] }

    /// Sets a game's own controls (nil, or one with nothing set: none). This
    /// replaces a record of that id this build could not read: the player
    /// changed that game's controls here.
    public mutating func set(_ id: String, _ c: GameControls?) {
        unreadable[id] = nil
        games[id] = c.flatMap { $0.isEmpty ? nil : $0.normalized }
    }

    /// The JSON to store: the records read and the unreadable ones as they came.
    public func json() throws -> Data {
        var object: [String: Any] = [:]
        for (id, raw) in unreadable {
            object[id] = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
        }
        for (id, c) in games {
            object[id] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c), options: [.fragmentsAllowed])
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
