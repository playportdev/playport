// SPDX-License-Identifier: GPL-3.0-or-later
// An Xbox copy's install (PLA-497), dev app only (decision 0179): the Downloads
// driver for `.xbox` jobs, the game page's sizes and refusal text, and Remove's saves.
// XboxClientKit's XboxInstaller streams the copy's MSIXVC into C:\Games; this writes
// the receipt the Library adopts.

import Combine
import ContentKit
import Foundation
import PlayportKit
import XboxClientKit

@MainActor
final class XboxInstalls: ObservableObject, DownloadDriver {
    static let shared = XboxInstalls()
    /// Microsoft's refusal of a copy (no entitlement, no licence), by Product ID, until the next Install.
    @Published private(set) var refused: [String: String] = [:]
    private(set) weak var downloads: Downloads?
    private var watch: AnyCancellable?
    nonisolated static let log = ContentKit.Logger { AppLog.append("xbox: " + $0) }
    /// The prefix's `%LOCALAPPDATA%`: where the Xbox runtime keeps a game's local saves.
    nonisolated static let localAppData = WineHostRuntime.documents
        .appendingPathComponent("prefix/drive_c/users/playport/AppData/Local", isDirectory: true)

    var installer: XboxInstaller {
        XboxInstaller(layout: LibraryModel.paths.layout, services: XboxAccount.shared.session, log: Self.log,
                      market: XboxMarket.current)
    }

    func attach(_ downloads: Downloads) {
        self.downloads = downloads
        downloads.register(self, for: .xbox)
        watch = XboxAccount.shared.$state.removeDuplicates().sink { [weak self] state in
            switch state {
            case .signedIn: self?.downloads?.conditionsChanged(letGoOf: .xbox, stopBlocked: false)
            case .signedOut: self?.downloads?.holdAll(of: .xbox, .stopped("Paused: signed out of Xbox."))
            case .unknown: break
            }
        }
    }

    /// The package the copy installs, as the display catalogue lists it.
    func package(_ id: String) -> XboxProductPackage? { XboxGames.shared.snapshot?.products[id]?.package }


    func canInstall(_ id: String) -> Bool { XboxAccount.shared.state == .signedIn && package(id) != nil }

    func install(_ copy: XboxLibraryCopy) {
        refused[copy.id] = nil
        downloads?.enqueue(DownloadJob(key: StoreGameKey(store: .xbox, id: copy.id), name: copy.title, kind: .install,
                                       bytes: package(copy.id)?.downloadSize))
    }

    var blocker: String? {
        if XboxAccount.shared.state != .signedIn { return "Waiting for Xbox" }
        let net = NetworkPath.shared
        if !net.connected { return "Waiting for a connection" }
        if !net.mayDownload { return "Waiting for Wi-Fi" }
        return nil
    }

    func run(_ job: DownloadJob, progress: @escaping @Sendable (InstallEngine.Progress) -> Void) async throws -> UInt64? {
        let id = job.key.id
        if job.kind == .update { return try await XboxUpdates.shared.run(job, progress: progress) }
        guard job.kind == .install else { throw ClientError.unsupported("Xbox copies are installed again from their page.") }
        if XboxGames.shared.snapshot == nil { await XboxGames.shared.refresh() }
        guard let package = package(id) else { throw XboxInstallRefusal.noPackage }
        var options = InstallEngine.Options()
        options.progressInterval = 0.5
        let r: XboxInstaller.Result
        do {
            r = try await installer.install(product: id, contentID: package.contentID, title: job.name, options: options, progress: progress)
        } catch let refusal as XboxInstallRefusal {
            refused[id] = refusal.description
            throw refusal
        }
        let rec = r.installed
        try LibraryModel.paths.layout.saveReceipt(StoreReceipt(
            store: .xbox, storeID: id, name: job.name, installDir: rec.installDir, version: rec.version, executable: rec.executable,
            files: rec.files.count, bytes: rec.bytes, installedAt: Date()))
        Self.log.info("xbox", "\(job.key): \(rec.version) in C:\\Games\\\(rec.installDir), \(rec.files.count) files, \(rec.encrypted.count) kept encrypted")
        return r.bytesWritten
    }

    func finished(_ job: DownloadJob) {}

    func discard(_ key: StoreGameKey) {
        let installer = self.installer
        Task.detached(priority: .utility) { installer.discardStages(key.id) }
    }

    func reason(_ error: Error) -> String { Self.message(error) }

    static func message(_ error: Error) -> String {
        if let refusal = error as? XboxInstallRefusal { return refusal.description }
        if let problem = error as? XboxLicenceProblem { return problem.description }
        if let session = error as? XboxSessionError { return session.description }
        if case let .unsupported(why)? = error as? ClientError { return why }
        return InstallCopy.reason(error, store: "Xbox")
    }

    /// Remove's part (the folder is the library's): the record, stages and, unless kept, the copy's saves.
    nonisolated static func forget(_ id: String, keepSaves: Bool) async {
        let installer = await shared.installer
        installer.forget(id, keepSaves: keepSaves, localAppData: localAppData)
        log.info("xbox", "\(StoreGameKey(store: .xbox, id: id)): removed, saves \(keepSaves ? "kept" : "deleted")")
    }
}
