// SPDX-License-Identifier: GPL-3.0-only
// Xodus Nexus e0668a12f1da931aed13537ef04295599011317b
// assets/xodus-subscription-login.patch (library.rs: the PCGAFD request and its
// continuation) and src/main/catalog.ts (licensedDetails: the bounded catalogue
// graph); translated to Swift by the Playport authors, 2026-10-30. Modified:
// injected transport, kept product descriptions, the library's own copies list.
import Foundation
import ContentKit

/// Whoever can mint the Microsoft Store's ticket (the signed-in XboxSession): the
/// value PCGAFD takes as its `Authorization`.
public protocol XboxStoreTickets: Sendable {
    func storeAuthorization() async throws -> Secret<String>
}
extension XboxSession: XboxStoreTickets {
    public func storeAuthorization() async throws -> Secret<String> { try await storeTicket().token }
}

/// One Xbox copy in the library, keyed by its Product ID (`xbox-<ProductId>`).
public struct XboxLibraryCopy: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let access: XboxAccess
    public let tileArt: URL?
    public let heroArt: URL?
}

public struct XboxLibrarySnapshot: Codable, Sendable, Equatable {
    /// The GDK games the account can license, by title.
    public var copies: [XboxLibraryCopy]
    /// Every licensed product looked up, listed or not: the next refresh's cache.
    public var products: [String: XboxProduct]
    public var checkedAt: Date
    /// Licensed products not listed: other packages, other launchers, add-ons, duplicate editions.
    public var leftOut: Int
    /// Every licensed product's access, games or not (add-ons are found among them);
    /// nil in a cache from before PLA-502.
    public var access: [String: XboxAccess]? = nil
}

/// The account's Xbox PC library: its own copies plus the PC Game Pass
/// catalogue it can play, from the Store's entitlements and the display catalogue.
public struct XboxStoreLibrary: Sendable {
    private let tickets: any XboxStoreTickets
    private let http: any XboxHTTP
    private let log: Logger
    private let market: String
    private let now: @Sendable () -> Date

    /// Catalogue pages of 20 products run to a few MiB; the default transport allows 8.
    public init(tickets: any XboxStoreTickets, http: any XboxHTTP = XboxURLSessionHTTP(limit: 8 << 20), log: Logger = .silent,
                market: String = "US", now: @escaping @Sendable () -> Date = { Date() }) {
        self.tickets = tickets; self.http = http; self.log = log; self.now = now
        self.market = market.utf8.count == 2 && market.utf8.allSatisfy({ (0x41...0x5A).contains($0) }) ? market : "US"
    }

    /// Reads the entitlements again; looks up only products the previous snapshot lacks.
    public func refresh(_ previous: XboxLibrarySnapshot? = nil) async throws -> XboxLibrarySnapshot {
        let checked = now()
        let entries = try await entitlements(tickets.storeAuthorization())
        var licensed: [String: XboxAccess] = [:]
        for id in entries.keys { if let access = XboxEntitlements.access(id, in: entries, now: checked) { licensed[id] = access } }
        // A GDK product cached before it carried its package is looked up again.
        var products = (previous?.products ?? [:]).filter { licensed[$0.key] != nil && ($0.value.delivery != .gdk || $0.value.package != nil) }
        let missing = licensed.keys.filter { products[$0] == nil }.sorted()
        if !missing.isEmpty {
            let records = try await lookUp(missing)
            for id in missing { if let product = XboxCatalog.product(id, records) { products[id] = product } }
        }
        let gdk = Set(licensed.keys.filter { products[$0]?.delivery == .gdk })
        // An edition (bundle) whose games are all listed as copies of their own is the same games twice.
        let listed = gdk.filter { id in
            let games = products[id]!.games
            return games == [id] || games.isEmpty || !games.allSatisfy(gdk.contains)
        }
        let copies = listed.map { id -> XboxLibraryCopy in
            let p = products[id]!
            return XboxLibraryCopy(id: id, title: p.title, access: licensed[id]!, tileArt: p.tileArt, heroArt: p.heroArt)
        }.sorted { ($0.title.localizedLowercase, $0.id) < ($1.title.localizedLowercase, $1.id) }
        let owned = copies.filter { $0.access == .owned }.count
        log.info("xbox", "library: \(copies.count) copies (\(owned) owned, \(copies.count - owned) PC Game Pass); \(licensed.count - copies.count) licensed products left out")
        return XboxLibrarySnapshot(copies: copies, products: products, checkedAt: checked, leftOut: licensed.count - copies.count,
                                   access: licensed)
    }

    /// Every page of the account's entitlements (the `x-ms-ct` continuation).
    private func entitlements(_ ticket: Secret<String>) async throws -> [String: XboxEntitlement] {
        var all: [String: XboxEntitlement] = [:], cursor: String?, seen = Set<String>()
        for _ in 0..<20 {
            var headers = ["Authorization": ticket, "X-MS-API-Version": Secret("1.1"), "Calling-App-Name": Secret("Xodus-Nexus"),
                           "MS-CV": Secret(Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
                                .replacingOccurrences(of: "=", with: "") + ".0"),
                           "Accept": Secret("application/json"), "User-Agent": Secret("Xodus-Nexus-membership/0.2.3")]
            if let cursor { headers["x-ms-ct"] = Secret(cursor) }
            let response = try await send(XboxEntitlements.url(market: market), headers: headers)
            if response.status == 401 || response.status == 403 { throw XboxSessionError.signInRequired }
            guard (200..<300).contains(response.status) else { throw ClientError.transport("Xbox entitlements returned HTTP \(response.status)") }
            for (id, entry) in try XboxEntitlements.parse(response.body.value) {
                if let old = all[id], old != entry { throw ClientError.protocolChanged("Xbox entitlements disagree between pages") }
                all[id] = entry
            }
            guard all.count <= XboxEntitlements.maximum else { throw ClientError.protocolChanged("Xbox entitlements are too many") }
            guard let next = response.headers["x-ms-ct"], !next.isEmpty else { return all }
            guard next.count <= 4096, seen.insert(next).inserted else { throw ClientError.protocolChanged("Xbox entitlements repeat a page") }
            cursor = next
        }
        throw ClientError.protocolChanged("Xbox entitlements have too many pages")
    }

    /// The products and, round by round, the bundles' products, in pages of 20, four at a time.
    private func lookUp(_ roots: [String]) async throws -> [String: XboxCatalog.Record] {
        var records: [String: XboxCatalog.Record] = [:], asked = Set<String>(), pending = roots
        for depth in 0...XboxCatalog.maxDepth where !pending.isEmpty && asked.count < 4096 {
            asked.formUnion(pending)
            let batches = stride(from: 0, to: pending.count, by: XboxCatalog.batch).map { Array(pending[$0..<min($0 + XboxCatalog.batch, pending.count)]) }
            let pages = try await withThrowingTaskGroup(of: [UInt8].self) { group in
                var pages: [[UInt8]] = [], next = 0
                func add() {
                    let batch = batches[next]; next += 1
                    group.addTask { try await self.page(batch) }
                }
                while next < min(4, batches.count) { add() }
                while let page = try await group.next() {
                    pages.append(page)
                    if next < batches.count { add() }
                }
                return pages
            }
            for page in pages { records.merge(try XboxCatalog.parse(page, asked: asked)) { a, _ in a } }
            pending = depth == XboxCatalog.maxDepth ? [] : Array(Set(pending.flatMap { records[$0].map(XboxCatalog.children) ?? [] }).subtracting(asked)).sorted()
        }
        return records
    }

    private func page(_ batch: [String]) async throws -> [UInt8] {
        let response = try await send(XboxCatalog.url(batch, market: market), headers: ["Accept": Secret("application/json")])
        guard (200..<300).contains(response.status) else { throw ClientError.transport("Xbox catalogue returned HTTP \(response.status)") }
        return response.body.value
    }

    private func send(_ url: URL, headers: [String: Secret<String>]) async throws -> XboxHTTPResponse {
        do { return try await http.send(XboxHTTPRequest(url: url, method: "GET", headers: headers, body: Secret([]))) }
        catch let error as ClientError { throw error }
        catch is CancellationError { throw ClientError.cancelled }
        catch { throw ClientError.transport("Xbox request failed; check your connection") }
    }
}
