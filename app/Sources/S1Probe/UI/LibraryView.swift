// SPDX-License-Identifier: GPL-3.0-or-later
// The Library (docs/design/2026-09-28-gamepad-ui/Library.dc.html): the games
// in C:\Games and the paired account's owned games in one grid
// (PlayportKit.LibraryList), with the chips Installed, All Steam games and
// Recently played and a sort, both in one list picker on the View button
// (⧉), and search on Y with the controller keyboard (UI/Pad/PadKeyboardView.swift). The ring
// moves among the tiles only: the chips and the sort take a tap or their button. Each tile
// says whether the game is ready and when it was last played, its download or
// queued update, or its size when it is not installed. A opens the game's
// page over the grid. Works offline, with no Steam session: the owned games
// come from the disk cache.
//
// The grid is lazy, so a tile off screen is not drawn; the grid reports every
// tile's frame to the focus ring itself (padFrames), and when the ring moves to
// a tile not wholly on screen scrolls just far enough to show its row, to an
// offset worked out from that frame (a scroll to the lazy grid's id lands on an estimate).

import PlayportKit
import SteamClientKit
import SwiftUI

/// The Library's chips, sort and search: where it was left, for the session.
@MainActor
final class LibraryGrid: ObservableObject {
    static let shared = LibraryGrid()

    @Published var filter = LibraryFilter.installed
    @Published var sort = LibrarySort.recent
    @Published var search = ""
    /// The controller keyboard is up for the search (Y).
    @Published private(set) var searching = false

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

    /// The chips and the sorts, in one list picker (UI/Pad/PadPicker.swift): the View button (⧉).
    func openFilterSort() {
        let show = "Show", order = "Sort"
        PadModal.shared.picker(title: "Filter & sort", context: "Library",
                               options: LibraryFilter.allCases.map { .init(id: "filter:\($0.rawValue)", label: Self.label($0), section: show) }
                                   + [.init(id: "sort:\(LibrarySort.recent.rawValue)", label: "Recent", detail: "Last played first", section: order),
                                      .init(id: "sort:\(LibrarySort.name.rawValue)", label: "Name", detail: "A to Z", section: order),
                                      .init(id: "sort:\(LibrarySort.size.rawValue)", label: "Size", detail: "Largest first", section: order)],
                               selected: ["filter:\(filter.rawValue)", "sort:\(sort.rawValue)"]) { [weak self] id in
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

    static func label(_ filter: LibraryFilter) -> String {
        switch filter {
        case .installed: "Installed"
        case .steam: "All Steam games"
        case .recent: "Recently played"
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

struct LibraryView: View {
    @ObservedObject var installs: SteamInstalls
    @ObservedObject private var nav = AppNavigation.shared

    var body: some View {
        NavigationStack(path: $nav.gamePath) {
            LibraryGridView(installs: installs)
                // Under a game page the stack keeps the grid: its tiles leave the ring.
                .transformPreference(PadItemsKey.self) { if !nav.gamePath.isEmpty { $0 = [:] } }
                .toolbar(.hidden, for: .navigationBar)
                // The stack draws the system background otherwise, not the app's.
                .containerBackground(PP.background, for: .navigation)
                .navigationDestination(for: GameRef.self) { GameDetailView(ref: $0) }
        }
    }
}

private struct LibraryGridView: View {
    @ObservedObject var installs: SteamInstalls
    @EnvironmentObject private var model: SteamAccountModel
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var grid = LibraryGrid.shared
    @ObservedObject private var nav = AppNavigation.shared
    @ObservedObject private var focus = PadFocus.shared
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
        let all = LibraryList.entries(titles: library.catalog.titles, owned: model.games)
        let downloading = Set(installs.jobs.keys)
        let shown = LibraryList.shown(all, filter: grid.filter, sort: grid.sort, search: grid.search, downloading: downloading)
        VStack(alignment: .leading, spacing: 0) {
            chips(all, downloading: downloading)
                .padding(.top, 6).padding(.bottom, 8)
            if shown.isEmpty {
                empty
            } else {
                tiles(shown)
            }
        }
        // The ring starts on the first tile, on arrival and after the chip, sort or search changes.
        // Back from a game page the ring is still on its tile, and stays there.
        .onAppear { if focus.focused?.hasPrefix("lib:") != true { PadFocus.shared.reset(start: nav.focusStart ?? firstTile()) } }
        .onChange(of: grid.filter) { _, _ in PadFocus.shared.reset(start: firstTile()) }
        .onChange(of: grid.sort) { _, _ in PadFocus.shared.reset(start: firstTile()) }
        .onChange(of: grid.search) { _, _ in PadFocus.shared.reset(start: firstTile()) }
    }

    /// The first tile the grid shows now, read afresh (an onChange's closure holds the old body's values).
    private func firstTile() -> String? {
        let all = LibraryList.entries(titles: library.catalog.titles, owned: model.games)
        return LibraryList.shown(all, filter: grid.filter, sort: grid.sort, search: grid.search,
                                 downloading: Set(installs.jobs.keys)).first.map { "lib:\($0.id)" }
    }

    // MARK: chips

    private func chips(_ all: [LibraryEntry], downloading: Set<UInt32>) -> some View {
        HStack(spacing: 8) {
            ForEach(LibraryFilter.allCases, id: \.self) { chip in
                let count = all.filter { LibraryList.matches($0, chip, downloading: downloading) }.count
                // Not in the ring: ⧉ picks one; a tap here.
                Button { grid.filter = chip } label: {
                    Chip(text: chip == .recent ? LibraryGrid.label(chip) : "\(LibraryGrid.label(chip)) · \(count)", on: grid.filter == chip)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chip-\(chip.rawValue)")
            }
            Spacer(minLength: 8)
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
            if library.scanning || model.gamesLoading { ProgressView().controlSize(.small) }
            Button { grid.openFilterSort() } label: {
                Text("Sort: \(LibraryGrid.label(grid.sort))")
                    .font(.system(size: 12)).foregroundStyle(PP.muted)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library-sort")
        }
        .padding(.horizontal, 6)
    }

    // MARK: tiles

    private func tiles(_ shown: [LibraryEntry]) -> some View {
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
                            LibraryTile(entry: entry, game: entry.appID.flatMap { games[$0] }, installs: installs, width: tile.width,
                                        artHeight: Self.artHeight, metaGap: Self.metaGap, metaHeight: Self.metaHeight)
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
                .padFrames(offscreenFrames(shown, tile: tile, pitch: pitch), hint: "Open")
                .refreshable {
                    library.refresh()
                    await model.loadGames(refresh: true)
                }
                .onChange(of: focus.focused) { _, id in
                    if let id, id.hasPrefix("lib:"), let frame = focus.items[id]?.frame { reveal(frame) }
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
    private func offscreenFrames(_ shown: [LibraryEntry], tile: CGSize, pitch: CGSize) -> [String: CGRect] {
        guard viewport.width > 0 else { return [:] }
        let origin = CGPoint(x: viewport.minX + Self.inset, y: viewport.minY + Self.inset - offset)
        let frames = LibraryList.tileFrames(count: shown.count, columns: Self.columns, tile: tile, spacing: pitch, origin: origin)
        var out: [String: CGRect] = [:]
        for (entry, frame) in zip(shown, frames) where frame.maxY <= viewport.minY || frame.minY >= viewport.maxY {
            out["lib:\(entry.id)"] = frame
        }
        return out
    }

    // MARK: nothing to show

    @ViewBuilder
    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(emptyTitle).font(PP.display(24)).foregroundStyle(PP.text)
            Text(emptyText).font(.system(size: 13)).foregroundStyle(PP.soft)
            if needsSignIn {
                Text("Steam account")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(PP.onAccent)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(PP.accent, in: Capsule())
                    .padItem("signin", hint: "Open", cornerRadius: 14) { _ = nav.open("account") }
                    .padding(.top, 6)
            } else if grid.filter == .installed, !model.games.isEmpty, grid.search.isEmpty {
                Text("All Steam games")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(PP.onAccent)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(PP.accent, in: Capsule())
                    .padItem("steam", hint: "Show", cornerRadius: 14) { grid.filter = .steam }
                    .padding(.top, 6)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 6).padding(.bottom, 8)
    }

    private var needsSignIn: Bool {
        grid.filter == .steam && model.games.isEmpty && (model.state.account == nil || model.state == .expired)
    }

    private var emptyTitle: String {
        if !grid.search.isEmpty { return "No games match “\(grid.search)”" }
        switch grid.filter {
        case .installed: return "No games installed"
        case .steam: return needsSignIn ? "Sign in to Steam" : (model.gamesLoading ? "Loading your games…" : "No Steam games")
        case .recent: return "Nothing played yet"
        }
    }

    private var emptyText: String {
        if !grid.search.isEmpty { return "Press B to clear the search." }
        switch grid.filter {
        case .installed:
            #if PLAYPORT_RELEASE
            return "Install one from your Steam games, or copy one into Playport."
            #else
            return "Install one from your Steam games, or copy one into Playport's C:\\Games folder."
            #endif
        case .steam:
            if needsSignIn { return model.state == .expired ? AccountCopy.status(.expired) : "Pair Playport with your Steam account to see your games." }
            return model.gamesError ?? "Your Steam account owns no games."
        case .recent: return "Games you play show up here."
        }
    }
}

private struct Chip: View {
    let text: String
    let on: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(on ? PP.text : PP.soft)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(on ? PP.line : PP.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Color(hex: 0x4A5667) : PP.line, lineWidth: 1))
    }
}

/// One tile: the art (the ring's item), then one line about the game.
private struct LibraryTile: View {
    let entry: LibraryEntry
    let game: SteamGame?
    @ObservedObject var installs: SteamInstalls
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var nav = AppNavigation.shared
    let width: CGFloat
    let artHeight: CGFloat
    let metaGap: CGFloat
    let metaHeight: CGFloat

    private var job: SteamInstalls.Job? { entry.appID.flatMap { installs.jobs[$0] } }
    private var title: InstalledTitle? { entry.installed ? library.title(entry.id) : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: metaGap) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.overlay { GameArt(appID: entry.appID, name: entry.name, kind: .header) }.clipped()
                if game == nil || job != nil {
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

    private func jobText(_ job: SteamInstalls.Job) -> String {
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

/// A game's store art when the paired account owns it, else its colour tile.
struct GameArt: View {
    @EnvironmentObject private var model: SteamAccountModel
    let appID: UInt32?
    let name: String
    let kind: ArtworkCache.Kind

    var body: some View {
        if let app = appID, let game = model.games.first(where: { $0.id == app }) {
            SteamArtView(app: game.info, kind: kind, placeholder: PP.tile(for: name))
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
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .clipped()
        .task(id: "\(app.appID)/\(kind.rawValue)") { image = await model.image(app, kind) }
    }
}
