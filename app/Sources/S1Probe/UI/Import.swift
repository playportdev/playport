// SPDX-License-Identifier: GPL-3.0-or-later
// Importing a game from Files (docs/plans/2026-10-06-pc-import-gog-epic.md, Phase 1):
// the Library's Add a game tile opens the system picker (touch: iOS draws it, as
// the pairing-file import's), and what is picked, a folder or a .zip, becomes a
// Downloads job of kind import (PlayportKit GameImporter does the copy).
//
// iOS lends the picked item's access to this process only, so the picked URL
// is kept in memory. After a restart (decision 0029) an unfinished import has
// none: it stops with "Pick the folder again", and picking the same item
// (by its name; DownloadJob.source) resumes it from its stage.

import Combine
import Foundation
import PlayportKit
import SteamClientKit
import UniformTypeIdentifiers

@MainActor
final class GameImports: ObservableObject, DownloadDriver {
    static let shared = GameImports()
    /// Add a game: the shell opens the Files picker (AppShell).
    static let requests = PassthroughSubject<Void, Never>()

    /// What the picker offers: folders and zips, and executables only so that a picked
    /// installer gets an answer (installers are not run; plan 1.5, owner 2026-10-06).
    static let contentTypes: [UTType] = [.folder, .zip] + [UTType(filenameExtension: "exe")].compactMap { $0 }

    static let pickAgain = "Pick the folder again in Add a game to continue."

    private struct Picked {
        var url: URL
        var plan: ImportPlan
    }

    private var picked: [StoreGameKey: Picked] = [:]
    /// The import being planned (a big folder takes a moment to list), for the tile's spinner.
    @Published private(set) var planning = false
    private weak var downloads: Downloads?

    var importer: GameImporter { GameImporter(layout: LibraryModel.paths.layout) }

    func attach(_ downloads: Downloads) {
        self.downloads = downloads
        downloads.register(self, for: .local)
    }

    // MARK: DownloadDriver

    var blocker: String? { nil }

    func run(_ job: DownloadJob, progress: @escaping @Sendable (InstallEngine.Progress) -> Void) async throws -> UInt64? {
        guard let p = picked[job.key] else { throw ImportFailure.needsSource }
        let importer = self.importer, folder = job.name, started = Date()
        Self.event("started", job)
        let worker = Task.detached(priority: .userInitiated) { () throws -> StoreReceipt in
            let access = p.url.startAccessingSecurityScopedResource()
            defer { if access { p.url.stopAccessingSecurityScopedResource() } }
            return try await importer.run(p.plan, folder: folder) { g in
                progress(InstallEngine.Progress(bytesDone: g.bytesDone, bytesTotal: g.bytesTotal, downloadedBytes: g.bytesDone,
                                                chunksDownloaded: g.filesDone, chunksToDownload: g.filesTotal,
                                                filesVerified: g.filesDone, filesTotal: g.filesTotal,
                                                seconds: Date().timeIntervalSince(started)))
            }
        }
        let receipt = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        SteamUILog.logger.info("import", "\(job.key): \(receipt.files) files, \(receipt.bytes) bytes into C:\\Games\\\(folder)"
                               + (receipt.store == .local ? "" : " (a \(receipt.store.label) copy, \(receipt.key))")
                               + (p.plan.skippedSymlinks > 0 ? ", \(p.plan.skippedSymlinks) symlinks skipped" : ""))
        Self.event("done", job, ["files": receipt.files, "bytes": receipt.bytes, "store": receipt.store.rawValue,
                                 "id": StoreGameKey(store: receipt.store, id: receipt.storeID).titleID])
        return receipt.bytes
    }

    func finished(_ job: DownloadJob) { picked[job.key] = nil }

    func discard(_ key: StoreGameKey) {
        picked[key] = nil
        let games = importer.layout.gamesRoot
        let stages = ((try? FileManager.default.contentsOfDirectory(atPath: games.path)) ?? [])
            .filter { $0.hasPrefix(".stage-import-") && StoreGameKey(store: .local, id: String($0.dropFirst(".stage-import-".count))) == key }
        Task.detached(priority: .utility) {
            for s in stages { try? FileManager.default.removeItem(at: games.appendingPathComponent(s)) }
        }
    }

    func reason(_ error: Error) -> String {
        Self.event("stopped", nil, ["error": "\(error)"])
        switch error {
        case ImportFailure.needsSource: return Self.pickAgain
        case let e as ImportError: return InstallCopy.detailed(e.description, error)
        case is CancellationError: return "The import stopped."
        default:
            if case .insufficientSpace? = error as? ClientError { return InstallCopy.reason(error) }
            return InstallCopy.detailed("The import stopped: a file could not be copied. Pick the folder again to retry.", error)
        }
    }

    // MARK: picking

    /// What the picker returned: plan it off the main thread, then queue it, or
    /// resume the held import of the same item. Returns a message for the player
    /// when it cannot be imported.
    func picked(_ url: URL) async -> String? {
        guard let downloads else { return "Downloads are not ready yet." }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
        let ext = url.pathExtension.lowercased()
        let source: ImportSource
        if isDir {
            source = .folder(url)
        } else if ext == "zip" {
            source = .zip(url)
        } else if ext == "exe" {
            return "Playport doesn't run installers. Pick the installed game's folder (or a .zip of it), "
                + "or sign in to GOG in Settings › Accounts to install the game from there."
        } else {
            return "Pick a game's folder or a .zip of it."
        }
        planning = true
        defer { planning = false }
        let planned = await Task.detached(priority: .userInitiated) { () -> Result<ImportPlan, Error> in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return Result { try GameImporter.plan(source) }
        }.value
        let plan: ImportPlan
        switch planned {
        case let .success(p): plan = p
        case let .failure(e):
            SteamUILog.logger.warn("import", "\(url.lastPathComponent): refused: \(e)")
            return (e as? ImportError)?.description ?? "Playport can't read that: \(e)"
        }
        let name = url.lastPathComponent
        // The same item again: its held import resumes from the stage.
        if let held = downloads.order.first(where: { $0.kind == .import && $0.record.source == name && !$0.isRunning }) {
            picked[held.key] = Picked(url: url, plan: plan)
            SteamUILog.logger.info("import", "\(held.key): picked again, resuming")
            downloads.resume(held.key)
            return nil
        }
        let games = importer.layout.gamesRoot
        let existing = ((try? FileManager.default.contentsOfDirectory(atPath: games.path)) ?? []).filter { !$0.hasPrefix(".") }
        let queued = downloads.order.filter { $0.kind == .import }.map(\.name)
        let folder = GameImporter.uniqueFolder(plan.name, existing: existing, taken: queued)
        let key = StoreGameKey(store: .local, id: folder)
        picked[key] = Picked(url: url, plan: plan)
        var job = DownloadJob(key: key, name: folder, kind: .import, bytes: plan.totalBytes)
        job.source = name
        SteamUILog.logger.info("import", "\(key): queued from \(name): \(plan.files.count) files, \(plan.totalBytes) bytes"
                               + (plan.skippedSymlinks > 0 ? ", \(plan.skippedSymlinks) symlinks to skip" : ""))
        Self.event("queued", job, ["files": plan.files.count])
        downloads.enqueue(job)
        return nil
    }

    private static func event(_ state: String, _ job: DownloadJob?, _ extra: [String: Any] = [:]) {
        #if !PLAYPORT_RELEASE
        var o = extra
        o["state"] = state
        if let job {
            o["key"] = job.key.titleID
            o["bytes"] = o["bytes"] ?? job.bytes
        }
        RunEvents.emit("import", o)
        #endif
    }
}

enum ImportFailure: Error {
    /// This process holds no access to the picked item (a restart came between).
    case needsSource
}
