// SPDX-License-Identifier: GPL-3.0-or-later
// An installed Battle.net product's store region, language and updates, on its page (PLA-520,
// PLA-521): the region in place, without a download (every region's data is in the install, so
// only `.build.info` changes, BattleNetClientKit's changeRegion); the language as a Downloads job
// (an update of the installed build, PlayportKit BattleNet.languageJob) that fetches only the new
// locale's data, after which Play is available again; an update to the region's current build
// (BattleNet.updateJob), which every Play checks for first (BattleNetPlay) and the page's Check for
// update asks by hand, as a Downloads job that fetches only what changed. An install without the
// x64 client Play starts (one from before decision 0177) is updated the same way at its own build:
// the job fetches the x64 client's files and data, and the receipt names it after. What the
// install is in now is its `.build.info`'s, read when the page shows.

import BattleNetClientKit
import Foundation
import PlayportKit
import SteamClientKit
import SwiftUI

@MainActor
final class BattleNetInstalled: ObservableObject {
    static let shared = BattleNetInstalled()

    struct Choice: Equatable {
        var region: StoreRegion
        var locale: String
    }

    /// Each installed product's region and language, as its `.build.info` says.
    @Published private(set) var current: [BattleNetProduct: Choice] = [:]
    /// Products whose region is being changed.
    @Published private(set) var changingRegion: Set<BattleNetProduct> = []
    /// Why a product's last region change or update failed, worded for the player.
    @Published private(set) var errors: [BattleNetProduct: String] = [:]

    /// What the last update check of a product found.
    enum UpdateState: Equatable {
        case checking
        case current(String)
        case available(from: String, to: String, bytes: UInt64)
        /// The check failed; why, worded for the player.
        case unreachable(String)
    }

    @Published private(set) var updates: [BattleNetProduct: UpdateState] = [:]
    /// Plays to go on with once their update finished well in Downloads (this process only: a
    /// Play is not started by an update the player resumes later, nor by a language change).
    private var playsAfterUpdate = BattleNet.PlaysAfterUpdate()

    private let log = SteamUILog.logger

    private init() {}

    private func receipt(_ p: BattleNetProduct) -> StoreReceipt? {
        let file = LibraryModel.paths.layout.receiptFile(BattleNet.key(p))
        return (try? Data(contentsOf: file)).flatMap { try? StoreReceipt.decoder.decode(StoreReceipt.self, from: $0) }
    }

    /// The install's folder under C:\Games.
    private func root(_ p: BattleNetProduct) -> URL? {
        receipt(p).map { LibraryModel.paths.layout.gamesRoot.appendingPathComponent($0.installDir, isDirectory: true) }
    }

    /// Reads the install's region and language (the page does when it shows).
    func load(_ p: BattleNetProduct) {
        let folder = root(p)
        Task.detached(priority: .userInitiated) {
            let c = folder.flatMap { BattleNet.installedChoice(p, folder: $0) }
            await MainActor.run { self.current[p] = c.map { Choice(region: $0.region, locale: $0.locale) } }
        }
    }

    // MARK: region

    /// The region picker (PadModal), as the installed page's Region row opens it.
    func pickRegion(_ p: BattleNetProduct) {
        PadModal.shared.picker(title: "Store region", context: p.name,
                               note: "Your Battle.net account's region. The game signs in to it. Changing it downloads nothing.",
                               options: StoreRegion.allCases.map { PadOption(id: $0.rawValue, label: BattleNetStore.label($0)) },
                               selected: current[p]?.region.rawValue) { [weak self] id in
            guard let r = StoreRegion(rawValue: id) else { return }
            Task { _ = await self?.changeRegion(p, to: r) }
        }
    }

    /// Moves the install to `region`: `.build.info` is rewritten, nothing is downloaded. Returns
    /// why it failed, or nil.
    @discardableResult
    func changeRegion(_ p: BattleNetProduct, to region: StoreRegion) async -> String? {
        guard let root = root(p) else { return "\(p.name) is not installed" }
        guard current[p]?.region != region, !changingRegion.contains(p) else { return nil }
        changingRegion.insert(p)
        defer { changingRegion.remove(p) }
        do {
            let info = try await BattleNetInstaller(client: BattleNetStore.shared.client, log: log).changeRegion(p, root: root, to: region)
            current[p] = Choice(region: info.region, locale: info.locale ?? current[p]?.locale ?? BattleNet.defaultLocale)
            errors[p] = nil
            return nil
        } catch {
            log.warn("battlenet", "\(p.code): region change to \(region.rawValue) failed: \(error)")
            let why = BattleNetStore.shared.reason(error)
            errors[p] = why
            return why
        }
    }

    // MARK: language

    /// The locales the product ships (its product config's, from the store's listing).
    func locales(_ p: BattleNetProduct) async -> [String] {
        let store = BattleNetStore.shared
        if store.listing(p)?.supportedLocales.isEmpty ?? true { await store.refresh(force: true) }
        return store.listing(p)?.supportedLocales ?? []
    }

    /// `deDE` as the phone words it: `German (Germany) · deDE`.
    static func label(_ locale: String) -> String {
        name(locale).map { "\($0) · \(locale)" } ?? locale
    }

    /// `deDE`'s language alone, `German (Germany)`, for the page's narrow facts card.
    static func name(_ locale: String) -> String? {
        guard locale.count == 4 else { return nil }
        return Locale.current.localizedString(forIdentifier: "\(locale.prefix(2))_\(locale.suffix(2))")
    }

    /// The language picker (PadModal), as the installed page's Language row opens it.
    func pickLanguage(_ p: BattleNetProduct, downloads: Downloads) {
        Task {
            let locales = await locales(p)
            guard !locales.isEmpty else {
                errors[p] = BattleNetStore.shared.error ?? "The languages could not be read."
                return
            }
            PadModal.shared.picker(title: "Language", context: p.name,
                                   note: "The game's text and voices. A new language downloads its data in Downloads; Play is available again once it finishes.",
                                   options: locales.map { PadOption(id: $0, label: Self.label($0)) },
                                   selected: current[p]?.locale) { [weak self] id in
                self?.changeLanguage(p, to: id, downloads: downloads)
            }
        }
    }

    /// Queues the language change in Downloads. Returns why it was not queued, or nil.
    @discardableResult
    func changeLanguage(_ p: BattleNetProduct, to locale: String, downloads: Downloads) -> String? {
        guard let now = current[p] else { return "\(p.name) is not installed" }
        guard now.locale != locale else { return nil }
        errors[p] = nil
        log.info("battlenet", "\(p.code): language \(now.locale) → \(locale) queued")
        downloads.enqueue(BattleNet.languageJob(p, region: now.region, locale: locale))
        return nil
    }

    /// Downloads' run of a Battle.net update job: a language change (it names a locale), else an
    /// update to the region's current build.
    func run(_ p: BattleNetProduct, _ job: DownloadJob, client: BattleNetClient,
             progress: @escaping @Sendable (InstallEngine.Progress) -> Void) async throws -> UInt64? {
        let layout = LibraryModel.paths.layout
        guard let before = receipt(p), let root = root(p) else { throw ClientError.notFound("\(p.name) is not installed") }
        let work = BattleNet.workArea(p, layout: layout)
        var installer = BattleNetInstaller(client: client, log: log)
        installer.engine.progressInterval = 0.5
        guard let choice = BattleNet.jobChoice(job.branch) else {
            let prepared = try await installer.prepareUpdate(p, root: root, work: work)
            let r = try await installer.update(prepared, root: root, work: work, progress: progress)
            let version = prepared.plan.build.version.versionsName
            let measured = await BattleNet.measure(root)
            try layout.saveReceipt(BattleNet.receipt(before, measured: measured, version: version, client: prepared.clientPath))
            updates[p] = .current(version)
            log.info("battlenet", "\(p.code): updated \(before.version ?? "?") → \(version) in C:\\Games\\\(before.installDir), "
                     + "\(prepared.plan.objects) objects and \(prepared.plan.files.count) files, \(r.engine.downloadedBytes) bytes fetched "
                     + "in \(Int(r.seconds)) s")
            return r.engine.downloadedBytes
        }
        let prepared = try await installer.prepareLocaleChange(p, root: root, to: choice.locale, work: work)
        let r = try await installer.changeLocale(prepared, root: root, work: work, progress: progress)
        let measured = await BattleNet.measure(root)
        try layout.saveReceipt(BattleNet.receipt(before, measured: measured, client: prepared.clientPath))
        if let c = BattleNet.installedChoice(p, folder: root) { current[p] = Choice(region: c.region, locale: c.locale) }
        log.info("battlenet", "\(p.code): language \(choice.locale) in C:\\Games\\\(before.installDir), "
                 + "\(prepared.plan.objects) objects, \(r.engine.downloadedBytes) bytes fetched in \(Int(r.seconds)) s")
        return r.engine.downloadedBytes
    }

    // MARK: updates

    /// Asks the version endpoint of the install's region whether its build is current and the
    /// install holds the x64 client; when not, plans the update (its manifests stay in the work area
    /// for the Downloads job) for its size: a newer build's, or the x64 client's at the installed one.
    /// A failure is `unreachable`, worded by its kind for the player (no answer, a refusal or a
    /// 429, damaged data, BattleNet.reason): Play reports it and goes on.
    func checkUpdate(_ p: BattleNetProduct) async -> BattleNetPlay.Update {
        guard let root = root(p) else { return .unreachable("\(p.name) is not installed.") }
        updates[p] = .checking
        let installer = BattleNetInstaller(client: BattleNetStore.shared.client, log: log)
        do {
            let check = try await installer.checkUpdate(p, root: root)
            guard check.needsUpdate else {
                log.info("battlenet", "\(p.code): \(check.installed) is current")
                updates[p] = .current(check.installed)
                return .current
            }
            let prepared = try await installer.prepareUpdate(p, root: root, work: BattleNet.workArea(p, layout: LibraryModel.paths.layout))
            let bytes = prepared.plan.content.totalBytes
            log.info("battlenet", "\(p.code): update \(check.installed) → \(check.current)"
                     + (check.lacksClient ? " with the x64 client (\(prepared.clientPath))" : "") + ", \(bytes) bytes to write, "
                     + "\(prepared.plan.fetchBytes) to fetch")
            updates[p] = .available(from: check.installed, to: check.current, bytes: bytes)
            return .available(version: check.current, bytes: bytes)
        } catch {
            log.warn("battlenet", "\(p.code): update check failed: \(error)")
            let why = BattleNetStore.shared.reason(error)
            updates[p] = .unreachable(why)
            return .unreachable(why)
        }
    }

    /// The update's Downloads job, queued; `thenPlay` (a title ID) starts once it finished.
    /// Returns why it was not queued (it does not fit), or nil.
    @discardableResult
    func update(_ p: BattleNetProduct, downloads: Downloads, thenPlay: String? = nil) -> String? {
        guard case let .available(_, to, bytes)? = updates[p] else { return "No update was found for \(p.name)." }
        if let free = LibraryModel.shared.freeBytes, let why = BattleNet.refusal(needed: BattleNet.spaceNeeded(update: bytes), free: free) {
            log.info("battlenet", "\(p.code): update to \(to) refused: \(why)")
            errors[p] = why
            return why
        }
        errors[p] = nil
        if let thenPlay { playsAfterUpdate.queued(p, thenPlay: thenPlay) }
        log.info("battlenet", "\(p.code): update to \(to) queued" + (thenPlay.map { ", then Play \($0)" } ?? ""))
        downloads.enqueue(BattleNet.updateJob(p, bytes: bytes))
        return nil
    }

    /// After a Battle.net update job finished well: the Play that asked for it goes on (never
    /// after a language change).
    func finished(_ job: DownloadJob) {
        guard let id = playsAfterUpdate.finished(job) else { return }
        log.info("battlenet", "\(job.key.id): updated; Play \(id) goes on")
        LibraryModel.shared.playAfterUpdate(id)
    }

    /// A Battle.net job failed, paused or was cancelled: a Play waiting for it does not go on.
    func stopped(_ key: StoreGameKey) {
        playsAfterUpdate.stopped(key)
    }

    /// Before Play: the game's `Config.wtf` gets the install's locale and region where it names
    /// none, and Direct3D 12 (BattleNetClientKit's WoWConfig). A failure is logged and Play goes
    /// on: WoW then asks for its language and region itself.
    func prepareForPlay(_ p: BattleNetProduct) {
        guard let root = root(p) else { return }
        do {
            try WoWConfig.prepareForPlay(p, root: root)
        } catch {
            log.warn("battlenet", "\(p.code): Config.wtf not prepared: \(error)")
        }
    }
}
