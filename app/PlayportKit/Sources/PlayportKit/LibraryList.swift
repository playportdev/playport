// SPDX-License-Identifier: GPL-3.0-or-later
// The Library's one grid (docs/design/2026-09-28-gamepad-ui/Library.dc.html):
// the games in C:\Games and the paired account's owned games as one list,
// the filter chips (All, Installed, then stores), the sort,
// the search, and where each tile sits on the grid, so the focus ring can
// move to a tile the lazy grid has not drawn yet (UI/LibraryView.swift).

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SteamClientKit

/// The origin of a library copy, independent of ownership and installation:
/// its store (decision 0057). Local is not a store filter.
public typealias LibrarySource = Store

/// One tile: a catalogued title, an owned game, or both at once.
public struct LibraryEntry: Equatable, Identifiable, Sendable {
    /// The catalogue's id (`app-<appID>`, `gog-<id>`, `dir-<folder>`); the store's
    /// title ID for an owned game not in C:\Games.
    public var id: String
    public var name: String
    /// Steam's app ID, for a Steam copy.
    public var appID: UInt32?
    /// The copy's store identity; never inferred from the name.
    public var key: StoreGameKey
    public var source: LibrarySource { key.store }
    /// In C:\Games: the catalogue has it.
    public var installed: Bool
    /// The paired account owns it.
    public var owned: Bool
    public var lastPlayed: Date?
    /// On disk when installed, else Steam's install size.
    public var sizeBytes: UInt64?

    public init(id: String, name: String, appID: UInt32?, key: StoreGameKey? = nil, installed: Bool, owned: Bool,
                lastPlayed: Date? = nil, sizeBytes: UInt64? = nil) {
        self.id = id
        self.name = name
        self.appID = appID
        self.key = key ?? appID.map(StoreGameKey.steam) ?? StoreGameKey(titleID: id) ?? StoreGameKey(store: .local, id: id)
        self.installed = installed
        self.owned = owned
        self.lastPlayed = lastPlayed
        self.sizeBytes = sizeBytes
    }
}

public enum LibraryFilter: String, CaseIterable, Sendable {
    /// Every known copy, including local games and store games not installed.
    case all
    /// In C:\Games, or downloading into it.
    case installed
    /// Every Steam copy, including installed games outside the paired account.
    case steam
    /// Every GOG copy: shown once GOG is signed in or a copy is in the catalogue.
    case gog
    /// Every Epic Games copy, likewise.
    case epic

    public var label: String {
        switch self {
        case .all: "All"
        case .installed: "Installed"
        case .steam: Store.steam.label
        case .gog: Store.gog.label
        case .epic: Store.epic.label
        }
    }

    public var store: Store? {
        switch self {
        case .all, .installed: nil
        case .steam: .steam
        case .gog: .gog
        case .epic: .epic
        }
    }

    /// The chips to show (decision 0045: connected stores add their own after
    /// Installed): Steam always, GOG and Epic when `stores` (signed in, or with
    /// a copy in the catalogue) has them.
    public static func shown(stores: Set<Store>) -> [LibraryFilter] {
        allCases.filter { f in f == .gog ? stores.contains(.gog) : f == .epic ? stores.contains(.epic) : true }
    }

    /// The next chip, wrapping round.
    public var next: LibraryFilter { next(in: Self.allCases) }

    public func next(in shown: [LibraryFilter]) -> LibraryFilter {
        guard let i = shown.firstIndex(of: self) else { return shown.first ?? .all }
        return shown[(i + 1) % shown.count]
    }
}

public enum LibrarySort: String, CaseIterable, Sendable {
    /// Last played first, then installed, then by name.
    case recent
    case name
    /// Largest first.
    case size

    public var next: LibrarySort {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

public enum LibraryList {
    /// What the grid needs of an owned game, in any store.
    public struct Owned: Equatable, Sendable {
        public var key: StoreGameKey
        public var name: String
        public var installSize: UInt64?
        public var appID: UInt32? { key.steamAppID }

        public init(key: StoreGameKey, name: String, installSize: UInt64? = nil) {
            self.key = key
            self.name = name
            self.installSize = installSize
        }

        public init(appID: UInt32, name: String, installSize: UInt64? = nil) {
            self.init(key: .steam(appID), name: name, installSize: installSize)
        }
    }

    public static func entries(titles: [InstalledTitle], owned: [SteamGame]) -> [LibraryEntry] {
        entries(titles: titles, owned: owned.map { Owned(appID: $0.id, name: $0.info.name, installSize: $0.info.installSize) })
    }

    /// The catalogue's titles, each joined with the owned game of its store identity
    /// (decision 0057), then every other owned game. Names are not identities: copies
    /// from different stores stay separate, and an imported folder joins no store.
    public static func entries(titles: [InstalledTitle], owned: [Owned]) -> [LibraryEntry] {
        let byKey = Dictionary(owned.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<StoreGameKey>()
        var out = titles.map { title -> LibraryEntry in
            let key = title.key
            let game = key.store == .local ? nil : byKey[key]
            seen.insert(key)
            return LibraryEntry(id: title.id, name: title.name, appID: title.appID, key: key, installed: true, owned: game != nil,
                                lastPlayed: title.lastPlayed, sizeBytes: title.sizeBytes ?? game?.installSize)
        }
        for game in owned where !seen.contains(game.key) {
            out.append(LibraryEntry(id: game.key.titleID, name: game.name, appID: game.appID, key: game.key, installed: false,
                                    owned: true, sizeBytes: game.installSize))
        }
        return out
    }

    /// Badge targets from the full library, before filtering: same display name but
    /// different sources. An installed/owned merge and copies within one source do not qualify.
    /// Until stores provide a shared game identity, use case/accent-insensitive names.
    public static func duplicateSourceIDs(_ entries: [LibraryEntry]) -> Set<String> {
        let groups = Dictionary(grouping: entries) {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        return Set(groups.filter { !$0.key.isEmpty && Set($0.value.map(\.source)).count > 1 }
            .values.flatMap { $0.map(\.id) })
    }

    /// Duplicate source badges only help in mixed-source views.
    public static func showsSourceBadge(_ entry: LibraryEntry, filter: LibraryFilter, duplicateIDs: Set<String>) -> Bool {
        (filter == .all || filter == .installed) && duplicateIDs.contains(entry.id)
    }

    /// `downloading`: the games with a download, update, repair or import queued or running.
    public static func matches(_ entry: LibraryEntry, _ filter: LibraryFilter, downloading: Set<StoreGameKey> = []) -> Bool {
        switch filter {
        case .all: true
        case .installed: entry.installed || downloading.contains(entry.key)
        case .steam, .gog, .epic: entry.source == filter.store
        }
    }

    /// What the grid shows: the filter's entries whose name contains `search`
    /// (case and accents aside), in `sort` order.
    public static func shown(_ entries: [LibraryEntry], filter: LibraryFilter, sort: LibrarySort, search: String = "",
                             downloading: Set<StoreGameKey> = []) -> [LibraryEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return entries
            .filter { matches($0, filter, downloading: downloading) }
            .filter { query.isEmpty || $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .sorted { lhs, rhs in
                switch sort {
                case .recent:
                    if lhs.lastPlayed != rhs.lastPlayed {
                        guard let left = lhs.lastPlayed else { return false }
                        guard let right = rhs.lastPlayed else { return true }
                        return left > right
                    }
                    if lhs.installed != rhs.installed { return lhs.installed }
                case .size:
                    if lhs.sizeBytes != rhs.sizeBytes { return (lhs.sizeBytes ?? 0) > (rhs.sizeBytes ?? 0) }
                case .name:
                    break
                }
                let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return byName == .orderedSame ? lhs.id < rhs.id : byName == .orderedAscending
            }
    }

    /// Home's Recent row: excluding the hero, the `count` games played last, newest
    /// first, then installed games never played by name, then the rest by name.
    public static func recent(_ entries: [LibraryEntry], count: Int, excluding heroID: String? = nil) -> [LibraryEntry] {
        Array(entries.filter { $0.id != heroID }.sorted { lhs, rhs in
            if lhs.lastPlayed != rhs.lastPlayed {
                guard let left = lhs.lastPlayed else { return false }
                guard let right = rhs.lastPlayed else { return true }
                return left > right
            }
            if lhs.installed != rhs.installed { return lhs.installed }
            let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return byName == .orderedSame ? lhs.id < rhs.id : byName == .orderedAscending
        }.prefix(max(0, count)))
    }

    /// Each tile's frame in the grid's content, row by row: `columns` tiles of
    /// `tile` size, `spacing` apart (across, down), from `origin`.
    public static func tileFrames(count: Int, columns: Int, tile: CGSize, spacing: CGSize,
                                  origin: CGPoint = .zero) -> [CGRect] {
        guard columns > 0 else { return [] }
        return (0..<max(0, count)).map { index in
            CGRect(x: origin.x + CGFloat(index % columns) * (tile.width + spacing.width),
                   y: origin.y + CGFloat(index / columns) * (tile.height + spacing.height),
                   width: tile.width, height: tile.height)
        }
    }
}
