// SPDX-License-Identifier: GPL-3.0-or-later
// The Xbox store's Library surfaces (decision 0166): the dev app only. Release is built
// without Dev/, and `pp verify --variant release` fails an executable naming a Swift
// `Xbox…` type or carrying `emptyText` (build/verify-ipa.py, XBOX_STRINGS), so an Xbox
// surface that slips out of Dev/ or `#if !PLAYPORT_RELEASE` is caught there.
//
// The signed-in account's copies (PLA-492): its own Xbox PC games and the PC Game
// Pass catalogue it can play, from XboxClientKit's XboxStoreLibrary. The list is
// kept as a cache (listed offline); opening the Library refreshes it. Each copy
// is `xbox-<ProductId>`, so the Steam and Xbox copies of one game stay two copies.

import Combine
import ContentKit
import Foundation
import PlayportKit
import SwiftUI
import UIKit
import XboxClientKit

enum XboxLibrary {
    /// Keep the dev Xbox chip visible even while the account is signed out.
    static func addChip(to stores: inout Set<Store>) {
        stores.insert(.xbox)
    }

    /// The Xbox chip's empty Library. Its last sentence is verify-ipa.py's release marker.
    static let emptyText = "Games you own on Xbox and PC Game Pass titles appear here. Xbox is in the dev app only."

    /// What the empty Xbox chip says now: loading, the refresh's failure, or the empty text.
    @MainActor static var emptyMessage: String {
        let games = XboxGames.shared
        if XboxAccount.shared.state != .signedIn { return "Sign in to Xbox in Settings › Accounts. " + emptyText }
        if games.loading { return "Loading your Xbox library…" }
        return games.error ?? emptyText
    }

    /// The account's copies, as the Library joins them (by `xbox-<ProductId>`, never by name).
    @MainActor static var owned: [LibraryList.Owned] {
        XboxGames.shared.copies.map { LibraryList.Owned(key: StoreGameKey(store: .xbox, id: $0.id), name: $0.title) }
    }

    /// Whether the copy has Microsoft's titled art (so no name is drawn over it).
    @MainActor static func hasArt(_ id: String) -> Bool { XboxGames.shared.game(id)?.tileArt != nil }

    /// The copy's art view, or nil when the key is no copy of the account's.
    @MainActor static func art(_ key: StoreGameKey, wide: Bool) -> XboxArtView? {
        guard key.store == .xbox, let copy = XboxGames.shared.game(key.id) else { return nil }
        return XboxArtView(copy: copy, wide: wide)
    }

    /// The Library opened: read the account's entitlements again.
    @MainActor static func opened() { Task { await XboxGames.shared.refresh() } }
}

@MainActor
final class XboxGames: ObservableObject {
    static let shared = XboxGames()
    @Published private(set) var snapshot: XboxLibrarySnapshot?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private let library: XboxStoreLibrary
    private var watch: AnyCancellable?
    nonisolated static let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Playport/xbox/library.json")
    nonisolated static let art = SteamPaths.art.appendingPathComponent("xbox", isDirectory: true)

    private init() {
        let account = XboxAccount.shared
        library = XboxStoreLibrary(tickets: account.session, log: ContentKit.Logger { AppLog.append("xbox: " + $0) },
                                   market: XboxMarket.current)
        if let data = try? Data(contentsOf: Self.cache) { snapshot = try? JSONDecoder().decode(XboxLibrarySnapshot.self, from: data) }
        // Signed out: the account's list goes (no cache of it is kept); signed in: it is read.
        watch = account.$state.removeDuplicates().sink { [weak self] state in
            switch state {
            case .signedOut: self?.forget()
            case .signedIn: Task { await self?.refresh() }
            case .unknown: break
            }
        }
    }

    /// The copies of the signed-in account; none while signed out.
    var copies: [XboxLibraryCopy] { XboxAccount.shared.state == .signedIn ? snapshot?.copies ?? [] : [] }

    func game(_ id: String) -> XboxLibraryCopy? { copies.first { $0.id == id } }

    func refresh() async {
        guard XboxAccount.shared.state == .signedIn, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try await library.refresh(snapshot)
            guard XboxAccount.shared.state == .signedIn else { return }
            snapshot = next; error = nil
            try? FileManager.default.createDirectory(at: Self.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(next).write(to: Self.cache, options: .atomic)
        } catch let failure as XboxSessionError {
            error = failure.description
        } catch let failure as ClientError {
            error = "The Xbox library can't be loaded: \(failure.description)"
        } catch {
            self.error = "The Xbox library can't be loaded. Try again."
        }
        // Each installed copy's licence (its lapse, Dev/XboxLapse.swift), then the removals due.
        await XboxLapses.shared.refreshed()
    }

    private func forget() {
        snapshot = nil; error = nil
        try? FileManager.default.removeItem(at: Self.cache)
    }
}

/// Microsoft's art for a copy, sized by its image service (`?w=`), kept under Caches.
@MainActor
final class XboxArt: ObservableObject {
    static let shared = XboxArt()
    @Published private var images: [String: UIImage] = [:]
    private var loading = Set<String>()

    /// 800 wide for a tile; 1920 behind a page and the launch screen.
    nonisolated static func width(wide: Bool) -> Int { wide ? 1920 : 800 }

    nonisolated static func file(_ id: String, wide: Bool) -> URL {
        XboxGames.art.appendingPathComponent("\(StoreGameKey(store: .xbox, id: id).fileStem)_\(width(wide: wide)).jpg")
    }

    func image(_ copy: XboxLibraryCopy, wide: Bool) -> UIImage? {
        let key = "\(copy.id)/\(wide)"
        if let i = images[key] { return i }
        guard let art = wide ? copy.heroArt ?? copy.tileArt : copy.tileArt,
              var parts = URLComponents(url: art, resolvingAgainstBaseURL: false), loading.insert(key).inserted else { return nil }
        parts.queryItems = [URLQueryItem(name: "w", value: String(Self.width(wide: wide)))]
        guard let url = parts.url else { return nil }
        let file = Self.file(copy.id, wide: wide)
        Task.detached(priority: .utility) {
            var data = try? Data(contentsOf: file)
            if data == nil, let (d, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200 {
                try? FileManager.default.createDirectory(at: XboxGames.art, withIntermediateDirectories: true)
                try? d.write(to: file, options: .atomic)
                data = d
            }
            let image = data.flatMap(UIImage.init(data:))
            await MainActor.run {
                if let image { XboxArt.shared.images[key] = image }
            }
        }
        return nil
    }
}

struct XboxArtView: View {
    let copy: XboxLibraryCopy
    var wide = false
    @ObservedObject private var art = XboxArt.shared

    var body: some View {
        ZStack {
            Rectangle().fill(PP.tile(for: copy.title))
            if let i = art.image(copy, wide: wide) { Image(uiImage: i).resizable().aspectRatio(contentMode: .fill) }
        }
        .clipped()
    }
}
