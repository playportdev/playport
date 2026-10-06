// SPDX-License-Identifier: GPL-3.0-or-later
// GOG in the app (docs/plans/2026-10-06-pc-import-gog-epic.md, Phase 2): the
// sign-in (a WKWebView sheet on GOG's login page; decision 0058), the owned
// library (cached, listed offline), the art, and the GOG driver of the download
// queue: install, update and repair through GOGClientKit's GOGInstaller. After an
// install the store receipt is written from the goggame-ID.info the build carries
// (PlayportKit StoreMarkers), so the game launches with GOG's play task.

import Combine
import ContentKit
import Foundation
import GOGClientKit
import PlayportKit
import SteamClientKit
import SwiftUI
import UIKit
import WebKit

@MainActor
final class GOGAccount: ObservableObject, DownloadDriver {
    static let shared = GOGAccount()

    enum State: Equatable { case unknown, signedOut, signedIn }

    @Published private(set) var state = State.unknown
    @Published private(set) var games: [GOGGame] = []
    @Published private(set) var gamesFetchedAt: Date?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// The newest build per installed product, once asked (an Update shows when it differs).
    @Published private(set) var newest: [String: String] = [:]
    /// The sign-in sheet is up.
    @Published var signingIn = false

    let session: GOGSession
    private let log = SteamUILog.logger
    private weak var downloads: Downloads?
    nonisolated static let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Playport/gog/games.json")
    nonisolated static let art = SteamPaths.art.appendingPathComponent("gog", isDirectory: true)

    private init() {
        #if canImport(Security)
        session = GOGSession(store: KeychainSecretStore(service: GOGSession.keychainService), log: SteamUILog.logger)
        #else
        session = GOGSession(store: MemorySecretStore(), log: SteamUILog.logger)
        #endif
        if let data = try? Data(contentsOf: Self.cache), let c = try? JSONDecoder.gogCache.decode(Cache.self, from: data) {
            games = c.games
            gamesFetchedAt = c.at
        }
    }

    private struct Cache: Codable {
        var at: Date
        var games: [GOGGame]
    }

    func attach(_ downloads: Downloads) {
        self.downloads = downloads
        downloads.register(self, for: .gog)
        Task { await restore() }
    }

    /// At start: whether a session is kept; a library older than a day is fetched again.
    func restore() async {
        state = await session.state == .signedIn ? .signedIn : .signedOut
        downloads?.conditionsChanged(letGoOf: state == .signedIn ? .gog : nil, stopBlocked: false)
        if state == .signedIn, gamesFetchedAt.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true { await loadGames() }
    }

    func signIn(code: Secret<String>) async {
        do {
            try await session.signIn(code: code)
            state = .signedIn
            error = nil
            downloads?.conditionsChanged(letGoOf: .gog)
            await loadGames()
        } catch {
            log.warn("gog", "sign-in failed: \(error)")
            self.error = InstallCopy.detailed("GOG did not accept the sign-in. Try again.", error)
        }
    }

    func signOut() async {
        await session.signOut()
        state = .signedOut
        games = []
        gamesFetchedAt = nil
        try? FileManager.default.removeItem(at: Self.cache)
        downloads?.holdAll(of: .gog, .stopped("Paused: signed out of GOG."))
        log.info("gog", "signed out; the token was deleted (GOG has no revoke endpoint, so it lapses by itself)")
    }

    func loadGames() async {
        guard state == .signedIn, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let list = try await GOGLibrary.owned(session)
            games = list
            gamesFetchedAt = Date()
            error = nil
            try? FileManager.default.createDirectory(at: Self.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder.gogCache.encode(Cache(at: Date(), games: list)).write(to: Self.cache, options: .atomic)
            log.info("gog", "library: \(list.count) Windows games")
        } catch ClientError.notLoggedOn {
            state = .signedOut
        } catch {
            log.warn("gog", "library failed: \(error)")
            self.error = InstallCopy.detailed("GOG can't be reached.", error)
        }
    }

    func game(_ productID: String) -> GOGGame? { games.first { $0.id == productID } }

    /// The newest build of an installed game, asked once per process.
    func checkUpdate(_ productID: String) async {
        guard state == .signedIn, newest[productID] == nil else { return }
        if let b = try? await GOGContent.builds(session, productID: productID).first { newest[productID] = b.buildID }
    }

    var installer: GOGInstaller { GOGInstaller(layout: LibraryModel.paths.layout, session: session, log: log) }

    // MARK: queue

    /// `build`: a GOG build ID to install instead of the newest (kept in the job's branch field).
    func install(_ productID: String, name: String, kind: DownloadJob.Kind = .install, build: String? = nil) {
        downloads?.enqueue(DownloadJob(key: StoreGameKey(store: .gog, id: productID), name: name, kind: kind, branch: build))
    }

    var blocker: String? {
        if state != .signedIn { return "Waiting for GOG" }
        let net = NetworkPath.shared
        if !net.connected { return "Waiting for a connection" }
        if !net.mayDownload { return "Waiting for Wi-Fi" }
        return nil
    }

    func run(_ job: DownloadJob, progress: @escaping @Sendable (InstallEngine.Progress) -> Void) async throws -> UInt64? {
        let pid = job.key.id, installer = self.installer
        var options = InstallEngine.Options()
        options.progressInterval = 0.5
        switch job.kind {
        case .install, .update:
            let owned = Set(games.map(\.id))
            let r = try await installer.install(productID: pid, buildID: job.branch, owned: owned, options: options, progress: progress)
            try writeReceipt(r.installed, name: job.name)
            // Asked again: an older build installed on purpose shows its Update.
            newest[pid] = nil
            await checkUpdate(pid)
            log.info("gog", "\(job.key): build \(r.installed.buildID) in C:\\Games\\\(r.installed.installDir), \(r.filesChanged) files written")
            return job.kind == .install ? r.bytesWritten : r.downloadedBytes
        case .repair:
            let report = try await installer.repair(productID: pid, options: options, progress: progress)
            LibraryModel.shared.recordVerification(StoreGameKey(store: .gog, id: pid).titleID, files: report.files, bad: report.bad)
            return nil
        case .import:
            throw ClientError.unsupported("an import is not a GOG job")
        }
    }

    /// The receipt adoption reads: GOG's play task from the build's goggame-ID.info.
    private func writeReceipt(_ r: GOGInstalled, name: String) throws {
        let layout = LibraryModel.paths.layout
        let dir = layout.gamesRoot.appendingPathComponent(r.installDir, isDirectory: true)
        let marker = StoreMarkers.detect(in: dir)
        let bytes = r.files.reduce(UInt64(0)) { $0 + $1.size }
        try layout.saveReceipt(StoreReceipt(store: .gog, storeID: r.productID, name: marker?.name ?? name, installDir: r.installDir,
                                            version: r.buildID, executable: marker?.executable, arguments: marker?.arguments,
                                            workingDir: marker?.workingDir, files: r.files.count, bytes: bytes, installedAt: Date()))
    }

    func finished(_ job: DownloadJob) {}

    func discard(_ key: StoreGameKey) {
        let installer = self.installer
        Task.detached(priority: .utility) { installer.discardStages(key.id) }
    }

    func reason(_ error: Error) -> String { InstallCopy.reason(error, store: "GOG") }
}

extension JSONDecoder {
    static let gogCache: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let gogCache: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

// MARK: art

/// A GOG game's art from GOG's image CDN, kept under Caches (re-fetchable).
@MainActor
final class GOGArt: ObservableObject {
    static let shared = GOGArt()
    @Published private var images: [String: UIImage] = [:]
    private var loading = Set<String>()

    /// `_800` (800×370) for a tile; `_bg_crop_1920x655` behind a page.
    nonisolated static func suffix(wide: Bool) -> String { wide ? "_bg_crop_1920x655" : "_800" }

    /// The page backdrop already on disk, for the launch screen (TitleLaunch).
    nonisolated static func cachedHero(_ productID: String) -> UIImage? {
        (try? Data(contentsOf: GOGAccount.art.appendingPathComponent(productID + suffix(wide: true) + ".jpg"))).flatMap(UIImage.init(data:))
    }

    func image(_ g: GOGGame, wide: Bool) -> UIImage? {
        let suffix = Self.suffix(wide: wide)
        let key = "\(g.id)\(suffix)"
        if let i = images[key] { return i }
        guard let url = g.art(suffix), loading.insert(key).inserted else { return nil }
        let file = GOGAccount.art.appendingPathComponent(key + ".jpg")
        Task.detached(priority: .utility) {
            var data = try? Data(contentsOf: file)
            if data == nil, let (d, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200 {
                try? FileManager.default.createDirectory(at: GOGAccount.art, withIntermediateDirectories: true)
                try? d.write(to: file, options: .atomic)
                data = d
            }
            let image = data.flatMap(UIImage.init(data:))
            await MainActor.run {
                if let image { GOGArt.shared.images[key] = image }
            }
        }
        return nil
    }
}

struct GOGArtView: View {
    let game: GOGGame
    var wide = false
    @ObservedObject private var art = GOGArt.shared

    var body: some View {
        ZStack {
            Rectangle().fill(PP.tile(for: game.title))
            if let i = art.image(game, wide: wide) { Image(uiImage: i).resizable().aspectRatio(contentMode: .fill) }
        }
        .clipped()
    }
}

// MARK: sign-in sheet

/// GOG's login page; the redirect it ends on carries the code, which never loads.
struct GOGSignInSheet: View {
    @ObservedObject private var account = GOGAccount.shared

    var body: some View {
        NavigationStack {
            GOGLoginWebView { code in
                account.signingIn = false
                Task { await account.signIn(code: code) }
            }
            .navigationTitle("Sign in to GOG")
            .onAppear { AppDelegate.allowsPortrait = true }
            .onDisappear { AppDelegate.allowsPortrait = false }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { account.signingIn = false } }
            }
        }
    }
}

struct GOGLoginWebView: UIViewRepresentable {
    let done: (Secret<String>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Nothing of the login is kept on the phone beyond the token (decision 0058).
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: GOGAPI.loginURL))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let done: (Secret<String>) -> Void
        private var finished = false

        init(done: @escaping (Secret<String>) -> Void) { self.done = done }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, let code = GOGAPI.code(fromRedirect: url) {
                decisionHandler(.cancel)
                guard !finished else { return }
                finished = true
                done(code)
                return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: Settings › Accounts

struct GOGAccountSettings: View {
    @ObservedObject private var account = GOGAccount.shared

    var body: some View {
        PadSectionHeader(text: "GOG")
        switch account.state {
        case .unknown:
            SettingsInfoRow(id: "gog:status", title: "Checking…", subtitle: nil)
        case .signedOut:
            SettingsInfoRow(id: "gog:status", title: "Not signed in", subtitle: account.error ?? "Your GOG games, installed from GOG's servers.")
            PadRow(id: "set:gog:signin", title: "Sign in to GOG", subtitle: "On GOG's own sign-in page", accessory: .chevron,
                   hint: "Sign in") { account.signingIn = true }
        case .signedIn:
            SettingsInfoRow(id: "gog:status", title: "Signed in", subtitle: "\(account.games.count) Windows games")
            PadRow(id: "set:gog:refresh", title: "Refresh library",
                   subtitle: account.error ?? account.gamesFetchedAt.map { "Fetched " + $0.formatted(.relative(presentation: .named)) },
                   value: account.loading ? "Asking GOG…" : nil, hint: "Refresh") {
                Task { await account.loadGames() }
            }
            PadRow(id: "set:gog:signout", title: "Sign out", subtitle: "Installed games stay. GOG has no way to end the session, so it lapses by itself.",
                   destructive: true, hint: "Sign out") {
                PadModal.shared.picker(
                    title: "Sign out of GOG?", context: "Settings · Accounts",
                    note: "Installed GOG games stay and still play. Downloads from GOG pause.",
                    options: [PadOption(id: "keep", label: "Stay signed in"), PadOption(id: "out", label: "Sign out")],
                    selected: "keep") { if $0 == "out" { Task { await account.signOut() } } }
            }
        }
    }
}
