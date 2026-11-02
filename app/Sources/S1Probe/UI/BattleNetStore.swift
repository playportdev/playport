// SPDX-License-Identifier: GPL-3.0-or-later
// The Battle.net store in the app (PLA-519, decisions 0174 and 0177), as EpicAccount.swift is
// Epic's, without a sign-in: which World of Warcraft products are offered (BattleNetClientKit
// asks Blizzard's public version endpoint and CDN; a product is listed while its build carries
// its x64 client), cached so the store lists offline; each product's store region (the phone's
// region until the page's picker changes it) and install language (the phone's language as a
// WoW locale, enUS as fallback); its download size and the space an install needs, an Install
// refused up front when that space is not free; and the Battle.net driver of the download queue,
// whose install stages under the staging root and becomes C:\Games\<product> with a store
// receipt (PlayportKit BattleNet), so Play shows only once it is complete. The play itself, and
// the ban-risk notice before it, are PLA-514's.

import BattleNetClientKit
import Combine
import Foundation
import PlayportKit
import SteamClientKit
import SwiftUI

@MainActor
final class BattleNetStore: ObservableObject, DownloadDriver {
    static let shared = BattleNetStore()

    /// What Blizzard said of each product, per store region asked (newest first per product).
    @Published private(set) var listings: [BattleNetListing] = []
    @Published private(set) var listedAt: Date?
    @Published private(set) var loading = false
    /// Why the last listing failed (Blizzard unreachable or refusing), worded for the player.
    @Published private(set) var error: String?
    /// The region picked on a product's page; the phone's region until then.
    @Published private(set) var picked: [BattleNetProduct: StoreRegion] = [:]
    /// The size requests running, by product and region: a region picked while another region's
    /// request runs gets its own.
    @Published private var sizeRequests: Set<String> = []
    /// Products whose sizes are being asked for in the region their page shows.
    var sizing: Set<BattleNetProduct> {
        Set(BattleNetProduct.allCases.filter { sizeRequests.contains("\($0.code)/\(region($0).rawValue)") })
    }
    /// Why a product's sizes could not be asked for.
    @Published private(set) var sizeErrors: [BattleNetProduct: String] = [:]
    /// An Install refused for space: what the page says.
    @Published private(set) var refusals: [BattleNetProduct: String] = [:]

    let client = BattleNetClient(transport: URLSessionTransport())
    private let log = SteamUILog.logger
    private weak var downloads: Downloads?
    /// The offers asked for in this process, by product and region: sizes need one.
    private var offers: [String: BattleNetOffer] = [:]
    nonisolated static let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Playport/battlenet/listings.json")

    private init() {
        if let data = try? Data(contentsOf: Self.cache), let c = try? JSONDecoder.gogCache.decode(Cache.self, from: data),
           c.machine == BattleNetProduct.x64ClientTag {
            listings = c.listings
            listedAt = c.at
        }
    }

    /// `machine`: the client the listings' offers and sizes are for. A cache from before decision
    /// 0177 has none (its sizes are the ARM64 client's) and is asked again.
    private struct Cache: Codable {
        var at: Date
        var listings: [BattleNetListing]
        var machine: String?
    }

    private func saveCache() {
        guard let at = listedAt else { return }
        try? FileManager.default.createDirectory(at: Self.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.gogCache.encode(Cache(at: at, listings: listings, machine: BattleNetProduct.x64ClientTag))
            .write(to: Self.cache, options: .atomic)
    }

    /// Registers the driver. Blizzard is asked only when the store is shown (the Library, a
    /// product's page), never at start.
    func attach(_ downloads: Downloads) {
        self.downloads = downloads
        downloads.register(self, for: .battlenet)
    }

    // MARK: products

    /// The phone's region as a store region.
    var phoneRegion: StoreRegion { BattleNet.region(phoneRegion: Locale.current.region?.identifier) }

    func region(_ p: BattleNetProduct) -> StoreRegion { picked[p] ?? phoneRegion }

    /// What Blizzard said of the product in its region, else in any region.
    func listing(_ p: BattleNetProduct) -> BattleNetListing? {
        listings.first { $0.product == p && $0.region == region(p) } ?? listings.first { $0.product == p }
    }

    /// The install language: the phone's, as a WoW locale the product ships, else enUS.
    func locale(_ p: BattleNetProduct) -> String {
        let l = listing(p)
        return BattleNet.locale(preferredLanguages: Locale.preferredLanguages, supported: l?.supportedLocales ?? [],
                                replacements: l?.replacementLocales ?? [:])
    }

    /// The store's tiles: the offered products.
    var shown: [LibraryList.Owned] { BattleNet.shown(BattleNetProduct.allCases.compactMap(listing)) }

    /// An offered product, for its page.
    func offered(_ key: StoreGameKey) -> BattleNetProduct? {
        BattleNet.product(key).flatMap { p in listing(p)?.offered == true ? p : nil }
    }

    /// Asks Blizzard which products are offered in their regions; at most every six hours unless `force`.
    func refresh(force: Bool = false) async {
        guard !loading else { return }
        if !force, let at = listedAt, Date().timeIntervalSince(at) < 6 * 3600, !listings.isEmpty { return }
        loading = true
        defer { loading = false }
        var failure: Error?
        for p in BattleNetProduct.allCases {
            do {
                try await ask(p, region(p))
            } catch {
                failure = failure ?? error
                log.warn("battlenet", "\(p.code) \(region(p).rawValue): \(error)")
            }
        }
        if let failure {
            error = BattleNet.reason(failure).map { InstallCopy.detailed($0, failure) } ?? InstallCopy.detailed("The Battle.net store could not be read.", failure)
        } else {
            error = nil
        }
        listedAt = Date()
        saveCache()
        log.info("battlenet", "offered: " + shown.map(\.key.id).joined(separator: ", "))
    }

    /// One product's offer in one region, kept with its sizes when the build is the same.
    private func ask(_ p: BattleNetProduct, _ r: StoreRegion) async throws {
        let offer = try await client.offer(p, r)
        offers["\(p.code)/\(r.rawValue)"] = offer
        var l = BattleNetListing(offer)
        if let old = listings.first(where: { $0.product == p && $0.region == r }), old.version == l.version { l.sizes = old.sizes }
        listings.removeAll { $0.product == p && $0.region == r }
        listings.insert(l, at: 0)
    }

    /// The page's sizes for the product in its region and locale, asked once per build.
    func loadSizes(_ p: BattleNetProduct) async {
        let r = region(p), request = "\(p.code)/\(r.rawValue)"
        guard !sizeRequests.contains(request) else { return }
        sizeRequests.insert(request)
        defer { sizeRequests.remove(request) }
        do {
            if listings.first(where: { $0.product == p && $0.region == r }) == nil || offers["\(p.code)/\(r.rawValue)"] == nil {
                try await ask(p, r)
            }
            let locale = self.locale(p)
            guard let i = listings.firstIndex(where: { $0.product == p && $0.region == r }), listings[i].offered else { return }
            if listings[i].sizes?.locale == locale { return }
            guard let offer = offers["\(p.code)/\(r.rawValue)"] else { return }
            let sizes = try await client.sizes(offer, locale: locale)
            if let i = listings.firstIndex(where: { $0.product == p && $0.region == r }) {
                listings[i].sizes = BattleNetListing.Sizes(sizes, locale: locale)
            }
            if region(p) == r { sizeErrors[p] = nil }
            listedAt = listedAt ?? Date()
            saveCache()
            log.info("battlenet", "\(p.code) \(r.rawValue) \(locale): download \(sizes.download), install \(sizes.install), \(sizes.objects) objects")
        } catch {
            // A page left (its task cancelled) or a region changed since is no error to show.
            if Task.isCancelled {
                log.info("battlenet", "\(p.code) \(r.rawValue): sizes not asked for: cancelled")
                return
            }
            log.warn("battlenet", "\(p.code) \(r.rawValue): sizes failed: \(error)")
            guard region(p) == r else { return }
            sizeErrors[p] = BattleNet.reason(error).map { InstallCopy.detailed($0, error) } ?? InstallCopy.detailed("The size could not be read.", error)
        }
    }

    /// The page's region picker's choice.
    func pick(_ p: BattleNetProduct, region r: StoreRegion) {
        guard r != region(p) else { return }
        picked[p] = r
        refusals[p] = nil
        log.info("battlenet", "\(p.code): store region \(r.rawValue)")
        Task { await loadSizes(p) }
    }

    /// The region picker (PadModal), as the page's Region button opens it.
    func pickRegion(_ p: BattleNetProduct) {
        PadModal.shared.picker(title: "Store region", context: p.name,
                               note: "Your Battle.net account's region. The game signs in to it.",
                               options: StoreRegion.allCases.map { PadOption(id: $0.rawValue, label: Self.label($0)) },
                               selected: region(p).rawValue) { [weak self] id in
            if let r = StoreRegion(rawValue: id) { self?.pick(p, region: r) }
        }
    }

    static func label(_ r: StoreRegion) -> String {
        switch r {
        case .us: "Americas (us)"
        case .eu: "Europe (eu)"
        case .kr: "Korea (kr)"
        case .tw: "Taiwan (tw)"
        }
    }

    // MARK: space

    /// The space an install needs: from the sizes, or a dev build's override (`set:battlenetInstallBytes=N`,
    /// a size larger than free space shows the refusal).
    func needed(_ p: BattleNetProduct) -> UInt64? {
        #if !PLAYPORT_RELEASE
        let override = UserDefaults.standard.integer(forKey: Self.installBytesKey)
        if override > 0 { return UInt64(override) }
        #endif
        return listing(p)?.sizes.map(BattleNet.spaceNeeded)
    }

    #if !PLAYPORT_RELEASE
    static let installBytesKey = "battlenetInstallBytes"
    #endif

    /// Why an Install would be refused now, or nil.
    func spaceRefusal(_ p: BattleNetProduct) -> String? {
        guard let needed = needed(p), let free = LibraryModel.shared.freeBytes else { return nil }
        return BattleNet.refusal(needed: needed, free: free)
    }

    // MARK: queue

    /// A paused or stopped install has staged work to resume.
    func hasStage(_ p: BattleNetProduct) -> Bool {
        FileManager.default.fileExists(atPath: BattleNet.workArea(p, layout: LibraryModel.paths.layout).path)
    }

    /// The page's Install: refused up front, saying how much is needed, when it does not fit.
    /// Returns the refusal, or nil once queued.
    @discardableResult
    func install(_ p: BattleNetProduct) -> String? {
        if let why = spaceRefusal(p) {
            refusals[p] = why
            log.info("battlenet", "\(p.code): install refused: \(why)")
            return why
        }
        refusals[p] = nil
        let r = region(p), locale = self.locale(p)
        log.info("battlenet", "\(p.code): install queued (\(r.rawValue), \(locale))")
        downloads?.enqueue(DownloadJob(key: BattleNet.key(p), name: p.name, kind: .install,
                                       branch: BattleNet.jobBranch(region: r, locale: locale), bytes: listing(p)?.sizes?.download))
        return nil
    }

    var blocker: String? {
        let net = NetworkPath.shared
        if !net.connected { return "Waiting for a connection" }
        if !net.mayDownload { return "Waiting for Wi-Fi" }
        return nil
    }

    func run(_ job: DownloadJob, progress: @escaping @Sendable (InstallEngine.Progress) -> Void) async throws -> UInt64? {
        guard let p = BattleNet.product(job.key) else { throw ClientError.notFound("\(job.key) is not a Battle.net product") }
        // A language change (PLA-520) or an update to the region's current build (PLA-521). One that
        // stops (fails, pauses, is cancelled) drops the Play waiting for it.
        if job.kind == .update {
            do {
                return try await BattleNetInstalled.shared.run(p, job, client: client, progress: progress)
            } catch {
                BattleNetInstalled.shared.stopped(job.key)
                throw error
            }
        }
        guard job.kind == .install else { throw ClientError.unsupported("Battle.net \(job.kind.rawValue) is not available yet") }
        let choice = BattleNet.jobChoice(job.branch) ?? (region(p), locale(p))
        let layout = LibraryModel.paths.layout
        let work = BattleNet.workArea(p, layout: layout)
        var installer = BattleNetInstaller(client: client, log: log)
        installer.engine.progressInterval = 0.5
        // The plan holds the x64 client (prepare refuses one without it), before any download.
        let prepared = try await installer.prepare(p, choice.region, options: BattleNetInstallOptions(locale: choice.locale), work: work)
        try InstallFS.makeDirectory(layout.gamesRoot)
        let folder = BattleNet.folder(p, in: layout.gamesRoot)
        let root = layout.gamesRoot.appendingPathComponent(folder, isDirectory: true)
        log.info("battlenet", "\(p.code) \(choice.region.rawValue) \(choice.locale) \(prepared.plan.build.version.versionsName): "
                 + "\(prepared.plan.content.totalBytes) bytes into C:\\Games\\\(folder)")
        let r = try await installer.install(prepared, into: root, work: work, progress: progress)
        let measured = await BattleNet.measure(root)
        do {
            try layout.saveReceipt(BattleNet.receipt(p, folder: folder, version: prepared.plan.build.version.versionsName,
                                                     client: prepared.clientPath,
                                                     files: measured.files, bytes: measured.bytes, at: Date()))
        } catch {
            // No receipt, no title: the folder would be left in C:\Games with nothing to play or remove it.
            log.warn("battlenet", "\(p.code): the receipt was not saved (\(error)); C:\\Games\\\(folder) removed")
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        log.info("battlenet", String(format: "\(p.code): installed in C:\\Games\\\(folder), \(r.engine.downloadedBytes) bytes fetched in %.0f s",
                                     r.seconds))
        return prepared.plan.content.totalBytes
    }

    func finished(_ job: DownloadJob) {
        if job.kind == .update { BattleNetInstalled.shared.finished(job) }
    }

    /// A paused update, queued or running: the Play waiting for it does not go on when it is resumed.
    func held(_ key: StoreGameKey) {
        BattleNetInstalled.shared.stopped(key)
    }

    func discard(_ key: StoreGameKey) {
        guard let p = BattleNet.product(key) else { return }
        BattleNetInstalled.shared.stopped(key)
        let work = BattleNet.workArea(p, layout: LibraryModel.paths.layout)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: work) }
    }

    /// An uninstall: anything a later install left staged goes too.
    nonisolated static func forget(_ key: StoreGameKey) {
        guard let p = BattleNet.product(key) else { return }
        try? FileManager.default.removeItem(at: BattleNet.workArea(p, layout: LibraryModel.paths.layout))
    }

    func reason(_ error: Error) -> String {
        BattleNet.reason(error).map { InstallCopy.detailed($0, error) } ?? InstallCopy.reason(error, store: Store.battlenet.label)
    }
}

// MARK: art

/// A product's art from Blizzard's image host (BattleNetArt), kept under Caches beside the GOG
/// and Epic art (BattleNetArtCache, re-fetchable). No session: anyone sees it, signed in or not.
@MainActor
final class BattleNetArtImages: ObservableObject {
    static let shared = BattleNetArtImages()
    @Published private var images: [String: UIImage] = [:]
    private var loading = Set<String>()

    nonisolated static let cache = BattleNetArtCache(directory: SteamPaths.art.appendingPathComponent("battlenet", isDirectory: true))

    /// The page backdrop already on disk, for the launch screen (TitleLaunch).
    nonisolated static func cachedHero(_ p: BattleNetProduct) -> UIImage? {
        cache.cached(p, .hero).flatMap(UIImage.init(data:))
    }

    func image(_ p: BattleNetProduct, _ size: BattleNetArt.Size) -> UIImage? {
        let key = "\(p.code)/\(size.rawValue)"
        if let i = images[key] { return i }
        guard loading.insert(key).inserted else { return nil }
        let client = BattleNetStore.shared.client
        Task.detached(priority: .utility) {
            let image = await Self.cache.load(p, size) { try await client.art(p, size) }.flatMap(UIImage.init(data:))
            await MainActor.run {
                if let image { BattleNetArtImages.shared.images[key] = image }
                // Not kept: the next time the tile or page is drawn asks again.
                else { BattleNetArtImages.shared.loading.remove(key) }
            }
        }
        return nil
    }
}

struct BattleNetArtView: View {
    let product: BattleNetProduct
    var wide = false
    @ObservedObject private var art = BattleNetArtImages.shared

    var body: some View {
        ZStack {
            Rectangle().fill(PP.tile(for: product.name))
            if let i = art.image(product, wide ? .hero : .tile) { Image(uiImage: i).resizable().aspectRatio(contentMode: .fill) }
        }
        .clipped()
    }
}
