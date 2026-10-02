// SPDX-License-Identifier: GPL-3.0-or-later
// Home (docs/design/2026-09-28-gamepad-ui/Main.dc.html): the game played
// last, with its details, when and how long in all (PlayportKit PlayTime.swift); the
// download running, with its time left, and the one after it; and the
// four other games played last from the whole Library, installed or not (dimmed),
// the never played by name. Every card takes the focus ring; A opens its details.
// Search belongs to Library; game options belong to each game's details.

import PlayportKit
import SteamClientKit
import SwiftUI

struct HomeView: View {
    @ObservedObject var installs: SteamInstalls
    @EnvironmentObject private var model: SteamAccountModel
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var nav = AppNavigation.shared
    @ObservedObject private var focus = PadFocus.shared

    /// The game played last, else the first installed one.
    private var continueTitle: InstalledTitle? {
        let titles = library.catalog.titles.filter(\.canPlay)
        return titles.filter { $0.lastPlayed != nil }.max { $0.lastPlayed! < $1.lastPlayed! } ?? titles.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                hero
                VStack(spacing: 10) {
                    downloadCard
                    nextCard
                }
                .frame(width: 250)
            }
            .frame(height: 170)
            Text("Recent").font(PP.display(17, .semibold)).foregroundStyle(PP.text)
            recentRow
        }
        .padding(.top, 8)
    }

    // MARK: Continue playing

    @ViewBuilder
    private var hero: some View {
        if let t = continueTitle {
            ZStack(alignment: .bottomLeading) {
                // Art sized by the card, not the card by the art.
                Color.clear.overlay { GameArt(appID: t.appID, name: t.name, kind: .hero) }.clipped()
                LinearGradient(colors: [.clear, PP.background.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.lastPlayed == nil ? "Ready to play" : "Continue playing")
                        .font(.system(size: 12, weight: .semibold)).tracking(1.2).textCase(.uppercase)
                        .foregroundStyle(PP.accent)
                    Text(t.name).font(PP.display(34)).foregroundStyle(PP.text).lineLimit(1).minimumScaleFactor(0.6)
                    if let played = Self.played(t) {
                        Text(played).font(.system(size: 13)).foregroundStyle(PP.soft).lineLimit(1)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padItem("hero:\(t.id)", hint: "Open", cornerRadius: 14) { nav.openTitle(t.id) }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("No games yet").font(PP.display(30)).foregroundStyle(PP.text)
                Text("Install one from your Steam games in the Library.").font(.system(size: 13)).foregroundStyle(PP.soft)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .background(PP.surface, in: RoundedRectangle(cornerRadius: 14))
            .padItem("hero", hint: "Library", cornerRadius: 14) { _ = nav.open("games") }
        }
    }

    /// `Played 2 hr. ago · 14 h total`
    static func played(_ t: InstalledTitle) -> String? {
        let when = t.lastPlayed.map { "Played " + $0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)) }
        let total = t.playSeconds.map { PlayTime.format($0) + " total" }
        let parts = [when, total].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: downloads

    private var downloadCard: some View {
        let job = installs.order.first
        return HomeCard(label: job.map { $0.isRunning ? "Downloading" : $0.status } ?? "Downloads") {
            if let job {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.name).font(PP.display(19)).foregroundStyle(PP.text).lineLimit(1)
                    Spacer(minLength: 4)
                    if let f = job.fraction {
                        Text(([Self.percent(f)] + [Self.left(job)].compactMap { $0 }).joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(PP.muted).lineLimit(1)
                    }
                }
                ProgressBar(fraction: job.fraction ?? 0)
            } else {
                Text("Nothing downloading").font(.system(size: 13)).foregroundStyle(PP.muted)
            }
        }
        .padItem("download", hint: "Open") { nav.show(.downloads) }
    }

    private var nextCard: some View {
        let order = installs.order
        return HomeCard(label: "Up next") {
            if order.count > 1 {
                let next = order[1]
                Text(Self.jobName(next)).font(PP.display(19)).foregroundStyle(PP.text).lineLimit(1)
                Text(([next.remaining.map(ByteCount.format)].compactMap { $0 }
                      + [next.phase == .queued ? "starts after \(order[0].name)" : next.status]).joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(PP.muted).lineLimit(1)
            } else {
                Text("Nothing queued").font(.system(size: 13)).foregroundStyle(PP.muted)
            }
        }
        .padItem("next", hint: "Open") { nav.show(.downloads) }
    }

    static func percent(_ f: Double) -> String { "\(Int(f * 100))%" }

    /// `4 min`: the running job's time left at its speed.
    static func left(_ job: SteamInstalls.Job) -> String? {
        guard job.phase == .downloading, let r = job.remaining,
              let s = DownloadRate.seconds(remaining: r, rate: job.rate) else { return nil }
        return DownloadRate.short(s)
    }

    /// `Celeste`, `Celeste update`, `Celeste repair`.
    static func jobName(_ job: SteamInstalls.Job) -> String {
        switch job.kind {
        case .install: job.name
        case .update: job.name + " update"
        case .repair: job.name + " repair"
        }
    }

    // MARK: Recent

    /// The four games played last other than the hero, installed or not; the
    /// installed games never played fill the rest by name, then the others by name.
    private var recent: [LibraryEntry] {
        LibraryList.recent(LibraryList.entries(titles: library.catalog.titles, owned: model.games),
                           count: 4, excluding: continueTitle?.id)
    }

    /// Five tiles across (Main.dc.html), the ring's room at each end included.
    private static func tileWidth(_ row: CGFloat) -> CGFloat { max(100, (row - 12 - 4 * 12) / 5) }

    private var recentRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recent) { entry in
                        tile(entry)
                    }
                    Text("+ Find games")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(PP.muted)
                        .frame(height: 70)
                        .containerRelativeFrame(.horizontal) { w, _ in Self.tileWidth(w) }
                        .background(PP.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PP.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .padItem("find", hint: "Library", cornerRadius: 10) { _ = nav.open("games") }
                }
                // Room for the ring, which draws outside each tile.
                .padding(.horizontal, 6).padding(.vertical, 6)
            }
            .padding(.horizontal, -6)
            .onChange(of: focus.focused) { _, id in
                if let id, id.hasPrefix("tile:") || id.hasPrefix("game:") || id == "find" { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private func hasArt(_ appID: UInt32?) -> Bool {
        appID.map { app in model.games.contains { $0.id == app } } ?? false
    }

    /// An installed game is `tile:ID` and opens its details; one not installed is
    /// `game:APPID`, dimmed, and opens its Steam page.
    private func tile(_ entry: LibraryEntry) -> some View {
        let job = entry.appID.flatMap { installs.jobs[$0] }
        return ZStack(alignment: .bottomLeading) {
            Color.clear.overlay { GameArt(appID: entry.appID, name: entry.name, kind: .header) }.clipped()
            // Store art carries the game's name; a colour tile, or a download, says it.
            if !hasArt(entry.appID) || job != nil {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                Text(job.map { "\(entry.name) · \(Self.tileStatus($0))" } ?? entry.name)
                    .font(PP.display(14)).textCase(.uppercase).tracking(0.5).foregroundStyle(.white).lineLimit(1)
                    .padding(8)
            }
        }
        .frame(height: 70)
        .containerRelativeFrame(.horizontal) { w, _ in Self.tileWidth(w) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(entry.installed && job == nil ? 1 : 0.55)
        .padItem(entry.installed ? "tile:\(entry.id)" : "game:\(entry.appID ?? 0)", hint: "Open", cornerRadius: 10) {
            if entry.installed {
                nav.openTitle(entry.id)
            } else if let app = entry.appID {
                nav.openGame(.steam(app))
            }
        }
    }

    /// `62%` while it downloads, else the job's state.
    private static func tileStatus(_ job: SteamInstalls.Job) -> String {
        if job.isRunning, let f = job.fraction { return percent(f) }
        return job.status
    }
}

/// A small card on Home: a label over whatever it shows.
private struct HomeCard<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .semibold)).tracking(1.1).textCase(.uppercase).foregroundStyle(PP.muted)
            content
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ProgressBar: View {
    let fraction: Double
    var height: CGFloat = 6
    var track: Color = PP.line

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(PP.progress).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
    }
}
