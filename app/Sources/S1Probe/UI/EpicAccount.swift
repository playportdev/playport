// SPDX-License-Identifier: GPL-3.0-or-later
// Epic Games in the app (docs/plans/2026-10-06-pc-import-gog-epic.md, Phase 3), as
// GOGAccount.swift is GOG's: the sign-in (a WKWebView sheet on Epic's login page,
// whose redirect page is JSON with the code; decision 0058), the owned library
// (cached, listed offline), the art, and the Epic driver of the download queue:
// install, update and repair through EpicClientKit's EpicInstaller. After an
// install the store receipt names the manifest's launch executable and the
// arguments of plan 3.4 (no exchange code). A Play signs the game in (decision
// 0059, `launchSignIn`): a fresh exchange code, who is signed in, and for a game
// whose catalogue asks for it an ownership token. A game that uses anti-cheat or
// another company's launcher is refused before an install.

import Combine
import ContentKit
import EpicClientKit
import Foundation
import PlayportKit
import SteamClientKit
import SwiftUI
import UIKit
import WebKit

@MainActor
final class EpicAccount: ObservableObject, DownloadDriver {
    static let shared = EpicAccount()

    enum State: Equatable { case unknown, signedOut, signedIn }

    @Published private(set) var state = State.unknown
    @Published private(set) var games: [EpicGame] = []
    @Published private(set) var gamesFetchedAt: Date?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// The live build per installed game, once asked (an Update shows when it differs).
    @Published private(set) var newest: [String: String] = [:]
    /// Refusals found in a manifest (anti-cheat), shown on the page from then on.
    @Published private(set) var refused: [String: String] = [:]
    /// The sign-in sheet is up.
    @Published var signingIn = false

    let session: EpicSession
    private let log = SteamUILog.logger
    private weak var downloads: Downloads?
    nonisolated static let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Playport/epic/games.json")
    nonisolated static let art = SteamPaths.art.appendingPathComponent("epic", isDirectory: true)

    private init() {
        #if canImport(Security)
        session = EpicSession(store: KeychainSecretStore(service: EpicSession.keychainService), log: SteamUILog.logger)
        #else
        session = EpicSession(store: MemorySecretStore(), log: SteamUILog.logger)
        #endif
        if let data = try? Data(contentsOf: Self.cache), let c = try? JSONDecoder.gogCache.decode(Cache.self, from: data) {
            games = c.games
            gamesFetchedAt = c.at
            // Only a manifest's anti-cheat refusal is kept: one an older build cached for a game it
            // could not sign in, or for Epic's JSON manifest form, no longer holds.
            refused = (c.refused ?? [:]).filter { $0.value == EpicManifest.usesAntiCheat }
        }
    }

    private struct Cache: Codable {
        var at: Date
        var games: [EpicGame]
        var refused: [String: String]?
    }

    private func saveCache() {
        guard let at = gamesFetchedAt else { return }
        try? FileManager.default.createDirectory(at: Self.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.gogCache.encode(Cache(at: at, games: games, refused: refused)).write(to: Self.cache, options: .atomic)
    }

    func attach(_ downloads: Downloads) {
        self.downloads = downloads
        downloads.register(self, for: .epic)
        Task { await restore() }
    }

    /// At start: whether a session is kept; a library older than a day is fetched again.
    func restore() async {
        state = await session.state == .signedIn ? .signedIn : .signedOut
        downloads?.conditionsChanged(letGoOf: state == .signedIn ? .epic : nil, stopBlocked: false)
        if state == .signedIn, gamesFetchedAt.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true { await loadGames() }
    }

    func signIn(code: Secret<String>) async {
        do {
            try await session.signIn(code: code)
            state = .signedIn
            error = nil
            downloads?.conditionsChanged(letGoOf: .epic)
            await loadGames()
        } catch {
            log.warn("epic", "sign-in failed: \(error)")
            self.error = InstallCopy.detailed("Epic did not accept the sign-in. Try again.", error)
        }
    }

    func signOut() async {
        await session.signOut()
        // No game keeps an ownership token of the account (decision 0059).
        await LibraryModel.shared.removeEpicOwnershipFiles("at sign-out").value
        state = .signedOut
        games = []
        gamesFetchedAt = nil
        try? FileManager.default.removeItem(at: Self.cache)
        downloads?.holdAll(of: .epic, .stopped("Paused: signed out of Epic Games."))
        log.info("epic", "signed out")
    }

    func loadGames() async {
        guard state == .signedIn, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let list = try await EpicLibrary.owned(session)
            games = list
            gamesFetchedAt = Date()
            error = nil
            saveCache()
            log.info("epic", "library: \(list.count) Windows games")
        } catch ClientError.notLoggedOn {
            state = .signedOut
        } catch {
            log.warn("epic", "library failed: \(error)")
            self.error = InstallCopy.detailed("Epic Games can't be reached.", error)
        }
    }

    func game(_ app: String) -> EpicGame? { games.first { $0.id == app } }

    /// Why the game is not installed by Playport, or nil.
    func refusal(_ app: String) -> String? { game(app)?.refusal ?? refused[app] }

    /// What a Play needs to start the game signed in (decision 0059).
    struct LaunchSignIn {
        var auth: EpicLaunchAuth
        /// For `-epicovt`, when the catalogue asks for one.
        var ownershipToken: Secret<String>?
    }

    /// A fresh exchange code, who is signed in, and the ownership token when the catalogue
    /// asks for one. Throws when Epic is signed out or cannot be reached: the Play then
    /// asks the player (LibraryModel.play).
    func launchSignIn(_ app: String, installDir: String) async throws -> LaunchSignIn {
        guard await session.state == .signedIn else { throw ClientError.notLoggedOn }
        guard let rec = installer.loadRecord(app) else { throw ClientError.notFound("no Epic install record for \(app)") }
        if game(app) == nil { await loadGames() }
        let needsToken = game(app)?.needsOwnershipToken ?? false
        let account = try await session.account()
        let token = needsToken ? try await session.ownershipToken(namespace: rec.namespace, catalogItem: rec.catalogItemID) : nil
        // The code last: it lives five minutes from here.
        let code = try await session.exchangeCode()
        return LaunchSignIn(auth: EpicLaunchAuth(exchangeCode: code, account: account, namespace: rec.namespace,
                                                 ownershipFile: needsToken ? EpicOwnershipFile.windowsPath(installDir: installDir) : nil),
                            ownershipToken: token)
    }

    /// The live build of an installed game, asked once per process.
    func checkUpdate(_ app: String) async {
        guard state == .signedIn, newest[app] == nil, let g = game(app) else { return }
        if g.attributes["NeverUpdate"]?.lowercased() == "true" { return }
        do {
            let asset = try await installer.newestAsset(g)
            if try installer.refreshLaunchMetadata(app, asset: asset) {
                log.info("epic", "\(app): launch sidecar refreshed (revision \(asset.sidecarRvn.map(String.init) ?? "none"))")
                LibraryModel.shared.refresh()
            }
            newest[app] = asset.buildVersion
        } catch {
            log.warn("epic", "\(app): update/sidecar check failed: \(error)")
        }
    }

    var installer: EpicInstaller { EpicInstaller(layout: LibraryModel.paths.layout, session: session, log: log) }

    // MARK: queue

    func install(_ app: String, name: String, kind: DownloadJob.Kind = .install) {
        downloads?.enqueue(DownloadJob(key: StoreGameKey(store: .epic, id: app), name: name, kind: kind))
    }

    var blocker: String? {
        if state != .signedIn { return "Waiting for Epic Games" }
        let net = NetworkPath.shared
        if !net.connected { return "Waiting for a connection" }
        if !net.mayDownload { return "Waiting for Wi-Fi" }
        return nil
    }

    func run(_ job: DownloadJob, progress: @escaping @Sendable (InstallEngine.Progress) -> Void) async throws -> UInt64? {
        let app = job.key.id, installer = self.installer
        if games.isEmpty { await loadGames() }
        guard let g = game(app) else { throw ClientError.notFound("Epic does not list \(app) in this account's library") }
        var options = InstallEngine.Options()
        options.progressInterval = 0.5
        switch job.kind {
        case .install, .update:
            let r: EpicInstaller.Result
            do {
                r = try await installer.install(g, options: options, progress: progress)
            } catch let ClientError.unsupported(why) {
                refused[app] = why
                saveCache()
                throw ClientError.unsupported(why)
            }
            try writeReceipt(r.installed, game: g)
            newest[app] = r.installed.buildVersion
            log.info("epic", "\(job.key): build \(r.installed.buildVersion) in C:\\Games\\\(r.installed.installDir), \(r.filesChanged) files written")
            return job.kind == .install ? r.bytesWritten : r.downloadedBytes
        case .repair:
            let report = try await installer.repair(g, options: options, progress: progress)
            LibraryModel.shared.recordVerification(StoreGameKey(store: .epic, id: app).titleID, files: report.files, bad: report.bad)
            return nil
        case .import:
            throw ClientError.unsupported("an import is not an Epic job")
        }
    }

    /// The receipt adoption reads: the manifest's launch executable and plan 3.4's arguments.
    private func writeReceipt(_ r: EpicInstalled, game: EpicGame) throws {
        let layout = LibraryModel.paths.layout
        try layout.saveReceipt(StoreReceipt(store: .epic, storeID: r.appName, name: game.title, installDir: r.installDir,
                                            version: r.buildVersion, executable: r.launchExe.isEmpty ? nil : r.launchExe,
                                            arguments: EpicInstaller.arguments(r, game: game), workingDir: nil,
                                            files: r.files, bytes: r.bytes, installedAt: Date()))
    }

    func finished(_ job: DownloadJob) {}

    func discard(_ key: StoreGameKey) {
        let installer = self.installer
        Task.detached(priority: .utility) { installer.discardStages(key.id) }
    }

    func reason(_ error: Error) -> String {
        if case let .unsupported(why)? = error as? ClientError { return why }
        return InstallCopy.reason(error, store: "Epic Games")
    }
}

// MARK: art

/// An Epic game's 16:9 art from Epic's image CDN, kept under Caches (re-fetchable).
@MainActor
final class EpicArt: ObservableObject {
    static let shared = EpicArt()
    @Published private var images: [String: UIImage] = [:]
    private var loading = Set<String>()

    /// 800 wide (800×450) for a tile; 1920 behind a page and the launch screen.
    nonisolated static func width(wide: Bool) -> Int { wide ? 1920 : 800 }

    nonisolated static func file(_ app: String, wide: Bool) -> URL {
        EpicAccount.art.appendingPathComponent("\(StoreGameKey(store: .epic, id: app).fileStem)_\(width(wide: wide)).jpg")
    }

    /// The page backdrop already on disk, for the launch screen (TitleLaunch).
    nonisolated static func cachedHero(_ app: String) -> UIImage? {
        (try? Data(contentsOf: file(app, wide: true))).flatMap(UIImage.init(data:))
    }

    func image(_ g: EpicGame, wide: Bool) -> UIImage? {
        let key = "\(g.id)/\(wide)"
        if let i = images[key] { return i }
        guard let url = g.art(width: Self.width(wide: wide)), loading.insert(key).inserted else { return nil }
        let file = Self.file(g.id, wide: wide)
        Task.detached(priority: .utility) {
            var data = try? Data(contentsOf: file)
            if data == nil, let (d, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200 {
                try? FileManager.default.createDirectory(at: EpicAccount.art, withIntermediateDirectories: true)
                try? d.write(to: file, options: .atomic)
                data = d
            }
            let image = data.flatMap(UIImage.init(data:))
            await MainActor.run {
                if let image { EpicArt.shared.images[key] = image }
            }
        }
        return nil
    }
}

struct EpicArtView: View {
    let game: EpicGame
    var wide = false
    @ObservedObject private var art = EpicArt.shared

    var body: some View {
        ZStack {
            Rectangle().fill(PP.tile(for: game.title))
            if let i = art.image(game, wide: wide) { Image(uiImage: i).resizable().aspectRatio(contentMode: .fill) }
        }
        .clipped()
    }
}

// MARK: sign-in sheet

/// Epic's login page. It ends on Epic's redirect page, whose JSON carries the code;
/// a corrective action Epic asks for (an updated privacy policy) is said, with a
/// way to do it on Epic's site and try again.
struct EpicSignInSheet: View {
    @ObservedObject private var account = EpicAccount.shared
    @State private var notice: String?
    @State private var reload = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let notice {
                    Text(notice)
                        .font(.system(size: 13)).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
                EpicLoginWebView(reload: reload) { result in
                    switch result {
                    case let .code(code):
                        account.signingIn = false
                        Task { await account.signIn(code: code) }
                    case let .correctiveAction(what):
                        notice = what == "PRIVACY_POLICY_ACCEPTANCE"
                            ? "Epic asks you to accept its updated privacy policy first. Accept it on the page below, then tap Try again."
                            : "Epic asks for something on its site first (\(what)). Do it on the page below, then tap Try again."
                    case .none:
                        break
                    }
                }
            }
            .navigationTitle("Sign in to Epic Games")
            .onAppear { AppDelegate.allowsPortrait = true }
            .onDisappear { AppDelegate.allowsPortrait = false }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { account.signingIn = false } }
                if notice != nil {
                    ToolbarItem(placement: .primaryAction) { Button("Try again") { notice = nil; reload += 1 } }
                }
            }
        }
    }
}

struct EpicLoginWebView: UIViewRepresentable {
    /// Bumped to load the login page again.
    let reload: Int
    let done: (EpicAPI.RedirectPage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The login's cookies last only while the sheet is up (decision 0058): within it
        // a corrective action and Try again share them.
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: EpicAPI.loginURL))
        context.coordinator.loaded = reload
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != reload else { return }
        context.coordinator.loaded = reload
        context.coordinator.finished = false
        context.coordinator.relogins = 0
        view.load(URLRequest(url: EpicAPI.loginURL))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let done: (EpicAPI.RedirectPage) -> Void
        var finished = false
        var loaded = 0
        /// Times the redirect page said "not signed in" and the login page was loaded again.
        var relogins = 0

        init(done: @escaping (EpicAPI.RedirectPage) -> Void) { self.done = done }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url, EpicAPI.isRedirect(url), !finished else { return }
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self, weak webView] value, _ in
                guard let self, !self.finished else { return }
                let page = EpicAPI.redirectPage(Array(((value as? String) ?? "").utf8))
                switch page {
                case .code:
                    self.finished = true
                    // The code is not left on screen.
                    webView?.loadHTMLString("", baseURL: nil)
                    self.done(page)
                case .correctiveAction:
                    // Epic's account page, where the policy (or what else it asks) is shown.
                    webView?.load(URLRequest(url: URL(string: "https://www.epicgames.com/account/personal")!))
                    self.done(page)
                case .none:
                    // Not signed in yet: the login page (twice at most, so a page Epic changed cannot loop).
                    guard self.relogins < 2 else { return }
                    self.relogins += 1
                    webView?.load(URLRequest(url: EpicAPI.loginURL))
                }
            }
        }
    }
}

// MARK: Settings › Accounts

struct EpicAccountSettings: View {
    @ObservedObject private var account = EpicAccount.shared

    var body: some View {
        PadSectionHeader(text: "Epic Games")
        switch account.state {
        case .unknown:
            SettingsInfoRow(id: "epic:status", title: "Checking…", subtitle: nil)
        case .signedOut:
            SettingsInfoRow(id: "epic:status", title: "Not signed in", subtitle: account.error ?? "Your Epic games, installed from Epic's servers.")
            PadRow(id: "set:epic:signin", title: "Sign in to Epic Games", subtitle: "On Epic's own sign-in page", accessory: .chevron,
                   hint: "Sign in") { account.signingIn = true }
        case .signedIn:
            SettingsInfoRow(id: "epic:status", title: "Signed in", subtitle: "\(account.games.count) Windows games")
            PadRow(id: "set:epic:refresh", title: "Refresh library",
                   subtitle: account.error ?? account.gamesFetchedAt.map { "Fetched " + $0.formatted(.relative(presentation: .named)) },
                   value: account.loading ? "Asking Epic…" : nil, hint: "Refresh") {
                Task { await account.loadGames() }
            }
            PadRow(id: "set:epic:signout", title: "Sign out", subtitle: "Installed games stay. Playport ends the session at Epic.",
                   destructive: true, hint: "Sign out") {
                PadModal.shared.picker(
                    title: "Sign out of Epic Games?", context: "Settings · Accounts",
                    note: "Installed Epic games stay and still play. Downloads from Epic pause.",
                    options: [PadOption(id: "keep", label: "Stay signed in"), PadOption(id: "out", label: "Sign out")],
                    selected: "keep") { if $0 == "out" { Task { await account.signOut() } } }
            }
        }
    }
}
