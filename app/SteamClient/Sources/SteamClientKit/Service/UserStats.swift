// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A game's stats and achievements on Steam, and the Steam API emulator's
/// copy of them (docs/plans/finished.md#steam-for-games, phase 3).
///
/// Steam keeps a user's stats as 32-bit values by stat ID (a float stat as
/// its bit pattern); an achievement is one bit of an "achievement block"
/// stat, with its unlock time kept beside the block. The schema, which names
/// both, comes as binary KeyValues with ClientGetUserStats. The emulator
/// (gbe_fork) reads the schema from `steam_settings/achievements.json` and
/// `stats.json`, and saves progress under `GSE Saves/<appid>/`:
/// `achievements.json` (name -> earned, earned_time) and one 4-byte file per
/// stat in `stats/`, named by the lower-cased stat name.
public struct StatsSchema: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case int, float, avgrate }

    public struct Stat: Codable, Sendable, Equatable {
        public var id: UInt32
        public var name: String
        public var kind: Kind
        public var defaultValue: String?
    }

    public struct Achievement: Codable, Sendable, Equatable {
        public var name: String
        /// The achievement block stat and the bit in it.
        public var statID: UInt32
        public var bit: UInt32
        /// By language (`english`, `german`, …).
        public var displayName: [String: String]
        public var description: [String: String]
        public var hidden: Bool

        public func text(_ field: [String: String], language: String = "english") -> String {
            field[language] ?? field["english"] ?? field.values.sorted().first ?? name
        }
    }

    public var version: Int?
    public var stats: [Stat]
    public var achievements: [Achievement]

    /// Steam's UserGameStatsSchema: `stats` { <id> { type, name, default, …,
    /// bits { <n> { name, bit, display { name, desc, hidden } } } } }. Stat
    /// types: 1 int, 2 float, 3 average rate, 4 achievements, 5 group
    /// achievements (the last two carry achievement bits).
    public static func parse(_ root: KeyValue) throws -> StatsSchema {
        let statsNode = root["stats"] ?? root.children.lazy.compactMap { $0["stats"] }.first
        guard let statsNode else { throw SteamError.protocolChanged("stats schema: no stats") }
        var stats: [Stat] = [], achievements: [Achievement] = []
        for node in statsNode.children {
            guard let id = UInt32(node.name) ?? node["id"]?.uint32 else { continue }
            let type = node["type"]?.value ?? ""
            switch type {
            case "1", "2", "3":
                guard let name = node["name"]?.value, !name.isEmpty else { continue }
                stats.append(Stat(id: id, name: name, kind: type == "1" ? .int : type == "2" ? .float : .avgrate,
                                  defaultValue: node["default"]?.value))
            case "4", "5", "ACHIEVEMENTS", "GROUPACHIEVEMENTS":
                for b in node["bits"]?.children ?? [] {
                    guard let name = b["name"]?.value, let bit = b["bit"]?.uint32 ?? UInt32(b.name), bit < 32 else { continue }
                    let display = b["display"]
                    achievements.append(Achievement(
                        name: name, statID: id, bit: bit,
                        displayName: languages(display?["name"]), description: languages(display?["desc"]),
                        hidden: display?["hidden"]?.value == "1"))
                }
            default:
                continue
            }
        }
        return StatsSchema(version: root["version"].flatMap { Int($0.value ?? "") },
                           stats: stats.sorted { $0.id < $1.id },
                           achievements: achievements.sorted { ($0.statID, $0.bit) < ($1.statID, $1.bit) })
    }

    static func languages(_ node: KeyValue?) -> [String: String] {
        guard let node else { return [:] }
        if let v = node.value { return ["english": v] }
        var out: [String: String] = [:]
        for c in node.children where c.name != "token" { if let v = c.value { out[c.name] = v } }
        return out
    }
}

/// One user's stats for one game, as Steam has them.
public struct UserStatsSnapshot: Codable, Sendable, Equatable {
    public var appID: UInt32
    public var crc: UInt32
    public var schema: StatsSchema
    public var values: [UInt32: UInt32]
    /// Per achievement block: the unlock time of each bit (0 when locked).
    public var unlockTimes: [UInt32: [UInt32]]
    public var fetchedAt: Date

    public func unlocked(_ a: StatsSchema.Achievement) -> Bool { (values[a.statID] ?? 0) >> a.bit & 1 == 1 }

    public func unlockTime(_ a: StatsSchema.Achievement) -> UInt32 {
        let t = unlockTimes[a.statID] ?? []
        return Int(a.bit) < t.count ? t[Int(a.bit)] : 0
    }

    public var unlockedCount: Int { schema.achievements.filter(unlocked).count }
}

/// The emulator's side: its schema files, and its saved progress.
public enum EmulatorStats {
    /// Progress as the emulator saved it: unlocked achievements by name (with
    /// the time), stat values by lower-cased name (Steam's 32-bit form).
    public struct Progress: Sendable, Equatable {
        public var unlocked: [String: UInt32] = [:]
        public var stats: [String: UInt32] = [:]
        public init(unlocked: [String: UInt32] = [:], stats: [String: UInt32] = [:]) {
            self.unlocked = unlocked
            self.stats = stats
        }
    }

    /// `achievements.json` and `stats.json` for a steam_settings folder.
    public static func schemaFiles(_ s: StatsSchema) -> [String: Data] {
        let achievements: [[String: Any]] = s.achievements.map {
            ["name": $0.name, "displayName": $0.displayName, "description": $0.description, "hidden": $0.hidden ? "1" : "0"]
        }
        // gbe_fork reads `default` only as a string; a number drops the stat.
        let stats: [[String: Any]] = s.stats.map {
            ["name": $0.name, "type": $0.kind.rawValue, "default": $0.defaultValue ?? "0", "global": "0"]
        }
        var out: [String: Data] = [:]
        out["achievements.json"] = try? JSONSerialization.data(withJSONObject: achievements, options: [.prettyPrinted, .sortedKeys])
        out["stats.json"] = try? JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys])
        return out
    }

    /// The emulator's save folder for one game: `<saves>/<appid>`.
    public static func folder(_ saves: URL, appID: UInt32) -> URL {
        saves.appendingPathComponent(String(appID), isDirectory: true)
    }

    /// The emulator's saved progress; empty when it has saved none.
    public static func read(_ folder: URL, schema: StatsSchema) -> Progress {
        var p = Progress()
        if let data = try? Data(contentsOf: folder.appendingPathComponent("achievements.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let known = Set(schema.achievements.map { $0.name.lowercased() })
            for (name, v) in json {
                guard known.contains(name.lowercased()), let e = v as? [String: Any], e["earned"] as? Bool == true else { continue }
                p.unlocked[name] = (e["earned_time"] as? NSNumber)?.uint32Value ?? 0
            }
        }
        for s in schema.stats {
            let url = folder.appendingPathComponent("stats").appendingPathComponent(fileName(s.name))
            if let d = try? Data(contentsOf: url), d.count == 4 {
                p.stats[s.name.lowercased()] = d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            }
        }
        return p
    }

    /// Writes `progress` into the emulator's save folder: every unlock in it
    /// (others kept as they are) and every stat in it.
    public static func write(_ progress: Progress, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("stats"), withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("achievements.json")
        var json = ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        for (name, time) in progress.unlocked {
            let key = json.keys.first { $0.lowercased() == name.lowercased() } ?? name
            json[key] = ["earned": true, "earned_time": time]
        }
        try InstallFS.writeAtomically(url, JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
        for (name, value) in progress.stats {
            var le = value.littleEndian
            try InstallFS.writeAtomically(folder.appendingPathComponent("stats").appendingPathComponent(fileName(name)),
                                          Data(bytes: &le, count: 4))
        }
    }

    /// gbe_fork's stat file name: lower case, with its escapes for the
    /// characters Windows names cannot hold.
    static func fileName(_ stat: String) -> String {
        var out = ""
        for c in stat.lowercased() {
            switch c {
            case "|": out += ".V_SLASH."
            case ":": out += ".COLON."
            case "*": out += ".ASTERISK."
            case "\"": out += ".QUOTE."
            case "?": out += ".Q_MARK."
            case "%": out += ".PERCENT."
            default: out.append(c)
            }
        }
        return out
    }

    /// What a sync does, from Steam's snapshot, the emulator's progress and
    /// the stat values the last sync left (`baseline`, by lower-cased name).
    public struct Plan: Sendable, Equatable {
        /// Stat values to store on Steam, by stat ID (achievement blocks included).
        public var store: [UInt32: UInt32] = [:]
        /// Achievements the emulator unlocked that Steam has not.
        public var newUnlocks: [String] = []
        /// What the emulator's save gets from Steam.
        public var local = Progress()
    }

    /// - Achievements only accumulate: an unlock the emulator has and Steam
    ///   has not is stored (its block's bit set), and one Steam has is written
    ///   to the emulator's save.
    /// - A stat the emulator changed since the last sync is stored; any other
    ///   takes Steam's value, which may be newer (another PC). With no last
    ///   sync (`baseline` nil) nothing tells a change from a stale value, so
    ///   every stat takes Steam's: a player's stats are never lowered to an
    ///   old save's.
    public static func plan(steam: UserStatsSnapshot, local: Progress, baseline: [String: UInt32]?) -> Plan {
        var plan = Plan()
        var blocks: [UInt32: UInt32] = [:]
        let localUnlocked = Set(local.unlocked.keys.map { $0.lowercased() })
        for a in steam.schema.achievements {
            if steam.unlocked(a) {
                if !localUnlocked.contains(a.name.lowercased()) { plan.local.unlocked[a.name] = steam.unlockTime(a) }
            } else if localUnlocked.contains(a.name.lowercased()) {
                blocks[a.statID, default: steam.values[a.statID] ?? 0] |= 1 << a.bit
                plan.newUnlocks.append(a.name)
            }
        }
        plan.store.merge(blocks) { $1 }
        for s in steam.schema.stats where s.kind != .avgrate {
            let key = s.name.lowercased()
            let onSteam = steam.values[s.id] ?? defaultBits(s)
            if let baseline, let mine = local.stats[key], mine != baseline[key], mine != onSteam {
                plan.store[s.id] = mine
            } else if local.stats[key] != onSteam {
                plan.local.stats[key] = onSteam
            }
        }
        return plan
    }

    /// A stat's schema default in Steam's 32-bit form.
    static func defaultBits(_ s: StatsSchema.Stat) -> UInt32 {
        switch s.kind {
        case .int: UInt32(bitPattern: Int32(s.defaultValue ?? "0") ?? 0)
        case .float, .avgrate: (Float(s.defaultValue ?? "0") ?? 0).bitPattern
        }
    }
}
