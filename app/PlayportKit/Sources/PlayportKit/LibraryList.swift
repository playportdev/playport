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

/// The origin of a library copy, independent of ownership and installation.
/// Add each store here when its catalogue adapter is available; Local is not a store filter.
public enum LibrarySource: String, CaseIterable, Sendable {
    case local
    case steam

    public var label: String {
        switch self {
        case .local: "Local"
        case .steam: "Steam"
        }
    }
}

/// One tile: a catalogued title, an owned game, or both at once.
public struct LibraryEntry: Equatable, Identifiable, Sendable {
    /// The catalogue's id (`app-<appID>`, `dir-<folder>`); `app-<appID>` for an owned game not in C:\Games.
    public var id: String
    public var name: String
    public var appID: UInt32?
    /// Today a Steam app ID is the catalogue's store identity; never infer origin from the name.
    public var source: LibrarySource { appID == nil ? .local : .steam }
    /// In C:\Games: the catalogue has it.
    public var installed: Bool
    /// The paired account owns it.
    public var owned: Bool
    public var lastPlayed: Date?
    /// On disk when installed, else Steam's install size.
    public var sizeBytes: UInt64?

    public init(id: String, name: String, appID: UInt32?, installed: Bool, owned: Bool,
                lastPlayed: Date? = nil, sizeBytes: UInt64? = nil) {
        self.id = id
        self.name = name
        self.appID = appID
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

    public var label: String {
        switch self {
        case .all: "All"
        case .installed: "Installed"
        case .steam: LibrarySource.steam.label
        }
    }

    /// The next chip, wrapping round.
    public var next: LibraryFilter {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
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
    /// What the grid needs of an owned game.
    public struct Owned: Equatable, Sendable {
        public var appID: UInt32
        public var name: String
        public var installSize: UInt64?

        public init(appID: UInt32, name: String, installSize: UInt64? = nil) {
            self.appID = appID
            self.name = name
            self.installSize = installSize
        }
    }

    public static func entries(titles: [InstalledTitle], owned: [SteamGame]) -> [LibraryEntry] {
        entries(titles: titles, owned: owned.map { Owned(appID: $0.id, name: $0.info.name, installSize: $0.info.installSize) })
    }

    /// The catalogue's titles, each joined with the owned Steam game of its Steam app ID,
    /// then every other owned game. Names are not identities: copies from different sources
    /// stay separate. Future adapters must join on (store, store game ID), not name or bare ID.
    public static func entries(titles: [InstalledTitle], owned: [Owned]) -> [LibraryEntry] {
        let byApp = Dictionary(owned.map { ($0.appID, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UInt32>()
        var out = titles.map { title -> LibraryEntry in
            let game = title.appID.flatMap { byApp[$0] }
            if let app = title.appID { seen.insert(app) }
            return LibraryEntry(id: title.id, name: title.name, appID: title.appID, installed: true, owned: game != nil,
                                lastPlayed: title.lastPlayed, sizeBytes: title.sizeBytes ?? game?.installSize)
        }
        for game in owned where !seen.contains(game.appID) {
            out.append(LibraryEntry(id: "app-\(game.appID)", name: game.name, appID: game.appID, installed: false, owned: true,
                                    sizeBytes: game.installSize))
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

    /// `downloading`: the app IDs with a download, update or repair queued or running.
    public static func matches(_ entry: LibraryEntry, _ filter: LibraryFilter, downloading: Set<UInt32> = []) -> Bool {
        switch filter {
        case .all: true
        case .installed: entry.installed || entry.appID.map(downloading.contains) == true
        case .steam: entry.source == .steam
        }
    }

    /// What the grid shows: the filter's entries whose name contains `search`
    /// (case and accents aside), in `sort` order.
    public static func shown(_ entries: [LibraryEntry], filter: LibraryFilter, sort: LibrarySort, search: String = "",
                             downloading: Set<UInt32> = []) -> [LibraryEntry] {
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
