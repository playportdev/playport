// SPDX-License-Identifier: GPL-3.0-or-later
// A game's page (docs/design/2026-09-28-gamepad-ui/Game.dc.html,
// GameInstall.dc.html), opened from the Library or Home over the grid: the
// hero art filling the screen behind it (drawn by the shell, PageArt), the name, the developer and controller
// support, then the buttons, all on the focus ring:
//
// - installed: Play (A), the achievements count, Options (X), Update when
//   Steam has a newer build on the install's branch; a running update or
//   repair takes Play's place with its progress, Pause and Cancel;
// - not installed: Install with the size (Resume or Discard a stopped
//   download), and Version (X) when Steam lists betas.
//
// At the right a card of facts: last played, cloud saves and the size on the
// phone, or the download size, the version and the achievements. Under the
// buttons one or two lines say what stands in the way of a Play (another game
// ran in this process, the memory limit, a download that pauses) and whether a
// controller is connected.
//
// Game options (GameOptions.dc.html) is a panel over the dimmed page: the
// game's resolution, frame rate limit and Direct3D, each "Default · X" until
// changed and marked when changed (PlayportKit OptionValue; LaunchSettings
// inherits game, then Settings, then 720p, 60 fps and DXMT), launch arguments
// on the controller keyboard; then the version, cloud saves (and the
// Cloud save conflict screen when they conflict), check game files (and Repair), achievements (a list over the
// panel), report a problem (a share sheet with the log) and uninstall. Y puts
// the ringed setting back to its default. A dev build adds a Developer
// section: FEX's memory ordering, block size and x87 precision over the game's
// profile (FEXProfile), which steam_api the game loads, and the build facts.
//
// Play is refused, with the reason, once this process has run a title (one
// runtime per process). A release build words failures without internals
// (decision 0009). A dev build's `open:ID#SECTION` opens the options at a
// section (graphics, game, files, developer, ordering, steam).

import GameController
import HostIOKit
import GOGClientKit
import PlayportKit
import SteamClientKit
import SwiftUI
import UIKit

/// What X does on the game page now, for the shell's footer (AppShell.gamePageHints).
@MainActor
final class GamePageState: ObservableObject {
    static let shared = GamePageState()

    struct Action {
        let label: String
        let action: () -> Void
    }

    @Published var x: Action?
}

struct GameDetailView: View {
    let ref: GameRef
    @EnvironmentObject private var steam: SteamAccountModel

    var body: some View { GameDetailPage(ref: ref, installs: steam.installs) }
}

private struct GameDetailPage: View {
    let ref: GameRef
    @ObservedObject var installs: Downloads
    @EnvironmentObject private var model: SteamAccountModel
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var launch = TitleLaunch.shared
    @ObservedObject private var launchSettings = LaunchSettingsStore.shared
    @ObservedObject private var navigation = AppNavigation.shared
    @ObservedObject private var focus = PadFocus.shared
    @ObservedObject private var gog = GOGAccount.shared
    @State private var playError: String?
    @State private var controllers = GCController.controllers().count
    @State private var stageOnDisk = false
    /// The version picker's choice; nil until the player picks one.
    @State private var pickedBranch: String?
    /// Which steam_api the game's folder holds now (SteamAPISwap), read off the main thread.
    @State private var steamAPIState: SteamAPISwap.State?
    /// Its executables wrapped in Steam's DRM (SteamStub), and whether it is off them.
    @State private var steamStubs: [SteamStub.Site] = []

    /// The game in C:\Games, if it is there now.
    private var installed: InstalledTitle? {
        switch ref {
        case let .title(id): library.title(id)
        case let .steam(app): library.catalog.titles.first { $0.appID == app }
        case let .store(key): library.catalog.titles.first { $0.key == key }
        }
    }

    private var appID: UInt32? {
        switch ref {
        case let .title(id): installed?.appID ?? Self.appID(fromTitleID: id)
        case let .steam(app): app
        case let .store(key): key.steamAppID
        }
    }

    /// The game's store identity (decision 0057): what its download and art key on.
    private var key: StoreGameKey? {
        if let installed { return installed.key }
        switch ref {
        case let .title(id): return StoreGameKey(titleID: id)
        case let .steam(app): return .steam(app)
        case let .store(key): return key
        }
    }

    /// `app-367520` names Steam app 367520 (InstalledTitle.id), so an
    /// uninstalled title's page still finds its Steam game.
    private static func appID(fromTitleID id: String) -> UInt32? {
        id.hasPrefix("app-") ? UInt32(id.dropFirst(4)) : nil
    }

    /// The paired account's copy of the game, if it owns it.
    private var game: SteamGame? { appID.flatMap { app in model.games.first { $0.id == app } } }

    private var job: Downloads.Job? { key.flatMap { installs.jobs[$0] } }

    /// The Steam branches this game can be downloaded from, public first.
    private var branches: [Branch] { game?.info.depots.installableBranches ?? [] }

    /// The cohort's build, when one of the branches carries it (The Witcher 3's
    /// D3D11 `classic`): the picker's preset, not marked.
    private var cohortBranch: String? {
        guard let app = appID, let build = LibraryModel.cohort.titles.first(where: { $0.appID == app })?.buildID else { return nil }
        return branches.first { $0.buildID == build }?.name
    }

    /// The picker's choice, else the install's branch, else the cohort's, else public.
    private var selectedBranch: String {
        pickedBranch ?? installed?.branch ?? (installed == nil ? cohortBranch : nil) ?? Branch.publicName
    }

    private var name: String { installed?.name ?? game?.info.name ?? gogGame?.title ?? "" }

    /// The GOG listing of this game, when GOG is signed in and owns it.
    private var gogGame: GOGGame? { key.flatMap { $0.store == .gog ? gog.game($0.id) : nil } }

    private var canDownloadGOG: Bool { gog.state == .signedIn && !installs.suspended }

    private var stats: UserStatsSnapshot? { appID.flatMap { model.userStats[$0]?.steam } }

    var body: some View {
        let t = installed, g = game
        Group {
            if t == nil, g == nil, gogGame == nil {
                VStack(spacing: 8) {
                    Text("Not installed").font(PP.display(28)).foregroundStyle(PP.text)
                    #if PLAYPORT_RELEASE
                    Text("This game is no longer in Playport.").foregroundStyle(PP.muted)
                    #else
                    Text("This game's folder is no longer in C:\\Games.").foregroundStyle(PP.muted)
                    #endif
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content(t, g)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { focus.reset(start: navigation.focusStart ?? primaryID) }
        .onDisappear { GamePageState.shared.x = nil }
    }

    // MARK: page

    private func content(_ t: InstalledTitle?, _ g: SteamGame?) -> some View {
        let panel = navigation.gamePanels.last
        return ZStack(alignment: .topLeading) {
            page(t, g)
                // Under a panel the page's controls leave the ring.
                .transformPreference(PadItemsKey.self) { if panel != nil { $0 = [:] } }
            if let panel {
                Color(hex: 0x05070A).opacity(0.72).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { _ = navigation.back() }
                HStack(spacing: 0) {
                    // The note sits low at the left, just above the footer the shell
                    // draws there (36 pt), clear of the page's dimmed title and
                    // subtitle (GameOptions.dc.html puts it under the title).
                    VStack(alignment: .leading) {
                        Spacer()
                        if panel == .options {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(PP.accent).frame(width: 7, height: 7)
                                Text("Changed for this game. The rest follow Settings › Graphics.")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 13)).foregroundStyle(PP.soft)
                            .padding(.bottom, AppShell.footerBottom + 36 + 12)
                        }
                    }
                    .allowsHitTesting(false)
                    Spacer(minLength: 0)
                    Group {
                        switch panel {
                        case .options: if let t { optionsPanel(t, g) }
                        case .achievements: achievementsPanel
                        }
                    }
                    .frame(width: 410)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(PP.surface.ignoresSafeArea(edges: [.top, .trailing, .bottom]))
                    .overlay(alignment: .leading) { Rectangle().fill(PP.line).frame(width: 1).ignoresSafeArea(edges: [.top, .bottom]) }
                }
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.15), value: panel)
        .task(id: job?.phase) { stageOnDisk = appID.map(installs.hasStageOnDisk) ?? false }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            controllers = GCController.controllers().count
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            controllers = GCController.controllers().count
        }
        .onChange(of: navigation.gamePanels) { old, new in panelsChanged(from: old, to: new) }
        .onChange(of: xKey(t), initial: true) { _, _ in updateX(t) }
        .task(id: t?.id) { if let t, t.store == .gog, t.source == .installed { await gog.checkUpdate(t.key.id) } }
        .task(id: navigation.pageSection) {
            // A dev build's `open:ID#SECTION`: the options, at that section.
            guard navigation.onGamePage, navigation.pageSection != nil, t != nil else { return }
            if navigation.gamePanels != [.options] { navigation.gamePanels = [.options] }
        }
        // Again once a restore signs in: a page opened while it ran fetched nothing.
        .task(id: "\(t?.appID.map(String.init) ?? "-") \(launch.running) \(signedIn)") {
            guard let t, let app = t.appID else { return }
            await model.loadGameProfile(app)
            // Not while the game runs: its launch suspends Steam in this process,
            // and the next start of the app syncs the played game.
            if !launch.running {
                await model.syncStats(app)
                await model.syncCloud(app)
            }
            let root = LibraryModel.paths.games.appendingPathComponent(t.installDir, isDirectory: true)
            (steamAPIState, steamStubs) = await Task.detached(priority: .utility) {
                (SteamAPISwap.state(in: root), SteamStub.sites(in: root))
            }.value
        }
        .alert("Can't start \(name)", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("OK") {}
        } message: {
            Text(playError ?? "")
        }
    }

    /// The page; under a panel only its art and name show (GameOptions.dc.html).
    private func page(_ t: InstalledTitle?, _ g: SteamGame?) -> some View {
        let under = !navigation.gamePanels.isEmpty
        return ZStack(alignment: .topLeading) {
            // The hero art fills the screen behind the page and its footer: the shell draws
            // it (PageArt), as the launch screen does, so on Play it does not change.
            Color.clear
                .preference(key: PageArtKey.self,
                            value: g.map { PageArt(appID: $0.id, name: name, info: $0.info) }
                                ?? t.map { PageArt(appID: $0.appID, name: $0.name, info: nil) }
                                ?? gogGame.map { PageArt(appID: nil, name: $0.title, info: nil) })

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(name).font(PP.display(48)).foregroundStyle(PP.text)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Group {
                        if let line = subtitle(t, g) {
                            Text(line).font(.system(size: 13)).foregroundStyle(PP.soft)
                        }
                        HStack(spacing: 12) {
                            if let t { installedButtons(t, g) } else if let g { installButtons(g) } else if let gg = gogGame { gogInstallButtons(gg) }
                        }
                        .padding(.top, 14)
                        notes(t, g)
                            .font(.system(size: 13)).foregroundStyle(PP.muted)
                            .lineSpacing(2)
                            .padding(.top, 12)
                    }
                    .opacity(under ? 0 : 1)
                }
                .frame(maxWidth: 500, alignment: .leading)
                Spacer(minLength: 0)
                facts(t, g)
                    .frame(width: 270)
                    .padding(.top, 94)
                    .opacity(under ? 0 : 1)
            }
            .padding(.top, 76)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func subtitle(_ t: InstalledTitle?, _ g: SteamGame?) -> String? {
        let developer = t?.developer ?? g?.info.developer
        let controller: String? = switch g?.info.controllerSupport {
        case "full": "Controller supported"
        case "partial": "Partial controller support"
        default: nil
        }
        let parts = [developer, controller].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The control the ring starts on.
    private var primaryID: String {
        if installed != nil { return job == nil ? "game:play" : "game:job" }
        return job == nil ? "game:install" : "game:job"
    }

    // MARK: buttons

    @ViewBuilder
    private func installedButtons(_ t: InstalledTitle, _ g: SteamGame?) -> some View {
        if let job {
            jobControls(job)
        } else if launch.spent {
            SecondaryButton(id: "game:close", systemImage: "xmark.circle", title: "Close Playport", hint: "Close") { exit(0) }
        } else {
            PrimaryButton(id: "game:play", title: "Play", enabled: canPlay(t), hint: "Play") { start(t) }
        }
        if let s = stats, !s.schema.achievements.isEmpty {
            SecondaryButton(id: "game:achievements", systemImage: "trophy", title: "\(s.unlockedCount) / \(s.schema.achievements.count)",
                            hint: "Achievements") { navigation.gamePanels = [.achievements] }
        }
        SecondaryButton(id: "game:options", systemImage: "slider.horizontal.3", title: "Options", glyph: .x, hint: "Game options") {
            navigation.gamePanels = [.options]
        }
        if job == nil, t.store == .gog, t.source == .installed, let newest = gog.newest[t.key.id], newest != t.storeVersion {
            SecondaryButton(id: "game:update", systemImage: "arrow.down.circle", title: "Update", enabled: canDownloadGOG && !launch.running,
                            hint: "Update") { gog.install(t.key.id, name: t.name, kind: .update) }
        }
        if job == nil, let g, SteamInstallStatus.updateAvailable(t, g.info) {
            SecondaryButton(id: "game:update", systemImage: "arrow.down.circle", title: "Update", enabled: canDownload && !launch.running,
                            hint: "Update") { installs.install(g.id, name: g.info.name) }
        }
    }

    @ViewBuilder
    private func installButtons(_ g: SteamGame) -> some View {
        if let job {
            jobControls(job)
        } else if stageOnDisk {
            PrimaryButton(id: "game:install", title: "Resume download", enabled: canDownload, hint: "Resume") {
                installs.install(g.id, name: g.info.name)
            }
            SecondaryButton(id: "game:discard", systemImage: "trash", title: "Discard", hint: "Discard") {
                installs.discard(g.id)
                stageOnDisk = false
            }
        } else {
            let size = g.info.installSize(branch: selectedBranch).map { " · " + ByteCount.format($0) } ?? ""
            PrimaryButton(id: "game:install", title: "Install" + size, enabled: canDownload, hint: "Install") {
                installs.install(g.id, name: g.info.name, branch: selectedBranch)
            }
            if branches.count > 1 {
                SecondaryButton(id: "game:version", systemImage: nil, title: "Version", glyph: .x, hint: "Version") { pickVersion(g) }
            }
        }
    }

    /// A GOG game not installed: Install, or its download's controls.
    @ViewBuilder
    private func gogInstallButtons(_ gg: GOGGame) -> some View {
        if let job {
            jobControls(job)
        } else {
            PrimaryButton(id: "game:install", title: gog.installer.hasStage(gg.id) ? "Resume download" : "Install",
                          enabled: canDownloadGOG, hint: "Install") { gog.install(gg.id, name: gg.title) }
        }
    }

    /// A download, update or repair of this game: its progress, Pause or Resume, and Cancel.
    @ViewBuilder
    private func jobControls(_ job: Downloads.Job) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(job.status).font(.system(size: 15, weight: .semibold)).foregroundStyle(PP.text)
                Spacer(minLength: 8)
                if let d = job.detail { Text(d).font(.system(size: 12)).foregroundStyle(PP.muted).monospacedDigit() }
            }
            ProgressView(value: job.fraction ?? 0).tint(PP.progress)
        }
        .padding(.horizontal, 14)
        .frame(width: 230, height: 52)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 12))
        .padItem("game:job", hint: job.isRunning || job.phase == .queued ? "Pause" : "Resume", cornerRadius: 12) {
            if job.isRunning || job.phase == .queued { installs.pause(job.key) } else if canDownload || job.key.store != .steam { installs.resume(job.key) }
        }
        SecondaryButton(id: "game:cancel", systemImage: "xmark", title: "Cancel", hint: job.kind == .repair ? "Cancel repair" : "Cancel download") {
            installs.discard(job.key)
        }
    }

    private func canPlay(_ t: InstalledTitle) -> Bool {
        t.canPlay && !launch.spent && !launch.running && !library.verifying.contains(t.id)
            && !library.removing.contains(t.id) && job == nil
    }

    private func start(_ t: InstalledTitle) {
        guard canPlay(t) else { return }
        Task {
            do {
                try await library.play(t.id)
            } catch {
                #if PLAYPORT_RELEASE
                LibraryModel.log("play \(t.id) refused: \(error)")
                playError = "Playport could not prepare this game's launch."
                #else
                playError = "\(error)"
                #endif
            }
        }
    }

    private var canDownload: Bool {
        guard case .signedIn = model.state else { return false }
        return !installs.suspended
    }

    /// Steam's public build or one of its betas (Steam's own "Betas" choice). For an installed
    /// game, another version downloads it over the one there.
    private func pickVersion(_ g: SteamGame) {
        let installedBranch = installed.map { $0.branch ?? Branch.publicName }
        PadModal.shared.picker(
            title: "Version", context: name,
            note: installedBranch == nil ? "Install downloads the version chosen here."
                : "Another version downloads over the one installed. Your saves are left alone.",
            options: branches.map { b in
                PadOption(id: b.name, label: BranchLabel.text(b),
                          detail: b.name == installedBranch ? "Installed" : g.info.installSize(branch: b.name).map(ByteCount.format))
            },
            selected: selectedBranch) { picked in
            pickedBranch = picked
            if let installedBranch, picked != installedBranch, canDownload, !launch.running, job == nil {
                installs.install(g.id, name: g.info.name, branch: picked)
            }
        }
    }

    // MARK: notes and facts

    @ViewBuilder
    private func notes(_ t: InstalledTitle?, _ g: SteamGame?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let t {
                if launch.spent {
                    Text(JitProvider.inLiveContainer
                         ? "Playport cannot start another game in this session. Close it and launch it again from LiveContainer with JIT to play again."
                         : "Playport cannot start another game in this session. Close it and reopen it from the Home Screen to play again.")
                } else if !t.canPlay {
                    Text("No Windows executable in this folder.").foregroundStyle(.orange)
                } else if let job {
                    if case let .paused(reason?) = job.phase { Text(reason).foregroundStyle(.orange) }
                    // An update Playport queued by itself holds Play too: say how to play now.
                    Text(job.kind == .repair ? "Play is available once the repair finishes, or after Cancel."
                         : job.record.automatic ? "Playport queued this update by itself. Play is available once it finishes, or after Cancel: it waits for Steam's next version then."
                         : "Play is available once the update finishes, or after Cancel.")
                } else {
                    MemoryWarning(need: MemoryNeed.of(t, cohort: LibraryModel.cohort))
                    if installs.isBusy { Text("Starting a game pauses the download. It goes on when Playport reopens after the game.") }
                    controllerLine
                }
            } else if let g {
                installNote(g)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var controllerLine: some View {
        if controllers == 0 {
            Text("No controller is connected. Connect it now: a game may not notice one connected later.")
                .foregroundStyle(.orange)
        } else {
            Text("Your controller is connected.")
        }
    }

    @ViewBuilder
    private func installNote(_ g: SteamGame) -> some View {
        if installs.suspended {
            Text(InstallCopy.afterLaunch)
        } else if case let .offline(_, reason) = model.state {
            Text("Steam can't be reached (\(reason)). Downloads resume once it can.")
        } else if model.state.account == nil || model.state == .expired {
            Text("Sign in to Steam to download.")
        } else if let job {
            if case let .paused(reason?) = job.phase { Text(reason).foregroundStyle(.orange) }
            if job.isRunning { Text("Keep Playport open: the download pauses when it leaves the screen.") }
        } else {
            let need = g.info.installSize(branch: selectedBranch).map { "Needs \(ByteCount.format($0))" }
            let free = library.freeBytes.map { "\(ByteCount.format($0)) free" }
            let parts = [need, free].compactMap { $0 }
            if !parts.isEmpty { Text(parts.joined(separator: " · ") + " · keep Playport open while it downloads") }
        }
    }

    private func facts(_ t: InstalledTitle?, _ g: SteamGame?) -> some View {
        let source: LibrarySource = key?.store ?? (appID == nil ? .local : .steam)
        var rows: [(String, String, Color?)] = [("Store", source.label, nil)]
        if let t {
            if t.badge != .ready { rows.append(("State", t.badge.rawValue, .orange)) }
            rows.append(("Last played", t.lastPlayed.map { $0.formatted(.relative(presentation: .named)) } ?? "Never", nil))
            if let played = t.playSeconds { rows.append(("Play time", PlayTime.format(played), nil)) }
            if t.source == .installed, let b = t.branch, b != Branch.publicName {
                rows.append(("Version", BranchLabel.text(b, in: g?.info), nil))
            }
            if t.appID != nil { rows.append(("Cloud saves", cloudStatus(t).0, cloudStatus(t).1)) }
            rows.append(("On this phone", t.sizeBytes.map(ByteCount.format) ?? "Unknown", nil))
        } else if let g {
            if let s = g.info.installSize(branch: selectedBranch) { rows.append(("Download", ByteCount.format(s), nil)) }
            if branches.count > 1 { rows.append(("Version", BranchLabel.text(selectedBranch, in: g.info), nil)) }
            if let s = stats, !s.schema.achievements.isEmpty {
                rows.append(("Achievements", "\(s.unlockedCount) of \(s.schema.achievements.count)", nil))
            }
        }
        return VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 12) {
                    Text(rows[i].0).foregroundStyle(PP.muted)
                    Spacer(minLength: 8)
                    Text(rows[i].1).foregroundStyle(rows[i].2 ?? PP.text).lineLimit(1)
                }
                .font(.system(size: 13))
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) {
                    if i < rows.count - 1 { Rectangle().fill(PP.raised).frame(height: 1) }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 14))
        .opacity(rows.isEmpty ? 0 : 1)
    }

    /// Steam Cloud for the facts card and the options' row.
    private func cloudStatus(_ t: InstalledTitle) -> (String, Color?) {
        guard SteamAccountModel.cloudOn else { return ("Off in Settings", nil) }
        guard launchSettings.settings(for: t.id).cloudSync ?? true else { return ("Off", nil) }
        guard let app = t.appID else { return ("Not synced", nil) }
        if model.cloudSyncing.contains(app) { return ("Syncing…", nil) }
        if model.cloudErrors[app] != nil { return ("Not synced", .orange) }
        guard let c = model.cloud[app] else { return ("Not synced yet", nil) }
        if !c.conflicts.isEmpty { return ("\(c.conflicts.count) to settle", .orange) }
        if !c.failed.isEmpty { return ("\(c.failed.count) not synced", .orange) }
        return ("Up to date", PP.ok)
    }

    private var signedIn: Bool {
        if case .signedIn = model.state { true } else { false }
    }

    // MARK: X and the ring

    private func xKey(_ t: InstalledTitle?) -> String {
        if t != nil { return "options" }
        return game != nil && job == nil && !stageOnDisk && branches.count > 1 ? "version" : "none"
    }

    private func updateX(_ t: InstalledTitle?) {
        switch xKey(t) {
        case "options":
            GamePageState.shared.x = .init(label: "Game options") { navigation.gamePanels = [.options] }
        case "version":
            GamePageState.shared.x = .init(label: "Version") { if let g = game { pickVersion(g) } }
        default:
            GamePageState.shared.x = nil
        }
    }

    private func panelsChanged(from old: [AppNavigation.GamePanel], to new: [AppNavigation.GamePanel]) {
        switch new.last {
        case .options?:
            let section = navigation.pageSection.flatMap(Self.firstRow(ofSection:))
            focus.reset(start: section ?? (old.last == .achievements ? "opt:achievements" : "opt:screen"))
        case .achievements?:
            focus.reset(start: "ach:0")
        case nil:
            focus.reset(start: old.last == .achievements ? "game:achievements" : "game:options")
        }
    }

    /// Where `open:ID#SECTION` rings the options.
    private static func firstRow(ofSection s: String) -> String? {
        switch s {
        case "graphics": "opt:screen"
        case "game": "opt:version"
        case "files": "opt:files"
        case "developer", "ordering": "opt:ordering-\(MemoryOrdering.Setting.allCases[0].rawValue)"
        case "steam": "opt:steamAPI"
        default: nil
        }
    }

    // MARK: Game options

    private func optionsPanel(_ t: InstalledTitle, _ g: SteamGame?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Game options").font(PP.display(22)).foregroundStyle(PP.text)
                .padding(.horizontal, 14).padding(.bottom, 2)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        graphicsRows(t)
                        gameRows(t, g)
                        #if !PLAYPORT_RELEASE
                        developerRows(t)
                        #endif
                    }
                    .padding(.bottom, 18)
                }
                .onChange(of: focus.focused) { _, id in
                    guard let id, id.hasPrefix("opt:") else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
                .task(id: navigation.pageSection) {
                    guard let s = navigation.pageSection, navigation.onGamePage else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    if let row = Self.firstRow(ofSection: s) {
                        focus.ring(row)
                        proxy.scrollTo(row, anchor: .top)
                    }
                    navigation.pageSection = nil
                }
            }
        }
        .padding(.top, 18).padding(.leading, 20).padding(.trailing, 28)
    }

    private var context: String { name }

    // Graphics: resolution, frame rate limit, Direct3D, launch arguments.
    @ViewBuilder
    private func graphicsRows(_ t: InstalledTitle) -> some View {
        let settings = launchSettings.binding(for: t.id)
        let own = settings.wrappedValue
        let inherited = LaunchSettings.resolve(game: nil, global: launchSettings.global)
        let screenName: (String?) -> String = { LaunchSettingsText.screen($0, pixels: false) }
        let screen = OptionValue.of(own: own.screen.map(Optional.some), inherited: inherited.screen, name: screenName)
        let limit = OptionValue.of(own: own.frameLimit, inherited: inherited.frameLimit, name: LaunchSettingsText.frameLimit)
        let inheritedGraphics = launchSettings.effective(for: t, inheritingGraphics: true).graphics
        let d3d = OptionValue.of(own: own.graphics, inherited: inheritedGraphics, name: LaunchSettingsText.graphics)
        PadSectionHeader(text: "Graphics").id("graphics")
        PadRow(id: "opt:screen", title: "Resolution", value: screen.text, accessory: .chevron, changed: screen.changed,
               style: .plain, reset: screen.changed ? { settings.wrappedValue.screen = nil } : nil) {
            let native = LaunchSettingsText.screens.first == "native"
            PadModal.shared.picker(
                title: "Resolution", context: "\(context) · Graphics", note: LaunchSettingsText.nextStart,
                options: [PadOption(id: "", label: "Default", detail: "\(screenName(inherited.screen)), from Settings")]
                    + LaunchSettingsText.screens.map { spec in
                        PadOption(id: spec, label: screenName(spec),
                                  detail: spec == "native" && native ? "Sharpest, most power"
                                      : spec == LaunchSettings.defaultScreen ? "Longest battery" : LaunchSettingsText.pixels(spec))
                    },
                selected: own.screen ?? "") { settings.wrappedValue.screen = $0.isEmpty ? nil : $0 }
        }
        PadRow(id: "opt:frameLimit", title: "Frame rate limit", value: limit.text, accessory: .chevron, changed: limit.changed,
               style: .plain, reset: limit.changed ? { settings.wrappedValue.frameLimit = nil } : nil) {
            PadModal.shared.picker(
                title: "Frame rate limit", context: "\(context) · Graphics", note: LaunchSettingsText.nextStart,
                options: [PadOption(id: "", label: "Default", detail: "\(LaunchSettingsText.frameLimit(inherited.frameLimit)), from Settings")]
                    + LaunchSettingsText.frameLimits.map { PadOption(id: String($0), label: LaunchSettingsText.frameLimit($0)) }
                    + [PadOption(id: "0", label: "Off", detail: "As fast as the screen allows")],
                selected: own.frameLimit.map(String.init) ?? "") { settings.wrappedValue.frameLimit = Int($0) }
        }
        PadRow(id: "opt:graphics", title: "Direct3D", value: d3d.text, accessory: .chevron, changed: d3d.changed,
               style: .plain, reset: d3d.changed ? { settings.wrappedValue.graphics = nil } : nil) {
            PadModal.shared.picker(
                title: "Direct3D", context: "\(context) · Graphics",
                note: LaunchSettingsText.nextStart + " " + LaunchSettingsText.graphicsDetection(t) + " " + LaunchSettingsText.graphicsFooter,
                options: [PadOption(id: "", label: "Default", detail: "\(LaunchSettingsText.graphics(inheritedGraphics)), from Settings or game detection")]
                    + GraphicsBackend.allCases.filter { Manifest.has($0) || own.graphics == $0 }.map {
                        PadOption(id: $0.rawValue, label: LaunchSettingsText.graphics($0), detail: LaunchSettingsText.graphicsDetail($0))
                    },
                selected: own.graphics?.rawValue ?? "") { settings.wrappedValue.graphics = GraphicsBackend(rawValue: $0) }
        }
        let args = own.arguments.trimmingCharacters(in: .whitespaces)
        PadRow(id: "opt:arguments", title: "Launch arguments", value: args.isEmpty ? "None" : args, accessory: .chevron,
               changed: !args.isEmpty, style: .plain, hint: "Edit",
               reset: args.isEmpty ? nil : { settings.wrappedValue.arguments = "" }) {
            PadModal.shared.keyboard(title: "Launch arguments", text: own.arguments, placeholder: "For example -DX12",
                                     maxLength: 200) { settings.wrappedValue.arguments = $0 }
        }
    }

    // Game: version, cloud saves, check game files, achievements, report a problem, uninstall.
    @ViewBuilder
    private func gameRows(_ t: InstalledTitle, _ g: SteamGame?) -> some View {
        let settings = launchSettings.binding(for: t.id)
        PadSectionHeader(text: "Game").id("game")
        if let g, t.source == .installed, branches.count > 1 {
            PadRow(id: "opt:version", title: "Version", value: BranchLabel.text(t.branch, in: g.info), accessory: .chevron,
                   style: .plain) { if job == nil { pickVersion(g) } }
        }
        if let app = t.appID {
            let cloudOn = settings.wrappedValue.cloudSync ?? true
            let cloud = cloudStatus(t)
            if SteamAccountModel.cloudOn {
                PadRow(id: "opt:cloud", title: "Cloud saves", subtitle: cloudOn ? cloudDetail(app) : nil,
                       accessory: .toggle(cloudOn), changed: !cloudOn, style: .plain, hint: cloudOn ? "Turn off" : "Turn on",
                       reset: cloudOn ? nil : { settings.wrappedValue.cloudSync = nil }) {
                    settings.wrappedValue.cloudSync = cloudOn ? false : nil
                }
            } else {
                PadRow(id: "opt:cloud", title: "Cloud saves", value: cloud.0, style: .plain, hint: "Settings") {}
            }
            if cloudOn, SteamAccountModel.cloudOn, let c = model.cloud[app], !c.conflicts.isEmpty {
                // One choice for the game's saves, as Play asks it (UI/CloudConflictView.swift).
                PadRow(id: "opt:conflict", title: "Choose which save to keep",
                       subtitle: "\(c.conflicts.count) file\(c.conflicts.count == 1 ? "" : "s") changed here and on Steam",
                       value: "Choose", accessory: .chevron, style: .plain, hint: "Choose") {
                    guard !model.cloudSyncing.contains(app), !launch.running else { return }
                    library.askCloud(t, app, c.conflicts, thenPlay: false)
                }
            }
        }
        if t.store != .steam, t.source != .cohort { localRows(t) }
        filesRows(t)
        if let s = stats, !s.schema.achievements.isEmpty {
            PadRow(id: "opt:achievements", title: "Achievements", value: "\(s.unlockedCount) of \(s.schema.achievements.count)",
                   accessory: .chevron, style: .plain, hint: "Open") { navigation.gamePanels.append(.achievements) }
        }
        PadRow(id: "opt:report", title: "Report a problem", value: "Shares a log", accessory: .chevron, style: .plain,
               hint: "Share") { ProblemReport.share(t) }
        uninstallRow(t)
    }

    /// A game that came without a store's launch record (imported, found, or another
    /// store's copy): which executable Play starts, and the name it shows.
    @ViewBuilder
    private func localRows(_ t: InstalledTitle) -> some View {
        let machine = t.executableMachine.map(Self.machineName)
        PadRow(id: "opt:executable", title: "Executable",
               subtitle: [machine, t.direct3D.flatMap { $0.apis.isEmpty ? nil : $0.summary }].compactMap { $0 }.joined(separator: " · "),
               value: t.executable ?? "None found", accessory: .chevron, changed: t.chosenExecutable != nil, style: .plain,
               hint: "Choose", reset: t.chosenExecutable == nil ? nil : { library.setExecutable(t.id, nil) }) {
            let dir = LibraryModel.paths.games.appendingPathComponent(t.installDir, isDirectory: true)
            let found = Adoption.candidates(in: dir, folder: t.installDir)
            guard !found.isEmpty else { return }
            PadModal.shared.picker(
                title: "Executable", context: "\(context) · Game",
                note: "What Play starts. The first is Playport's own pick; installers, tools and crash reporters are last.",
                options: [PadOption(id: "", label: "Default", detail: found.first.map { "\($0), Playport's pick" })]
                    + found.map { PadOption(id: $0, label: $0) },
                selected: t.chosenExecutable ?? "") { library.setExecutable(t.id, $0.isEmpty ? nil : $0) }
        }
        PadRow(id: "opt:name", title: "Name", value: t.name, accessory: .chevron, changed: t.displayName != nil, style: .plain,
               hint: "Edit", reset: t.displayName == nil ? nil : { library.rename(t.id, nil) }) {
            PadModal.shared.keyboard(title: "Name", text: t.name, placeholder: t.installDir, maxLength: 80) { library.rename(t.id, $0) }
        }
    }

    static func machineName(_ m: UInt16) -> String {
        switch m {
        case 0x8664: "x86-64"
        case 0x14C: "32-bit x86"
        case 0xAA64: "ARM64"
        default: String(format: "machine 0x%04X", m)
        }
    }

    @ViewBuilder
    private func filesRows(_ t: InstalledTitle) -> some View {
        let checking = library.verifying.contains(t.id)
        let canCheck = library.canVerify(t) && !launch.running && !library.removing.contains(t.id) && job == nil
        PadRow(id: "opt:files", title: "Check game files", subtitle: verifyError(t), value: filesValue(t, checking: checking),
               style: .plain, hint: "Check") {
            if canCheck, !checking { library.verify(t.id) }
        }
        if t.source == .installed, let app = t.appID, job == nil, !checking, t.lastVerification.map({ !$0.ok }) ?? false {
            PadRow(id: "opt:repair", title: "Repair from Steam", subtitle: "Downloads the damaged files again",
                   accessory: .chevron, style: .plain, hint: "Repair") {
                if !installs.suspended, !launch.running { installs.repair(app, name: t.name) }
            }
        }
        if t.store == .gog, job == nil, !checking, t.lastVerification.map({ !$0.ok }) ?? false {
            PadRow(id: "opt:repair", title: "Repair from GOG", subtitle: "Downloads the damaged files again",
                   accessory: .chevron, style: .plain, hint: "Repair") {
                if !installs.suspended, !launch.running { gog.install(t.key.id, name: t.name, kind: .repair) }
            }
        }
    }

    private func filesValue(_ t: InstalledTitle, checking: Bool) -> String {
        if checking { return "Checking…" }
        if !library.canVerify(t) { return "Store installs only" }
        guard let v = t.lastVerification else { return "Not checked yet" }
        let when = v.date.formatted(.relative(presentation: .named))
        return v.ok ? "Last OK \(when)" : "\(v.bad) of \(v.files) damaged"
    }

    private func verifyError(_ t: InstalledTitle) -> String? {
        guard let e = library.verifyErrors[t.id] else { return nil }
        #if PLAYPORT_RELEASE
        _ = e
        return "The check could not finish. Try again."
        #else
        return e
        #endif
    }

    @ViewBuilder
    private func uninstallRow(_ t: InstalledTitle) -> some View {
        let removing = library.removing.contains(t.id)
        let downloading = installs.jobs[t.key]?.isRunning ?? false
        PadRow(id: "opt:uninstall", title: removing ? "Uninstalling…" : "Uninstall", subtitle: removeError(t),
               value: t.sizeBytes.map { "Frees \(ByteCount.format($0))" }, destructive: true, style: .plain, hint: "Uninstall") {
            guard !removing, !launch.running, !library.verifying.contains(t.id), !downloading else { return }
            let again = t.source == .installed
                ? "You can install it again from the Library."
                : "To play it again, copy it into Playport again."
            PadModal.shared.picker(
                title: "Uninstall \(t.name)?", context: context,
                note: "Saves the game keeps in its own folder are deleted with it; saves in Playport's Windows user folder stay. " + again,
                options: [PadOption(id: "keep", label: "Keep it"),
                          PadOption(id: "uninstall", label: "Uninstall", detail: t.sizeBytes.map { "Frees \(ByteCount.format($0))" })],
                selected: nil) { choice in
                guard choice == "uninstall" else { return }
                navigation.gamePanels = []
                library.uninstall(t.id)
            }
        }
    }

    private func removeError(_ t: InstalledTitle) -> String? {
        guard let e = library.removeErrors[t.id] else { return nil }
        #if PLAYPORT_RELEASE
        _ = e
        return "The game could not be removed. Try again."
        #else
        return e
        #endif
    }

    private func cloudDetail(_ app: UInt32) -> String? {
        if model.cloudSyncing.contains(app) { return "Syncing saves…" }
        if let e = model.cloudErrors[app] { return "Not synced: " + e }
        guard let c = model.cloud[app] else { return nil }
        var s = "Synced " + c.at.formatted(date: .omitted, time: .shortened)
        if !c.downloaded.isEmpty || !c.uploaded.isEmpty { s += " · \(c.downloaded.count) from Steam, \(c.uploaded.count) to Steam" }
        if !c.failed.isEmpty { s += " · \(c.failed.count) failed" }
        return s
    }

    // MARK: Developer (dev builds)

    #if !PLAYPORT_RELEASE
    /// FEX's four ordering switches, its block size and x87 precision over the game's profile, madeira.cfg
    /// keys over the game's own, the steam_api the game loads, and the build's facts. Not in the player's app (decision 0034).
    @ViewBuilder
    private func developerRows(_ t: InstalledTitle) -> some View {
        let settings = launchSettings.binding(for: t.id)
        let exe = (try? t.launchPlan(cohort: LibraryModel.cohort))?.exe ?? ""
        let profile = FEXProfile.defaults(appID: t.appID, exe: exe)
        let onOff: (Bool) -> String = { $0 ? "On" : "Off" }
        PadSectionHeader(text: "Developer").id("developer")
        ForEach(MemoryOrdering.Setting.allCases, id: \.self) { s in
            let v = OptionValue.of(own: settings.wrappedValue.ordering[s], inherited: profile[s] == true, name: onOff)
            PadRow(id: "opt:ordering-\(s.rawValue)", title: LaunchSettingsText.ordering(s), value: v.text, accessory: .chevron,
                   changed: v.changed, style: .plain, reset: v.changed ? { settings.wrappedValue.ordering[s] = nil } : nil) {
                PadModal.shared.picker(
                    title: LaunchSettingsText.ordering(s), context: "\(context) · x86 memory ordering", note: LaunchSettingsText.orderingFooter,
                    options: [PadOption(id: "", label: "Default", detail: "\(onOff(profile[s] == true)), the game's profile"),
                              PadOption(id: "on", label: "On"), PadOption(id: "off", label: "Off")],
                    selected: settings.wrappedValue.ordering[s].map { $0 ? "on" : "off" } ?? "") {
                    settings.wrappedValue.ordering[s] = $0.isEmpty ? nil : $0 == "on"
                }
            }
        }
        let block = OptionValue.of(own: settings.wrappedValue.maxInst, inherited: FEXProfile.defaultBlockSize(appID: t.appID, exe: exe)) {
            "\($0) instructions"
        }
        PadRow(id: "opt:maxInst", title: "Block size", value: block.text, accessory: .chevron, changed: block.changed, style: .plain,
               reset: block.changed ? { settings.wrappedValue.maxInst = nil } : nil) {
            PadModal.shared.picker(
                title: "Block size", context: "\(context) · x86 emulator", note: LaunchSettingsText.orderingFooter,
                options: [PadOption(id: "", label: "Default",
                                    detail: "\(FEXProfile.defaultBlockSize(appID: t.appID, exe: exe)), the game's profile")]
                    + FEXProfile.blockSizes.map { PadOption(id: String($0), label: "\($0) instructions") },
                selected: settings.wrappedValue.maxInst.map(String.init) ?? "") { settings.wrappedValue.maxInst = Int($0) }
        }
        let x87Profile = FEXProfile.defaultX87Reduced(appID: t.appID, exe: exe)
        let x87Name: (Bool) -> String = { $0 ? "64-bit" : "80-bit" }
        let x87 = OptionValue.of(own: settings.wrappedValue.x87Reduced, inherited: x87Profile, name: x87Name)
        PadRow(id: "opt:x87Reduced", title: "x87 precision", value: x87.text, accessory: .chevron, changed: x87.changed,
               style: .plain, reset: x87.changed ? { settings.wrappedValue.x87Reduced = nil } : nil) {
            PadModal.shared.picker(
                title: "x87 precision", context: "\(context) · x86 emulator", note: LaunchSettingsText.x87Footer,
                options: [PadOption(id: "", label: "Default", detail: "\(x87Name(x87Profile)), the game's profile"),
                          PadOption(id: "reduced", label: "64-bit"), PadOption(id: "full", label: "80-bit")],
                selected: settings.wrappedValue.x87Reduced.map { $0 ? "reduced" : "full" } ?? "") {
                settings.wrappedValue.x87Reduced = $0.isEmpty ? nil : $0 == "reduced"
            }
        }
        let cacheName: (Bool) -> String = { $0 ? "On" : "Off" }
        let cache = OptionValue.of(own: settings.wrappedValue.diskCache, inherited: FEXProfile.defaultDiskCache, name: cacheName)
        PadRow(id: "opt:diskCache", title: "Disk cache", value: cache.text, accessory: .chevron, changed: cache.changed,
               style: .plain, reset: cache.changed ? { settings.wrappedValue.diskCache = nil } : nil) {
            PadModal.shared.picker(
                title: "Disk cache", context: "\(context) · x86 emulator", note: LaunchSettingsText.diskCacheFooter,
                options: [PadOption(id: "", label: "Default", detail: cacheName(FEXProfile.defaultDiskCache)),
                          PadOption(id: "on", label: "On"), PadOption(id: "off", label: "Off")],
                selected: settings.wrappedValue.diskCache.map { $0 ? "on" : "off" } ?? "") {
                settings.wrappedValue.diskCache = $0.isEmpty ? nil : $0 == "on"
            }
        }
        let keys = settings.wrappedValue.runtime.trimmingCharacters(in: .whitespaces)
        PadRow(id: "opt:runtime", title: "Runtime keys",
               subtitle: keys.isEmpty || LaunchSettings.runtimeKeys(keys) != nil ? nil : "Not key=value items: not used",
               value: keys.isEmpty ? "None" : keys, accessory: .chevron, changed: !keys.isEmpty, style: .plain,
               reset: keys.isEmpty ? nil : { settings.wrappedValue.runtime = "" }) {
            PadModal.shared.keyboard(title: "Runtime keys", text: settings.wrappedValue.runtime,
                                     placeholder: "For example vram-mb=1024 inproc-sync=1",
                                     maxLength: 200) { settings.wrappedValue.runtime = $0 }
        }
        if let app = t.appID {
            let mode = settings.wrappedValue.steamAPI ?? .emulated
            PadRow(id: "opt:steamAPI", title: "Steam API", value: Self.steamAPIModeText(mode), accessory: .chevron,
                   changed: settings.wrappedValue.steamAPI != nil, style: .plain,
                   reset: settings.wrappedValue.steamAPI == nil ? nil : { settings.wrappedValue.steamAPI = nil }) {
                PadModal.shared.picker(
                    title: "Steam API", context: "\(context) · Steam",
                    note: "The game's own Steam API needs Steam running, which Playport does not run: games that check for "
                        + "Steam will not start. Changes apply from the game's next launch.",
                    options: [PadOption(id: SteamAPISwap.Mode.emulated.rawValue, label: Self.steamAPIModeText(.emulated), detail: "Default"),
                              PadOption(id: SteamAPISwap.Mode.original.rawValue, label: Self.steamAPIModeText(.original))],
                    selected: mode.rawValue) {
                    let m = SteamAPISwap.Mode(rawValue: $0) ?? .emulated
                    settings.wrappedValue.steamAPI = m == .emulated ? nil : m
                }
            }
            developerFacts(t, app)
            PadRow(id: "opt:cloud-forget", title: "Forget the cloud sync",
                   subtitle: "The next sync is a first one: a save that differs from Steam's is a conflict",
                   style: .plain, hint: "Forget") {
                guard !model.cloudSyncing.contains(app), !launch.running else { return }
                Task { await model.forgetCloud(app) }
            }
            let busy = model.gameProfileLoading.contains(app) || model.statsSyncing.contains(app)
            PadRow(id: "opt:steam-refresh", title: "Update from Steam", subtitle: model.gameProfileErrors[app] ?? model.statsErrors[app],
                   value: busy ? "Asking Steam…" : nil, style: .plain, hint: "Update") {
                guard !busy, signedIn, !launch.running else { return }
                Task {
                    await model.loadGameProfile(app, refresh: true)
                    await model.syncStats(app)
                    await model.syncCloud(app)
                }
            }
        } else {
            developerFacts(t, nil)
        }
    }

    /// The build's facts, as grey lines.
    private func developerFacts(_ t: InstalledTitle, _ app: UInt32?) -> some View {
        let g = game
        var lines: [(String, String)] = []
        if let b = t.buildID { lines.append(("Build", String(b))) }
        if let b = g?.info.depots.buildID(branch: selectedBranch), b != t.buildID { lines.append(("Steam build", String(b))) }
        if let app { lines.append(("Steam app", String(app))) }
        lines.append(("Folder", "C:\\Games\\\(t.installDir)"))
        lines.append(("Executable", t.executable ?? "none found"))
        if let state = steamAPIState { lines.append(("In the game's folder", Self.steamAPIText(state))) }
        for site in steamStubs {
            lines.append(("Steam DRM", Self.steamStubText(site, mode: launchSettings.settings(for: t.id).steamAPI ?? .emulated)))
        }
        if let app, let profile = model.gameProfiles[app] {
            lines.append(("Player", profile.personaName ?? "Not known yet"))
            lines.append(("DLC", profile.dlc.isEmpty ? "None owned" : "\(profile.dlc.count) owned"))
        }
        if let note = t.note { lines.append(("Note", note)) }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(lines.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(lines[i].0).foregroundStyle(PP.muted)
                    Spacer(minLength: 8)
                    Text(lines[i].1).foregroundStyle(PP.soft).multilineTextAlignment(.trailing)
                }
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private static func steamAPIModeText(_ m: SteamAPISwap.Mode) -> String {
        switch m {
        case .emulated: "Playport's emulator"
        case .original: "The game's own"
        }
    }

    private static func steamStubText(_ site: SteamStub.Site, mode: SteamAPISwap.Mode) -> String {
        if site.info.unsupported != nil { return "\(site.info.label), can't be removed yet" }
        if site.removed { return mode == .emulated ? "Removed (\(site.info.label))" : "Removed; back at next launch" }
        return mode == .emulated ? "\(site.info.label), removed at next launch" : site.info.label
    }

    private static func steamAPIText(_ s: SteamAPISwap.State) -> String {
        switch s {
        case .none: "No steam_api"
        case .original: "The game's own"
        case .emulated: "Playport's emulator"
        case .mixed: "Partly swapped"
        }
    }
    #endif

    // MARK: achievements

    /// The game's achievements on Steam: unlocked ones first, newest first, then the rest.
    private var achievementsPanel: some View {
        let s = stats
        let all = s?.schema.achievements ?? []
        let sorted = all.enumerated().sorted { l, r in
            let lt = s?.unlockTime(l.element) ?? 0, rt = s?.unlockTime(r.element) ?? 0
            let lu = s?.unlocked(l.element) ?? false, ru = s?.unlocked(r.element) ?? false
            if lu != ru { return lu }
            if lu, lt != rt { return lt > rt }
            return l.offset < r.offset
        }.map(\.element)
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(context) · \(s?.unlockedCount ?? 0) of \(all.count)").font(.system(size: 12)).foregroundStyle(PP.muted)
                .padding(.horizontal, 14)
            Text("Achievements").font(PP.display(22)).foregroundStyle(PP.text)
                .padding(.horizontal, 14).padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(sorted.indices, id: \.self) { i in
                            achievementRow(sorted[i], s, id: "ach:\(i)")
                        }
                        if !(s?.schema.achievements.isEmpty ?? true) {
                            Text("From Steam. What a play unlocks goes to Steam when Playport next opens.")
                                .font(.system(size: 12)).foregroundStyle(PP.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.top, 8)
                        }
                    }
                    .padding(.bottom, 18)
                }
                .onChange(of: focus.focused) { _, id in
                    guard let id, id.hasPrefix("ach:") else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
            }
        }
        .padding(.top, 18).padding(.leading, 20).padding(.trailing, 28)
    }

    private func achievementRow(_ a: StatsSchema.Achievement, _ s: UserStatsSnapshot?, id: String) -> some View {
        let unlocked = s?.unlocked(a) ?? false
        let time = s?.unlockTime(a) ?? 0
        let selected = focus.focused == id
        let hidden = a.hidden && !unlocked
        return HStack(spacing: 12) {
            Image(systemName: unlocked ? "trophy.fill" : "lock.fill")
                .font(.system(size: 14))
                .foregroundStyle(unlocked ? PP.accent : selected ? Color(hex: 0x3A4452) : PP.muted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(hidden ? "Hidden achievement" : a.text(a.displayName)).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? PP.background : unlocked ? PP.text : PP.soft)
                let desc = hidden ? "Unlock it to see what it is." : a.text(a.description)
                if !desc.isEmpty, desc != a.name {
                    Text(desc).font(.system(size: 12)).foregroundStyle(selected ? Color(hex: 0x3A4452) : PP.muted)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if unlocked, time > 0 {
                Text(Date(timeIntervalSince1970: TimeInterval(time)).formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 12)).foregroundStyle(selected ? Color(hex: 0x3A4452) : PP.muted)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .frame(minHeight: 44)
        .background(selected ? PP.text : .clear, in: RoundedRectangle(cornerRadius: 10))
        .padItem(id, hint: "", cornerRadius: 10, ring: false) {}
    }
}

// MARK: buttons

/// The page's big amber button (Play, Install), with A on it.
private struct PrimaryButton: View {
    let id: String
    let title: String
    var enabled = true
    let hint: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PadGlyph(button: .a, inverted: enabled)
            Text(title).font(PP.display(20)).lineLimit(1)
        }
        .foregroundStyle(enabled ? PP.onAccent : PP.muted)
        .padding(.leading, 14).padding(.trailing, 26)
        .frame(height: 52)
        .background(enabled ? PP.accent : PP.raised, in: RoundedRectangle(cornerRadius: 12))
        .padItem(id, hint: hint, cornerRadius: 12) { if enabled { action() } }
    }
}

/// A dark button beside it (achievements, Options, Update), with its button glyph when it has one.
private struct SecondaryButton: View {
    let id: String
    let systemImage: String?
    let title: String
    var glyph: NavButton?
    var enabled = true
    let hint: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 14)) }
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            if let glyph { PadGlyph(button: glyph).padding(.leading, 2) }
        }
        .foregroundStyle(enabled ? PP.text : PP.muted)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(PP.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
        .padItem(id, hint: hint, cornerRadius: 10) { if enabled { action() } }
    }
}

// MARK: report a problem

/// Report a problem: the system share sheet with the app's log (playport.log in the
/// player's app, s1-host.log in a dev build, which hold the game's last run) and the
/// logs a game left on drive C, for the player to send where they like.
@MainActor
enum ProblemReport {
    static func files() -> [URL] {
        let fm = FileManager.default
        var urls = [AppLog.url]
        #if PLAYPORT_RELEASE
        urls.append(AppLog.url.deletingLastPathComponent().appendingPathComponent(AppLog.previousName))
        #endif
        let driveC = LibraryModel.paths.games.deletingLastPathComponent()
        urls += ((try? fm.contentsOfDirectory(at: driveC, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return urls.filter { fm.fileExists(atPath: $0.path) }
    }

    static func share(_ t: InstalledTitle) {
        let urls = files()
        LibraryModel.log("report a problem for \(t.id): sharing \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        present(urls)
    }

    /// The system share sheet with `urls` (also a dev build's Settings › Developer › logs).
    static func present(_ urls: [URL]) {
        guard !urls.isEmpty,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                  .first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        }
        top.present(sheet, animated: true)
        shown = sheet
    }

    /// The share sheet `present` put up, while it is on screen. It takes no
    /// controller focus, so the shell keeps the pad's presses from the page
    /// under it (AppShell.press) and B closes it.
    private static weak var shown: UIViewController?
    static var sheetUp: Bool { shown.map { $0.presentingViewController != nil && !$0.isBeingDismissed } ?? false }

    /// A pad press while the sheet is up: B closes it, the rest do nothing.
    static func sheetPress(_ b: NavButton) {
        if b == .b { shown?.dismiss(animated: true) }
    }
}

/// What the player is told about JIT before and during a launch (JitProvider).
enum JitNote {
    static let beforePlay = "JIT comes from Playport's own helper over LocalDevVPN, which Play turns on when it is off."
    static let waiting = "Playport's JIT helper is attaching. Keep Playport open."
    static let waitingForStikDebug = "Waiting for StikDebug to enable JIT. It comes back to Playport when it is done."
    static let waitingForAnotherApp = "Waiting for JIT from another app. Enable JIT for Playport there now, with the universal.js script."

    /// Why a game ended on running out of its JIT pool (LaunchMessage). Every Play
    /// gets the same pool (JitPool.sizeMB, decision 0036); only a dev build's simulated
    /// one is smaller. One that went on running was ended by the restart (decision 0030).
    static func outOfMemory(_ part: JitPool.Exhaustion, poolMB: Int) -> String {
        let what = switch part {
        case .head: "the game's program files"
        case .tail: "the code Playport translated for it"
        case .alias: "the code the game compiled as it ran"
        }
        let size = poolMB > 0 ? "\(MemoryNeed.format(mb: poolMB)) of " : ""
        let more = poolMB > 0 && poolMB < JitPool.minimumMB
            ? "Less than usual was set aside: Settings › Developer's Simulated JIT memory makes it smaller."
            : "This game needs more than Playport sets aside."
        return "Playport set aside \(size)JIT memory for the game, and \(what) filled it. \(more)"
    }
}
