// SPDX-License-Identifier: GPL-3.0-or-later
// Per-title compatibility defaults (decision 0074): launch settings known to make a game
// work, its default for everyone. The app ships them as Titles/compat-defaults.json:
//
//   {"titles": {"epic-Buffalo": {"settings": {"aspect": "16:9"},
//                                "reason": "This game draws nothing on a screen wider than 16:9."}}}
//
// keyed by catalogue id (case-sensitive: Epic app names have capitals), each entry a
// LaunchSettings object in the --settings JSON form and a short player-facing reason. The
// file reaches players: it names no issue, run or build; where an entry comes from is in
// the decision and evidence records. Precedence for one launch setting: the person's own
// choice on the game's page, then the title's compatibility default, then Settings, then
// Playport's built-in default; a game page's reset goes back to the compatibility default.
// Runtime keys and Graphics options take that precedence per key (decision 0091).

import Foundation

public struct CompatDefaults: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let settings: LaunchSettings
        /// Shown on the game's page, after "Set for this game's compatibility".
        public let reason: String
    }

    public let entries: [String: Entry]

    public static let fileName = "compat-defaults.json"
    public static let empty = CompatDefaults(entries: [:])

    public init(entries: [String: Entry]) { self.entries = entries }

    public func entry(for id: String) -> Entry? { entries[id] }

    /// Reads `<directory>/compat-defaults.json`.
    public static func load(directory: URL) throws -> CompatDefaults {
        try parse(Data(contentsOf: directory.appendingPathComponent(fileName)))
    }

    /// The table, checked: only `titles`; ids as the catalogue writes them; only `settings`
    /// and `reason` in an entry; each setting a LaunchSettings key whose value reads back as
    /// written and a launch takes; a reason with no project-internal reference.
    public static func parse(_ data: Data) throws -> CompatDefaults {
        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CompatDefaultsError.notAnObject("the file")
        }
        if let k = top.keys.first(where: { $0 != "titles" }) { throw CompatDefaultsError.unknownKey(k) }
        guard let titles = top["titles"] as? [String: Any] else { throw CompatDefaultsError.notAnObject("titles") }
        var entries: [String: Entry] = [:]
        for (id, value) in titles {
            guard id.range(of: #"^[a-z]+-[A-Za-z0-9 ._-]+$"#, options: .regularExpression) != nil else {
                throw CompatDefaultsError.badTitle(id)
            }
            guard let entry = value as? [String: Any] else { throw CompatDefaultsError.notAnObject(id) }
            if let k = entry.keys.first(where: { $0 != "settings" && $0 != "reason" }) {
                throw CompatDefaultsError.unknownKey("\(id).\(k)")
            }
            guard let reason = (entry["reason"] as? String)?.trimmingCharacters(in: .whitespaces), !reason.isEmpty else {
                throw CompatDefaultsError.noReason(id)
            }
            if containsInternalReference(reason) { throw CompatDefaultsError.internalReference(id) }
            guard let raw = entry["settings"] as? [String: Any], !raw.isEmpty else {
                throw CompatDefaultsError.notAnObject("\(id).settings")
            }
            entries[id] = Entry(settings: try settings(raw, id: id), reason: reason)
        }
        return CompatDefaults(entries: entries)
    }

    /// An issue id (`PLA-108`) or the tracker's address: what a shipped string must not hold.
    public static func containsInternalReference(_ text: String) -> Bool {
        text.range(of: #"(?i)\bPLA-[0-9]+|linear\.app"#, options: .regularExpression) != nil
    }

    private static func settings(_ raw: [String: Any], id: String) throws -> LaunchSettings {
        let data = try JSONSerialization.data(withJSONObject: raw)
        let s = try JSONDecoder().decode(LaunchSettings.self, from: data)
        // LaunchSettings skips what it does not know: a key it dropped or read otherwise is refused.
        let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any] ?? [:]
        for (k, v) in raw {
            guard let b = back[k], try same(b, v) else { throw CompatDefaultsError.badSetting("\(id).\(k)") }
        }
        if let screen = s.screen, !LaunchPlan.validScreen(screen) { throw CompatDefaultsError.badSetting("\(id).screen") }
        if let aspect = s.aspect, ScreenAspect(rawValue: aspect) == nil { throw CompatDefaultsError.badSetting("\(id).aspect") }
        if let limit = s.frameLimit, limit < 0 { throw CompatDefaultsError.badSetting("\(id).frameLimit") }
        return s
    }
}

/// Two JSON values alike, as their canonical text.
private func same(_ a: Any, _ b: Any) throws -> Bool {
    let o: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
    return try JSONSerialization.data(withJSONObject: a, options: o) == JSONSerialization.data(withJSONObject: b, options: o)
}

public enum CompatDefaultsError: Error, Equatable {
    case notAnObject(String)
    case unknownKey(String)
    case badTitle(String)
    case noReason(String)
    case badSetting(String)
    case internalReference(String)
}

extension LaunchSettings {
    /// These settings (a person's own for a game) over `base` (the game's compatibility
    /// default): each setting this level has wins, the rest come from `base`. Runtime keys
    /// and Graphics options merge by key (keyItems, decision 0091); Arguments, free text with
    /// no keys, are the person's alone once typed.
    public func over(_ base: LaunchSettings?) -> LaunchSettings {
        guard let base else { return self }
        func text(_ own: String, _ b: String) -> String { own.trimmingCharacters(in: .whitespaces).isEmpty ? b : own }
        return LaunchSettings(screen: screen ?? base.screen, aspect: aspect ?? base.aspect, frameLimit: frameLimit ?? base.frameLimit,
                              graphics: graphics ?? base.graphics, arguments: text(arguments, base.arguments),
                              steamAPI: steamAPI ?? base.steamAPI, cloudSync: cloudSync ?? base.cloudSync,
                              ordering: ordering.isEmpty ? base.ordering : ordering, maxInst: maxInst ?? base.maxInst,
                              x87Reduced: x87Reduced ?? base.x87Reduced, diskCache: diskCache ?? base.diskCache,
                              runtime: Self.keyItems(runtime, over: base.runtime),
                              graphicsOptions: Self.keyItems(graphicsOptions, over: base.graphicsOptions),
                              virtualPad: virtualPad ?? base.virtualPad,
                              virtualPadLayout: virtualPadLayout ?? base.virtualPadLayout)
    }

    /// `key=value` items as typed (Runtime keys, Graphics options) over the default's: the
    /// default's items whose key the person's text does not name, then the person's text as
    /// typed. A person's key wins (`MADEIRA_KEEP_SMC=0` turns that default off); every other
    /// key of the default stays. An item with no `=` is its own key.
    public static func keyItems(_ own: String, over base: String) -> String {
        let ownText = own.trimmingCharacters(in: .whitespaces)
        guard !ownText.isEmpty else { return base }
        func key(_ item: String) -> String { item.firstIndex(of: "=").map { String(item[..<$0]) } ?? item }
        let named = Set(splitArguments(ownText).map(key))
        let kept = splitArguments(base).filter { !named.contains(key($0)) }.map { $0.contains(" ") ? "\"\($0)\"" : $0 }
        return (kept + [ownText]).joined(separator: " ")
    }
}
