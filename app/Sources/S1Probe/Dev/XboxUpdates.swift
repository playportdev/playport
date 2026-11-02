// SPDX-License-Identifier: GPL-3.0-or-later
// An installed Xbox copy's updates (PLA-501), dev app only (decision 0181): the game
// page asks once per process whether the Store has a newer package (GetBasePackage
// through XboxClientKit's XboxInstaller.updateCheck) and offers Update as for GOG and
// Epic; the Downloads queue runs it as an `.update` job of the Xbox driver, which
// fetches only the pages or segments that changed, then rewrites the receipt.

import Combine
import ContentKit
import Foundation
import PlayportKit
import XboxClientKit

@MainActor
final class XboxUpdates: ObservableObject {
    static let shared = XboxUpdates()
    /// The Store's newer version per installed copy, once asked (the page shows Update).
    @Published private(set) var newest: [String: String] = [:]
    /// The last answer per copy (the page's "Up to date" line) and the copies being asked now.
    @Published private(set) var answers: [String: XboxPackageUpdateCheck] = [:]
    @Published private(set) var checking = Set<String>()
    private var asked = Set<String>()

    /// Asks the Store once per process (or again with `force`: the page's Check for update)
    /// for copy `id`'s latest package. Nil when signed out or the answer couldn't be had.
    @discardableResult
    func check(_ id: String, force: Bool = false) async -> XboxPackageUpdateCheck? {
        guard XboxAccount.shared.state == .signedIn, force || !asked.contains(id), !checking.contains(id) else { return nil }
        asked.insert(id)
        checking.insert(id)
        defer { checking.remove(id) }
        let installer = XboxInstalls.shared.installer
        do {
            let check = try await installer.updateCheck(id)
            if case .available(let latest) = check { newest[id] = latest } else { newest[id] = nil }
            answers[id] = check
            return check
        } catch {
            asked.remove(id)
            answers[id] = nil
            XboxInstalls.log.warn("xbox", "\(StoreGameKey(store: .xbox, id: id)): update check failed: \(XboxInstalls.message(error))")
            return nil
        }
    }

    func update(_ id: String, name: String) {
        XboxInstalls.shared.downloads?.enqueue(DownloadJob(key: StoreGameKey(store: .xbox, id: id), name: name, kind: .update))
    }

    /// The Xbox driver's `.update` job: the installed copy brought to the Store's latest package.
    func run(_ job: DownloadJob, progress: @escaping @Sendable (InstallEngine.Progress) -> Void) async throws -> UInt64? {
        let id = job.key.id
        var options = InstallEngine.Options()
        options.progressInterval = 0.5
        let r = try await XboxInstalls.shared.installer.update(product: id, title: job.name, options: options, progress: progress)
        let rec = r.installed
        try LibraryModel.paths.layout.saveReceipt(StoreReceipt(
            store: .xbox, storeID: id, name: job.name, installDir: rec.installDir, version: rec.version, executable: rec.executable,
            files: rec.files.count, bytes: rec.bytes, installedAt: Date()))
        newest[id] = nil
        XboxInstalls.log.info("xbox", "\(job.key): \(rec.version) in C:\\Games\\\(rec.installDir): \(r.filesChanged) files written, "
                              + "\(r.filesRemoved) removed, \(r.downloadedBytes) bytes fetched, \(r.reusedBytes) reused"
                              + (r.reinstalled ? " (installed again whole)" : ""))
        return r.downloadedBytes
    }
}
