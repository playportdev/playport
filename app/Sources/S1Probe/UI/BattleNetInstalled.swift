// SPDX-License-Identifier: GPL-3.0-or-later
// An installed Battle.net product's store region and language, changed on its page (PLA-520):
// the region in place, without a download (every region's data is in the install, so only
// `.build.info` changes, BattleNetClientKit's changeRegion); the language as a Downloads job (an
// update of the installed build, PlayportKit BattleNet.languageJob) that fetches only the new
// locale's data, after which Play is available again. What the install is in now is its
// `.build.info`'s, read when the page shows.

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
    /// Why a product's last region change failed, worded for the player.
    @Published private(set) var errors: [BattleNetProduct: String] = [:]

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

    /// The region picker (PadModal), as the installed page's Region button opens it.
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
        guard locale.count == 4 else { return locale }
        let id = locale.prefix(2) + "_" + locale.suffix(2)
        return Locale.current.localizedString(forIdentifier: String(id)).map { "\($0) · \(locale)" } ?? locale
    }

    /// The language picker (PadModal), as the installed page's Language button opens it.
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

    /// Downloads' run of a language change: only the new locale's data, then the receipt counts it.
    func run(_ p: BattleNetProduct, _ job: DownloadJob, client: BattleNetClient,
             progress: @escaping @Sendable (InstallEngine.Progress) -> Void) async throws -> UInt64? {
        guard let choice = BattleNet.jobChoice(job.branch) else { throw ClientError.unsupported("Battle.net update without a language") }
        let layout = LibraryModel.paths.layout
        guard let before = receipt(p), let root = root(p) else { throw ClientError.notFound("\(p.name) is not installed") }
        let work = BattleNet.workArea(p, layout: layout)
        var installer = BattleNetInstaller(client: client, log: log)
        installer.engine.progressInterval = 0.5
        let prepared = try await installer.prepareLocaleChange(p, root: root, to: choice.locale, work: work)
        let r = try await installer.changeLocale(prepared, root: root, work: work, progress: progress)
        try layout.saveReceipt(BattleNet.receipt(before, adding: prepared.plan.content.files.count, bytes: prepared.plan.content.totalBytes))
        if let c = BattleNet.installedChoice(p, folder: root) { current[p] = Choice(region: c.region, locale: c.locale) }
        log.info("battlenet", "\(p.code): language \(choice.locale) in C:\\Games\\\(before.installDir), "
                 + "\(prepared.plan.objects) objects, \(r.engine.downloadedBytes) bytes fetched in \(Int(r.seconds)) s")
        return r.engine.downloadedBytes
    }
}
