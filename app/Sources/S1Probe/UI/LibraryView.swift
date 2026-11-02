// SPDX-License-Identifier: GPL-3.0-or-later
// The Library (docs/design/2026-09-28-gamepad-ui/Library.dc.html): the games
// in C:\Games and the paired account's owned games in one grid
// (PlayportKit.LibraryList). At its left the store column (decision 0178): All,
// then every store as its mark (a store not connected dimmed), the chosen one
// named with its count above the grid. ◀ from the grid's first column takes the
// ring into the column at the chosen store; ▲▼ there switch the grid at once; ▶,
// A or B go back to the first tile; LT/RT step along the stores from anywhere.
// Installed only (narrowing any store) and the sort are in the list picker on
// the View button (⧉), and search is on Y with the controller keyboard
// (UI/Pad/PadKeyboardView.swift). Each tile says whether the game is ready and
// when it was last played, its download or queued update, or its size when it
// is not installed. A opens the game's page over the grid. Works offline, with
// no Steam session: the owned games come from the disk cache.
//
// Add a game (UI/Import.swift) opens Files to import a game's folder or .zip: a
// button in the heading and X in the footer on every store, an entry in the
// ⧉ picker, and a tile after the games in All and on the empty page.
//
// The grid is lazy, so a tile off screen is not drawn; the grid reports every
// tile's frame to the focus ring itself (padFrames), and when the ring moves to
// a tile not wholly on screen scrolls just far enough to show its row, to an
// offset worked out from that frame (a scroll to the lazy grid's id lands on an estimate).

import BattleNetClientKit
import Combine
import GOGClientKit
import EpicClientKit
import HostIOKit
import PlayportKit
import SteamClientKit
import SwiftUI

/// The Library's store, Installed only, sort and search: where it was left, for the session.
@MainActor
final class LibraryGrid: ObservableObject {
    static let shared = LibraryGrid()

    @Published var filter = LibraryFilter.all
    @Published var installedOnly = false
    @Published var sort = LibrarySort.recent
    @Published var search = ""
    /// The controller keyboard is up for the search (Y).
    @Published private(set) var searching = false
    /// The ring leaves the store column for the grid's first item (LibraryRing).
    let toTiles = PassthroughSubject<Void, Never>()
    /// The grid had nothing to ring when it was (re)started: the ring waits on the store's
    /// button and goes to the first tile when one comes, unless the player moved it first.
    var ringWaits = false

    /// The controller keyboard over the Library: the grid filters as the player types.
    func openSearch() {
        searching = true
        PadModal.shared.keyboard(title: "Search", text: search, placeholder: "Game name", maxLength: 64,
                                 changed: { [weak self] in self?.search = $0 },
                                 done: { [weak self] in
                                     self?.search = $0
                                     self?.searching = false
                                 })
    }

    /// The stores, Installed only and the sorts, in one list picker (UI/Pad/PadPicker.swift): the View button (⧉).
    func openFilterSort() {
        let order = "Sort"
        var options: [PadOption] = LibraryFilter.allCases.map { PadOption(id: "filter:\($0.rawValue)", label: $0.label, section: "Store") }
        options.append(PadOption(id: "installed", label: "Installed only", detail: "Games in C:\\Games or downloading", section: "Show"))
        options.append(PadOption(id: "add", label: "Add a game", detail: "From Files: a folder or a .zip", section: "Games"))
        options += [PadOption(id: "sort:\(LibrarySort.recent.rawValue)", label: "Recent", detail: "Last played first", section: order),
                    PadOption(id: "sort:\(LibrarySort.name.rawValue)", label: "Name", detail: "A to Z", section: order),
                    PadOption(id: "sort:\(LibrarySort.size.rawValue)", label: "Size", detail: "Largest first", section: order)]
        var selected: Set<String> = ["filter:\(filter.rawValue)", "sort:\(sort.rawValue)"]
        if installedOnly { selected.insert("installed") }
        PadModal.shared.picker(title: "Filter & sort", context: "Library", options: options, selected: selected) { [weak self] id in
            if id == "add" { GameImports.requests.send(); return }
            if id == "installed" { self?.installedOnly.toggle(); return }
            let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            if parts[0] == "filter", let f = LibraryFilter(rawValue: parts[1]) { self?.filter = f }
            if parts[0] == "sort", let s = LibrarySort(rawValue: parts[1]) { self?.sort = s }
        }
    }

    func clearSearch() {
        search = ""
        searching = false
    }

    /// LT (-1) or RT (+1): the store before or after, wrapping round.
    func step(_ by: Int) {
        filter = filter.step(by)
    }

    /// Shows `filter` from the start: All, or a store, with Installed only off (`open:` screens).
    func show(_ filter: LibraryFilter, installedOnly: Bool = false) {
        self.filter = filter
        self.installedOnly = installedOnly
    }

    /// Whether the store is connected; one that is not is dimmed in the column (decision 0178).
    /// Battle.net needs no sign-in, and All is no store.
    static func connected(_ filter: LibraryFilter) -> Bool {
        switch filter {
        case .all, .battlenet: true
        case .steam: SteamAccountModel.current.map { $0.state.account != nil && $0.state != .expired } ?? false
        case .gog: GOGAccount.shared.state == .signedIn
        case .epic: EpicAccount.shared.state == .signedIn
        }
    }

    static func label(_ sort: LibrarySort) -> String {
        switch sort {
        case .recent: "Recent"
        case .name: "Name"
        case .size: "Size"
        }
    }
}

/// The Library's presses before the shell's own (AppShell): the store column's and LT/RT.
@MainActor
enum LibraryRing {
    static func press(_ b: NavButton) -> Bool {
        let nav = AppNavigation.shared, focus = PadFocus.shared, grid = LibraryGrid.shared
        guard nav.page == .library, !nav.settings, !nav.onGamePage, !nav.signIn else { return false }
        grid.ringWaits = false
        let inColumn = focus.focused.map(StoreColumn.isItem) ?? false
        let tiles: (String) -> Bool = { !StoreColumn.isItem($0) }
        switch b {
        case .lt, .rt:
            grid.step(b == .lt ? -1 : 1)
        case .up, .down:
            if inColumn {
                focus.move(b == .up ? .up : .down, within: StoreColumn.isItem)
                if let f = focus.focused.flatMap(StoreColumn.filter) { grid.filter = f }
            } else {
                focus.move(b == .up ? .up : .down, within: tiles)
            }
        case .right:
            if inColumn { grid.toTiles.send() } else { focus.move(.right, within: tiles) }
        case .left:
            if inColumn { return true }
            let before = focus.focused
            focus.move(.left, within: tiles)
            // From the grid's first column: into the column, at the chosen store.
            if focus.focused == before { focus.ring(StoreColumn.item(grid.filter)) }
        case .b where inColumn:
            grid.toTiles.send()
        default:
            return false
        }
        return true
    }
}

struct LibraryView: View {
    @ObservedObject var installs: Downloads
    @ObservedObject private var nav = AppNavigation.shared

    var body: some View {
        NavigationStack(path: $nav.gamePath) {
            LibraryGridView(installs: installs)
                // Under a game page the stack keeps the grid: its tiles leave the ring.
                .transformPreference(PadItemsKey.self) { if !nav.gamePath.isEmpty { $0 = [:] } }
                .toolbar(.hidden, for: .navigationBar)
                // The stack draws the system background otherwise, not the app's.
                .containerBackground(PP.background, for: .navigation)
                .navigationDestination(for: GameRef.self) {
                    // Clear: the shell draws the game's art behind the page (PageArt).
                    GameDetailView(ref: $0).containerBackground(.clear, for: .navigation)
                }
        }
    }
}

private struct LibraryGridView: View {
    @ObservedObject var installs: Downloads
    @EnvironmentObject private var model: SteamAccountModel
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var grid = LibraryGrid.shared
    @ObservedObject private var nav = AppNavigation.shared
    @ObservedObject private var focus = PadFocus.shared
    @ObservedObject private var imports = GameImports.shared
    @ObservedObject private var gog = GOGAccount.shared
    @ObservedObject private var epic = EpicAccount.shared
    @ObservedObject private var bnet = BattleNetStore.shared
    /// The scroll view on screen, how far its content is scrolled and how far it can be.
    @State private var viewport = CGRect.zero
    @State private var offset = CGFloat.zero
    @State private var maxOffset = CGFloat.zero
    @State private var position = ScrollPosition(edge: .top)

    private static let columns = 4
    private static let spacing = CGSize(width: 14, height: 16)
    private static let artHeight: CGFloat = 78
    private static let metaHeight: CGFloat = 16
    private static let metaGap: CGFloat = 5
    /// Room at the grid's top and sides for the ring, which draws 6 pt outside a tile.
    private static let inset: CGFloat = 8

    var body: some View {
        let all = LibraryList.entries(titles: library.catalog.titles, owned: LibraryOwned.all(model.games, gog.games, epic.games, bnet.shown))
        let downloading = Set(installs.jobs.keys)
        let shown = LibraryList.shown(all, filter: grid.filter, installedOnly: grid.installedOnly, sort: grid.sort,
                                      search: grid.search, downloading: downloading)
        let count = all.filter { LibraryList.matches($0, grid.filter, installedOnly: grid.installedOnly, downloading: downloading) }.count
        HStack(alignment: .top, spacing: 12) {
            StoreColumn()
                .padding(.top, 6).padding(.bottom, 8).padding(.leading, 6)
            VStack(alignment: .leading, spacing: 0) {
                heading(count: count)
                    .padding(.top, 6).padding(.bottom, 8)
                if shown.isEmpty {
                    empty
                } else {
                    tiles(shown, duplicateIDs: LibraryList.duplicateSourceIDs(all), addTile: showsAddTile)
                }
            }
        }
        // The ring starts on the first tile, on arrival and after the store, sort or search changes.
        // Back from a game page the ring is still on its tile, and stays there; on arrival the page
        // switch has put it top left, which is the column's All, so that does not count.
        .onAppear {
            if focus.focused.map({ $0.hasPrefix("lib:") && !StoreColumn.isItem($0) }) != true { startRing(at: nav.focusStart) }
        }
        // All and the Battle.net store list what Blizzard offers now (cached for six hours).
        .task { await bnet.refresh() }
        // In the column the ring stays there, on the store now shown (▲▼ or LT/RT).
        .onChange(of: grid.filter) { _, f in
            if focus.focused.map(StoreColumn.isItem) == true { focus.ring(StoreColumn.item(f)) } else { startRing() }
        }
        .onChange(of: grid.installedOnly) { _, _ in startRing() }
        .onChange(of: grid.sort) { _, _ in startRing() }
        .onChange(of: grid.search) { _, _ in startRing() }
        // The games came after the ring started (the catalogue or a store still loading).
        .onChange(of: shown.first?.id ?? emptyItems.first) { _, _ in
            if grid.ringWaits, let id = entryItem() {
                grid.ringWaits = false
                focus.ring(id)
            }
        }
        .onReceive(grid.toTiles) { if let id = entryItem() { focus.ring(id) } }
    }

    /// The ring on `start`, else the first tile; with nothing to ring yet, on the store's button
    /// until the first tile comes (`ringWaits`), not on whatever is top left.
    private func startRing(at start: String? = nil) {
        let entry = start ?? entryItem()
        grid.ringWaits = entry == nil
        PadFocus.shared.reset(start: entry ?? StoreColumn.item(grid.filter))
    }

    /// The first tile the grid shows now, else the empty page's first button, read afresh
    /// (an onChange's closure holds the old body's values).
    private func entryItem() -> String? {
        let all = LibraryList.entries(titles: library.catalog.titles, owned: LibraryOwned.all(model.games, gog.games, epic.games, bnet.shown))
        let first = LibraryList.shown(all, filter: grid.filter, installedOnly: grid.installedOnly, sort: grid.sort, search: grid.search,
                                      downloading: Set(installs.jobs.keys)).first.map { "lib:\($0.id)" }
        return first ?? emptyItems.first
    }

    // MARK: heading

    /// The chosen store and its count, Installed only when on, the search, Add a game and the sort.
    private func heading(count: Int) -> some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(grid.filter.label).font(PP.display(20)).foregroundStyle(PP.text).lineLimit(1)
                Text("\(count)").font(.system(size: 13)).foregroundStyle(PP.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("library-store")
            if grid.searching || !grid.search.isEmpty {
                // What the keyboard typed; a tap brings the keyboard back.
                Button { grid.openSearch() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12))
                        Text(grid.search.isEmpty ? "Search" : grid.search)
                            .foregroundStyle(grid.search.isEmpty ? PP.muted : PP.soft).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13)).foregroundStyle(PP.soft)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .frame(width: 180)
                    .background(PP.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(grid.searching ? PP.accent : PP.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library-search")
            }
            if library.scanning || model.gamesLoading || bnet.loading { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
            // Not in the ring (it leaves the tiles alone): X does it; a tap here.
            Button { GameImports.requests.send() } label: {
                HStack(spacing: 5) {
                    if imports.planning { ProgressView().controlSize(.mini) } else { Image(systemName: "plus").font(.system(size: 11, weight: .bold)) }
                    Text("Add a game")
                    PadGlyph(button: .x).scaleEffect(0.8)
                }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(PP.text)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(PP.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(PP.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library-add")
            Button { grid.openFilterSort() } label: {
                Text("Sort: \(LibraryGrid.label(grid.sort))")
                    .font(.system(size: 12)).foregroundStyle(PP.muted)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library-sort")
            // Styled as the sort beside it; a tap flips it, ⧉ does too (it is not in the ring).
            Button { grid.installedOnly.toggle() } label: {
                Text("Installed only: \(grid.installedOnly ? "On" : "Off")")
                    .font(.system(size: 12)).foregroundStyle(PP.muted)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library-installed-only")
        }
        .padding(.trailing, 6)
    }

    // MARK: tiles

    /// Add a game shows where local games do: All, with no search typed.
    private var showsAddTile: Bool { grid.filter == .all && grid.search.isEmpty }

    private func tiles(_ shown: [LibraryEntry], duplicateIDs: Set<String>, addTile: Bool) -> some View {
        GeometryReader { outer in
            let width = outer.size.width - 2 * Self.inset
            let tile = CGSize(width: (width - CGFloat(Self.columns - 1) * Self.spacing.width) / CGFloat(Self.columns),
                              height: Self.artHeight)
            let pitch = CGSize(width: Self.spacing.width, height: Self.spacing.height + Self.metaGap + Self.metaHeight)
            let games = Dictionary(model.games.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile.width), spacing: Self.spacing.width, alignment: .top),
                                             count: Self.columns),
                              alignment: .leading, spacing: Self.spacing.height) {
                        ForEach(shown) { entry in
                            LibraryTile(entry: entry, game: entry.appID.flatMap { games[$0] }, installs: installs,
                                        showSource: LibraryList.showsSourceBadge(entry, filter: grid.filter, duplicateIDs: duplicateIDs),
                                        width: tile.width, artHeight: Self.artHeight, metaGap: Self.metaGap, metaHeight: Self.metaHeight)
                        }
                        if addTile {
                            AddGameTile(planning: imports.planning, width: tile.width, artHeight: Self.artHeight,
                                        metaGap: Self.metaGap, metaHeight: Self.metaHeight)
                        }
                    }
                    .padding(Self.inset)
                }
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, newY in offset = newY }
                .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentSize.height - $0.containerSize.height) } action: { _, m in
                    maxOffset = m
                }
                .background(GeometryReader { geo in
                    Color.clear.onAppear { viewport = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, frame in viewport = frame }
                })
                // Every tile's art on screen, drawn or not: the ring's targets. The drawn
                // ones report the same frames themselves.
                .padFrames(offscreenFrames(shown.map { "lib:\($0.id)" } + (addTile ? [AddGameTile.item] : []), tile: tile, pitch: pitch),
                           hint: "Open")
                .refreshable {
                    library.refresh()
                    await model.loadGames(refresh: true)
                }
                .onChange(of: focus.focused) { _, id in
                    if let id, id.hasPrefix("lib:"), !StoreColumn.isItem(id), let frame = focus.items[id]?.frame { reveal(frame) }
                }
        }
    }

    /// Scrolls just far enough that a tile (its frame on screen) and its line below show,
    /// with room for the ring; nothing when they already do.
    private func reveal(_ frame: CGRect) {
        guard viewport.height > 0 else { return }
        let top = frame.minY - Self.inset
        let bottom = frame.maxY + Self.metaGap + Self.metaHeight + Self.inset
        var target = offset
        if top < viewport.minY {
            target = offset - (viewport.minY - top)
        } else if bottom > viewport.maxY {
            target = offset + (bottom - viewport.maxY)
        }
        target = min(max(0, target), maxOffset)
        guard abs(target - offset) > 0.5 else { return }
        withAnimation(.easeOut(duration: 0.15)) { position.scrollTo(y: target) }
    }

    /// The frames on screen of the tiles the viewport does not show, as the grid lays them out.
    private func offscreenFrames(_ ids: [String], tile: CGSize, pitch: CGSize) -> [String: CGRect] {
        guard viewport.width > 0 else { return [:] }
        let origin = CGPoint(x: viewport.minX + Self.inset, y: viewport.minY + Self.inset - offset)
        let frames = LibraryList.tileFrames(count: ids.count, columns: Self.columns, tile: tile, spacing: pitch, origin: origin)
        var out: [String: CGRect] = [:]
        for (id, frame) in zip(ids, frames) where frame.maxY <= viewport.minY || frame.minY >= viewport.maxY {
            out[id] = frame
        }
        return out
    }

    // MARK: nothing to show

    /// A store not connected (GOG, Epic: Steam has its own sign-in below), asking for its account.
    private var needsStore: Bool {
        grid.filter.store != nil && grid.filter != .steam && !LibraryGrid.connected(grid.filter)
    }

    /// Installed only hides games: Show all turns it off.
    private var offersAll: Bool { grid.installedOnly && grid.search.isEmpty }

    /// The empty page's buttons, in order: the ring starts on the first.
    private var emptyItems: [String] {
        (needsSignIn ? ["signin"] : []) + (needsStore ? ["store-signin"] : []) + (showsAddTile ? [AddGameTile.item] : [])
            + (offersAll ? ["show-all"] : [])
    }

    @ViewBuilder
    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(emptyTitle).font(PP.display(24)).foregroundStyle(PP.text)
            Text(emptyText).font(.system(size: 13)).foregroundStyle(PP.soft)
            if needsSignIn {
                EmptyButton(text: "Steam account", primary: true)
                    .padItem("signin", hint: "Open", cornerRadius: 14) { _ = nav.open("account") }.padding(.top, 6)
            }
            if needsStore {
                EmptyButton(text: "\(grid.filter.label) account", primary: true)
                    .padItem("store-signin", hint: "Open", cornerRadius: 14) { _ = nav.open("account") }.padding(.top, 6)
            }
            if showsAddTile {
                EmptyButton(text: imports.planning ? "Reading…" : "Add a game", primary: !needsSignIn)
                    .padItem(AddGameTile.item, hint: "Add", cornerRadius: 14) { GameImports.requests.send() }.padding(.top, 6)
            }
            if offersAll {
                EmptyButton(text: "Show all", primary: !needsSignIn && !needsStore && !showsAddTile)
                    .padItem("show-all", hint: "Show", cornerRadius: 14) { grid.installedOnly = false }.padding(.top, 6)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 14))
        .padding(.trailing, 6).padding(.bottom, 8)
    }

    private var needsSignIn: Bool {
        let hasInstalled = library.catalog.titles.contains { grid.filter == .all || $0.appID != nil }
        return (grid.filter == .all || grid.filter == .steam) && !hasInstalled && model.games.isEmpty
            && (model.state.account == nil || model.state == .expired)
    }

    private var emptyTitle: String {
        if !grid.search.isEmpty { return "No games match “\(grid.search)”" }
        if needsStore { return "Sign in to \(grid.filter.label)" }
        if grid.installedOnly {
            return grid.filter == .all ? "No games installed" : "No \(grid.filter.label) games installed"
        }
        switch grid.filter {
        case .all: return "No games yet"
        case .steam: return needsSignIn ? "Sign in to Steam" : (model.gamesLoading ? "Loading your games…" : "No Steam games")
        case .gog, .epic: return "No \(grid.filter.label) games"
        case .battlenet: return bnet.loading ? "Asking Blizzard…" : "No Battle.net games offered"
        }
    }

    private var emptyText: String {
        if !grid.search.isEmpty { return "Press B to clear the search." }
        if needsStore { return "Connect your \(grid.filter.label) account in Settings › Accounts to see your games here." }
        if grid.installedOnly {
            return "Install one from a store, or add one from Files: its folder or a .zip of it. Installed only is in Filter & sort (⧉)."
        }
        switch grid.filter {
        case .all:
            return model.gamesError ?? "Your installed games and games from connected stores appear here. Sign in to Steam or add a game from Files to get started."
        case .steam:
            if needsSignIn { return model.state == .expired ? AccountCopy.status(.expired) : "Pair Playport with your Steam account to see your games." }
            return model.gamesError ?? "Your Steam account owns no games."
        case .gog, .epic:
            return "Games from \(grid.filter.label) appear here."
        case .battlenet:
            return bnet.error ?? "World of Warcraft products appear here while their builds carry an x64 client."
        }
    }
}

/// A button on the empty page: the accent for the one to press first.
private struct EmptyButton: View {
    let text: String
    let primary: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold)).foregroundStyle(primary ? PP.onAccent : PP.text)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(primary ? PP.accent : PP.line, in: Capsule())
    }
}

/// The store column (decision 0178): All, a rule, then every store as its mark; the chosen one
/// lit with an accent bar, one not connected dimmed. Its buttons join the ring (LibraryRing).
private struct StoreColumn: View {
    @ObservedObject private var grid = LibraryGrid.shared
    // The dimming follows the accounts.
    @EnvironmentObject private var model: SteamAccountModel
    @ObservedObject private var gog = GOGAccount.shared
    @ObservedObject private var epic = EpicAccount.shared

    static func item(_ filter: LibraryFilter) -> String { "lib:store:\(filter.rawValue)" }
    static func isItem(_ id: String) -> Bool { id.hasPrefix("lib:store:") }
    static func filter(_ id: String) -> LibraryFilter? {
        isItem(id) ? LibraryFilter(rawValue: String(id.dropFirst("lib:store:".count))) : nil
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(LibraryFilter.allCases, id: \.self) { f in
                if f == LibraryFilter.allCases.dropFirst().first {
                    Rectangle().fill(PP.line).frame(width: 24, height: 1).padding(.vertical, 2)
                }
                button(f)
            }
        }
        .padding(.vertical, 8)
        .frame(width: 52)
        .background(PP.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    private func button(_ f: LibraryFilter) -> some View {
        let on = grid.filter == f
        return StoreGlyph(filter: f)
            .foregroundStyle(on ? PP.text : PP.soft)
            .opacity(LibraryGrid.connected(f) ? 1 : 0.4)
            .frame(width: 38, height: 38)
            .background(on ? PP.line : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) {
                if on { Capsule().fill(PP.accent).frame(width: 3, height: 20).offset(x: -7) }
            }
            .accessibilityElement()
            .accessibilityLabel(f.label + (LibraryGrid.connected(f) ? "" : ", not connected"))
            .accessibilityAddTraits(on ? .isSelected : [])
            // A tap, or A with the ring here: this store, then the grid.
            .padItem(Self.item(f), hint: "Show", cornerRadius: 10) {
                grid.filter = f
                grid.toTiles.send()
            }
    }
}

/// A store's mark (PlayportKit.StoreMark, in its 24×24 box), its letter when it has none,
/// or All's grid symbol.
private struct StoreGlyph: View {
    let filter: LibraryFilter

    var body: some View {
        if let store = filter.store {
            if let d = StoreMark.path(store), let segments = SVGPath.parse(d) {
                StoreMarkShape(segments: segments).frame(width: 20, height: 20)
            } else {
                Text(StoreMark.letter(store)).font(.system(size: 15, weight: .heavy))
            }
        } else {
            Image(systemName: "square.grid.2x2.fill").font(.system(size: 17, weight: .semibold))
        }
    }
}

/// SVG path segments in a 24×24 box, scaled to the frame.
private struct StoreMarkShape: Shape {
    let segments: [SVGPath.Segment]

    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 24
        func p(_ q: SVGPath.Point) -> CGPoint { CGPoint(x: rect.minX + q.x * k, y: rect.minY + q.y * k) }
        var path = Path()
        for s in segments {
            switch s {
            case .move(let a): path.move(to: p(a))
            case .line(let a): path.addLine(to: p(a))
            case .cubic(let c1, let c2, let a): path.addCurve(to: p(a), control1: p(c1), control2: p(c2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

/// One tile: the art (the ring's item), then one line about the game.
private struct LibraryTile: View {
    let entry: LibraryEntry
    let game: SteamGame?
    @ObservedObject var installs: Downloads
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var nav = AppNavigation.shared
    let showSource: Bool
    let width: CGFloat
    let artHeight: CGFloat
    let metaGap: CGFloat
    let metaHeight: CGFloat

    private var job: Downloads.Job? { installs.jobs[entry.key] }
    private var title: InstalledTitle? { entry.installed ? library.title(entry.id) : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: metaGap) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.overlay { GameArt(appID: entry.appID, name: entry.name, kind: .header, titleID: entry.installed ? entry.id : nil,
                                                 storeKey: entry.key) }.clipped()
                // The name over the art, unless a store's art (which carries it) is there.
                if (game == nil && !StoreArt.has(entry.key)) || job != nil {
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    Text(entry.name)
                        .font(PP.display(14)).textCase(.uppercase).tracking(0.5).foregroundStyle(.white).lineLimit(2)
                        .padding(.horizontal, 10).padding(.bottom, job?.fraction == nil ? 8 : 14)
                }
                if let fraction = job?.fraction {
                    ProgressBar(fraction: fraction, height: 4, track: .black.opacity(0.45))
                        .padding(.horizontal, 10).padding(.bottom, 6)
                }
            }
            .frame(width: width, height: artHeight)
            .overlay(alignment: .topTrailing) {
                if showSource { GameSourceBadge(source: entry.source).padding(6) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padItem("lib:\(entry.id)", hint: "Open", cornerRadius: 10) { nav.openGame(.title(entry.id)) }
            meta
                .font(.system(size: 12)).foregroundStyle(PP.muted).lineLimit(1)
                .frame(width: width, height: metaHeight, alignment: .leading)
        }
    }

    @ViewBuilder
    private var meta: some View {
        if let job {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.to.line").font(.system(size: 10, weight: .bold))
                Text(jobText(job))
            }
        } else if let installed = title {
            HStack(spacing: 5) {
                switch installed.badge {
                case .ready:
                    Text("●").foregroundStyle(PP.ok)
                    Text(["Ready", played(installed.lastPlayed)].compactMap { $0 }.joined(separator: " · "))
                case .needsRepair:
                    Text("●").foregroundStyle(PP.accent)
                    Text("Needs repair")
                case .incomplete:
                    Text("No executable")
                }
                if let game, SteamInstallStatus.updateAvailable(installed, game.info) {
                    Text("· Update").foregroundStyle(PP.accent)
                }
            }
        } else {
            Text(["Not installed", entry.sizeBytes.map(ByteCount.format)].compactMap { $0 }.joined(separator: " · "))
        }
    }

    private func jobText(_ job: Downloads.Job) -> String {
        let update = entry.installed && job.kind != .repair
        switch job.phase {
        case .queued:
            return [update ? "Update queued" : "Queued", entry.sizeBytes.map(ByteCount.format)].compactMap { $0 }.joined(separator: " · ")
        case .downloading:
            let what = job.kind == .repair ? "Repairing" : update ? "Updating" : "Downloading"
            return job.fraction.map { "\(what) · \(Int($0 * 100))%" } ?? what
        default:
            return job.status
        }
    }

    private func played(_ when: Date?) -> String? {
        when.map { "Played " + $0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)) }
    }
}

/// The grid's last tile: Files opens to import a game's folder or .zip (UI/Import.swift).
private struct AddGameTile: View {
    static let item = "lib:add"
    let planning: Bool
    let width: CGFloat
    let artHeight: CGFloat
    let metaGap: CGFloat
    let metaHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: metaGap) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(PP.surface)
                RoundedRectangle(cornerRadius: 10).strokeBorder(PP.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                VStack(spacing: 4) {
                    if planning { ProgressView().controlSize(.small) } else {
                        Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(PP.soft)
                    }
                    Text("Add a game").font(.system(size: 13, weight: .semibold)).foregroundStyle(PP.soft)
                }
            }
            .frame(width: width, height: artHeight)
            .padItem(Self.item, hint: "Add", cornerRadius: 10) { GameImports.requests.send() }
            Text(planning ? "Reading the folder…" : "From Files: a folder or a .zip")
                .font(.system(size: 12)).foregroundStyle(PP.muted).lineLimit(1)
                .frame(width: width, height: metaHeight, alignment: .leading)
        }
        .accessibilityIdentifier("library-add-game")
    }
}

/// Quiet, readable over any artwork; not a separate tap or controller focus target.
struct GameSourceBadge: View {
    let source: LibrarySource

    var body: some View {
        Text(source.label)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.65), in: Capsule())
            .accessibilityLabel("Source: \(source.label)")
            .allowsHitTesting(false)
    }
}

/// The owned games of every signed-in store, as the library joins them.
enum LibraryOwned {
    @MainActor
    static func all(_ steam: [SteamGame], _ gog: [GOGGame], _ epic: [EpicGame], _ battlenet: [LibraryList.Owned]) -> [LibraryList.Owned] {
        steam.map { LibraryList.Owned(appID: $0.id, name: $0.info.name, installSize: $0.info.installSize) }
            + gog.map { LibraryList.Owned(key: StoreGameKey(store: .gog, id: $0.id), name: $0.title) }
            + epic.map { LibraryList.Owned(key: StoreGameKey(store: .epic, id: $0.id), name: $0.title) }
            + battlenet
    }
}

/// Whether a store game has its store's art carrying its name, so no name is drawn over it: GOG's
/// and Epic's, and retail World of Warcraft's (the Classic products' art has no words).
enum StoreArt {
    @MainActor
    static func has(_ key: StoreGameKey) -> Bool {
        switch key.store {
        case .gog: GOGAccount.shared.game(key.id)?.image != nil
        case .epic: EpicAccount.shared.game(key.id).map { $0.wideArt ?? $0.tallArt } != nil
        case .battlenet: BattleNet.product(key).map { BattleNetArt.carriesName($0) } ?? false
        case .steam, .local: false
        }
    }
}

/// A game's store art when the paired account owns it, or a Battle.net product's (no account);
/// else, for a game in C:\Games, its executable's icon (LocalGameArt); else its colour tile.
struct GameArt: View {
    @EnvironmentObject private var model: SteamAccountModel
    @ObservedObject private var library = LibraryModel.shared
    let appID: UInt32?
    let name: String
    let kind: ArtworkCache.Kind
    /// The catalogue's title, for a local game's icon.
    var titleID: String? = nil
    /// The store's game, for GOG's, Epic's or Battle.net's art.
    var storeKey: StoreGameKey? = nil

    var body: some View {
        if let app = appID, let game = model.games.first(where: { $0.id == app }) {
            SteamArtView(app: game.info, kind: kind, placeholder: PP.tile(for: name))
        } else if let key = storeKey, key.store == .gog, let g = GOGAccount.shared.game(key.id) {
            GOGArtView(game: g, wide: kind == .hero)
        } else if let key = storeKey, key.store == .epic, let g = EpicAccount.shared.game(key.id) {
            EpicArtView(game: g, wide: kind == .hero)
        } else if let key = storeKey, let p = BattleNet.product(key) {
            BattleNetArtView(product: p, wide: kind == .hero)
        } else if let id = titleID, let t = library.title(id), t.executable != nil {
            LocalGameArt(title: t)
        } else {
            PP.tile(for: name)
        }
    }
}

/// Store art for one app, from the art cache; the placeholder until it loads.
struct SteamArtView: View {
    @EnvironmentObject private var model: SteamAccountModel
    let app: SteamAppInfo
    let kind: ArtworkCache.Kind
    var placeholder: Color = PP.surface
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(placeholder)
            if let image = image ?? model.cachedImage(app, kind) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .clipped()
        .task(id: "\(app.appID)/\(kind.rawValue)") { image = await model.image(app, kind) }
    }
}
