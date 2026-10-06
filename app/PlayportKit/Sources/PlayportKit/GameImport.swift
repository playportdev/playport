// SPDX-License-Identifier: GPL-3.0-or-later
// A game picked in Files, copied into C:\Games (docs/plans/2026-10-06-pc-import-gog-epic.md,
// Phase 1): a folder or a .zip, as a Downloads job of kind import.
//
// - The plan: every file the source holds, checked as the guest will name it
//   (WindowsName: reserved names, characters, a trailing dot, names that differ
//   only by case), symlinks skipped and counted, iCloud placeholders refused.
//   A zip whose entries all sit in one top-level folder imports that folder.
// - The copy goes into `Games/.stage-import-<folder>` (adoption skips dot
//   folders), after a free-space check (what is left to copy, plus 5%, plus a
//   reserve). Each file is written beside its name and renamed into place when
//   whole, so a file at its final name is complete: a stopped import resumes by
//   skipping those. On Apple platforms a file is cloned when it can be (On My
//   iPhone: no space), else copied.
// - The commit is one rename into `Games/<folder>`, then the receipt
//   `installs/local-<folder>.json`: the source's name, never its path. An import is
//   always a Local game, whatever store the files once came from (owner, 2026-10-06:
//   local, Steam, GOG and Epic are separate sources). A launch record a store left in
//   the folder (StoreMarkers) only says which executable and arguments to start.

import Foundation
import SteamClientKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum ImportSource: Sendable, Equatable {
    case folder(URL)
    case zip(URL)

    public var url: URL {
        switch self {
        case let .folder(u), let .zip(u): u
        }
    }

    /// `Celeste` for a folder, `Celeste` for `Celeste.zip`.
    public var baseName: String {
        switch self {
        case let .folder(u): u.lastPathComponent
        case let .zip(u): u.deletingPathExtension().lastPathComponent
        }
    }
}

public struct ImportPlan: Sendable {
    public struct File: Sendable, Equatable {
        /// Relative, `/`-separated, as it will be under the game's folder.
        public var path: String
        public var size: UInt64
        /// Folder: the path under the source; zip: the entry's path in the archive.
        public var from: String
    }

    public var source: ImportSource
    /// The folder name the game asks for (the zip's single top folder, else the source's name).
    public var name: String
    public var files: [File]
    public var directories: [String]
    public var skippedSymlinks: Int
    public var totalBytes: UInt64 { files.reduce(0) { $0 + $1.size } }
}

public enum ImportError: Error, Equatable, CustomStringConvertible {
    case empty
    case notDownloaded(Int)
    case refused(String)
    case insufficientSpace(needed: UInt64, available: UInt64)

    public var description: String {
        switch self {
        case .empty: "There is nothing to import there."
        case let .notDownloaded(n): "\(n) of its files are still in iCloud. Download the folder in Files first."
        case let .refused(why): "Playport can't import this: \(why)"
        case let .insufficientSpace(needed, available):
            "Not enough free space: \(ByteCount.format(needed)) needed, \(ByteCount.format(available)) free."
        }
    }
}

public struct GameImporter: Sendable {
    public let layout: InstallLayout
    /// Free space kept beyond what is left to copy: this fraction of it, plus `reserveBytes`.
    public var marginFraction = 0.05
    public var reserveBytes: UInt64 = 256 << 20
    /// The volume query; tests substitute a fixed figure.
    public var freeSpace: @Sendable (URL) throws -> UInt64 = { try InstallFS.availableCapacity($0) }

    public init(layout: InstallLayout) {
        self.layout = layout
    }

    public struct Progress: Sendable {
        public var bytesDone: UInt64
        public var bytesTotal: UInt64
        public var filesDone: Int
        public var filesTotal: Int
    }

    // MARK: the plan

    public static func plan(_ source: ImportSource) throws -> ImportPlan {
        switch source {
        case let .folder(url): try planFolder(url)
        case let .zip(url): try planZip(url)
        }
    }

    static func planFolder(_ root: URL) throws -> ImportPlan {
        var files: [ImportPlan.File] = [], dirs: [String] = []
        var symlinks = 0, placeholders = 0
        var seen = Set<String>()
        func walk(_ dir: URL, _ rel: [String]) throws {
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            for name in names {
                if name == ".DS_Store" { continue }
                if name.hasPrefix("."), name.hasSuffix(".icloud") { placeholders += 1; continue }
                let url = dir.appendingPathComponent(name)
                var st = stat()
                guard lstat(url.path, &st) == 0 else { throw ImportError.refused("\(name) cannot be read") }
                let kind = st.st_mode & S_IFMT
                if kind == S_IFLNK { symlinks += 1; continue }
                let path = rel + [name]
                do { try WindowsName.check(path: path, seen: &seen) } catch { throw ImportError.refused("\(error)") }
                if kind == S_IFDIR {
                    dirs.append(path.joined(separator: "/"))
                    try walk(url, path)
                } else if kind == S_IFREG {
                    let p = path.joined(separator: "/")
                    files.append(.init(path: p, size: UInt64(st.st_size), from: p))
                }
            }
        }
        try walk(root, [])
        if placeholders > 0 { throw ImportError.notDownloaded(placeholders) }
        guard !files.isEmpty else { throw ImportError.empty }
        return ImportPlan(source: .folder(root), name: root.lastPathComponent, files: files, directories: dirs,
                          skippedSymlinks: symlinks)
    }

    static func planZip(_ url: URL) throws -> ImportPlan {
        let zip: ZipArchive
        do { zip = try ZipArchive(url: url) } catch { throw ImportError.refused("it is not a zip Playport can read (\(error))") }
        var entries: [(parts: [String], entry: ZipArchive.Entry)] = []
        var symlinks = 0
        for e in zip.entries {
            if e.isSymlink { symlinks += 1; continue }
            let parts = e.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            guard !parts.isEmpty, !e.path.hasPrefix("/") else { throw ImportError.refused("\(e.path) is not a relative path") }
            if parts.first == "__MACOSX" || parts.last == ".DS_Store" { continue }
            if e.encrypted { throw ImportError.refused("\(e.path) is encrypted") }
            if !e.isDirectory, e.method != 0, e.method != 8 {
                throw ImportError.refused("\(e.path) uses \(ZipArchive.methodName(e.method)) compression; only stored and deflate are supported")
            }
            entries.append((parts, e))
        }
        // One folder at the top holding everything: that is the game's folder.
        var name = url.deletingPathExtension().lastPathComponent
        let tops = Set(entries.map { $0.parts[0] })
        if tops.count == 1, let top = tops.first,
           entries.allSatisfy({ $0.parts.count > 1 || $0.entry.isDirectory }) {
            name = top
            entries = entries.compactMap { $0.parts.count > 1 ? (Array($0.parts.dropFirst()), $0.entry) : nil }
        }
        var files: [ImportPlan.File] = [], dirs = Set<String>()
        var seen = Set<String>()
        for (parts, e) in entries {
            for i in 1..<max(1, parts.count) { dirs.insert(parts[0..<i].joined(separator: "/")) }
            if e.isDirectory {
                dirs.insert(parts.joined(separator: "/"))
                continue
            }
            do { try WindowsName.check(path: parts, seen: &seen) } catch { throw ImportError.refused("\(error)") }
            files.append(.init(path: parts.joined(separator: "/"), size: e.size, from: e.path))
        }
        for d in dirs {
            do { for c in d.split(separator: "/") { try WindowsName.check(String(c)) } } catch { throw ImportError.refused("\(error)") }
            if seen.contains(d.lowercased()) { throw ImportError.refused("\(d) is both a file and a folder") }
        }
        guard !files.isEmpty else { throw ImportError.empty }
        return ImportPlan(source: .zip(url), name: name, files: files.sorted { $0.path < $1.path }, directories: dirs.sorted(),
                          skippedSymlinks: symlinks)
    }

    /// `name`, or `name 2`, `name 3`…: not a folder in C:\Games yet (without case), nor one of `taken`.
    public static func uniqueFolder(_ name: String, existing: [String], taken: [String] = []) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix(".") { base.removeLast() }
        if (try? WindowsName.check(base)) == nil || base.hasPrefix(".") { base = "Game" }
        let used = Set((existing + taken).map { $0.lowercased() })
        if !used.contains(base.lowercased()) { return base }
        var n = 2
        while used.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: the copy

    public func stage(folder: String) -> URL {
        layout.gamesRoot.appendingPathComponent(".stage-import-\(folder)", isDirectory: true)
    }

    /// Copies `plan` into the stage, then into `Games/<folder>`, and writes the receipt.
    /// Throws `CancellationError` when the task is cancelled; the stage is kept for a resume.
    public func run(_ plan: ImportPlan, folder: String, now: Date = Date(),
                    progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> StoreReceipt {
        let fm = FileManager.default
        try InstallFS.makeDirectory(layout.gamesRoot)
        let final = layout.gamesRoot.appendingPathComponent(folder, isDirectory: true)
        guard !fm.fileExists(atPath: final.path) else { throw ImportError.refused("C:\\Games\\\(folder) already exists") }
        let stage = self.stage(folder: folder)
        try InstallFS.makeDirectory(stage)
        for d in plan.directories { try InstallFS.makeDirectory(try InstallFS.resolveInside(stage, d, createParents: true)) }
        // What is in place already (a resumed import) is not copied again.
        var done: UInt64 = 0, filesDone = 0
        var todo: [ImportPlan.File] = []
        for f in plan.files {
            let at = try InstallFS.resolveInside(stage, f.path, createParents: true)
            if InstallFS.fileSize(at) == f.size { done += f.size; filesDone += 1 } else { todo.append(f) }
        }
        let left = plan.totalBytes - done
        let needed = left + UInt64(Double(left) * marginFraction) + reserveBytes
        let available = try freeSpace(layout.gamesRoot)
        guard available >= needed else { throw ImportError.insufficientSpace(needed: needed, available: available) }
        let total = plan.totalBytes, count = plan.files.count
        progress(Progress(bytesDone: done, bytesTotal: total, filesDone: filesDone, filesTotal: count))
        var zip: ZipArchive?
        if case let .zip(u) = plan.source { zip = try ZipArchive(url: u) }
        let byPath = Dictionary((zip?.entries ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var lastReport = Date()
        for f in todo {
            try Task.checkCancellation()
            let dst = try InstallFS.resolveInside(stage, f.path, createParents: true)
            let part = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).part")
            try? fm.removeItem(at: part)
            var copied: UInt64 = 0
            let tick: (UInt64) throws -> Void = { n in
                copied += n
                if Date().timeIntervalSince(lastReport) >= 0.5 {
                    lastReport = Date()
                    progress(Progress(bytesDone: done + copied, bytesTotal: total, filesDone: filesDone, filesTotal: count))
                }
                if Task.isCancelled { throw CancellationError() }
            }
            switch plan.source {
            case let .folder(root):
                let src = root.appendingPathComponent(f.from)
                if !Self.clone(src, part) { try Self.copy(src, part, tick) }
            case .zip:
                guard let zip, let e = byPath[f.from] else { throw ImportError.refused("\(f.from) is no longer in the archive") }
                try Self.write(part) { sink in try zip.extract(e) { buf in try sink(buf); try tick(UInt64(buf.count)) } }
            }
            guard InstallFS.fileSize(part) == f.size else {
                throw ClientError.verificationFailed("\(f.path) copied as \(InstallFS.fileSize(part) ?? 0) bytes, not \(f.size)")
            }
            guard rename(part.path, dst.path) == 0 else { throw ClientError.transport("rename \(f.path) errno \(errno)") }
            done += f.size
            filesDone += 1
        }
        progress(Progress(bytesDone: total, bytesTotal: total, filesDone: count, filesTotal: count))
        guard rename(stage.path, final.path) == 0 else { throw ClientError.transport("rename into C:\\Games errno \(errno)") }
        let marker = StoreMarkers.detect(in: final)
        let key = StoreGameKey(store: .local, id: folder)
        let receipt = StoreReceipt(store: .local, storeID: key.id, name: marker?.name ?? folder, installDir: folder,
                                   executable: marker?.executable, arguments: marker?.arguments,
                                   workingDir: marker?.workingDir, files: plan.files.count, bytes: total, installedAt: now,
                                   importedFrom: plan.source.url.lastPathComponent,
                                   hintSteamAppID: StoreMarkers.steamAppIDHint(in: final))
        try layout.saveReceipt(receipt)
        return receipt
    }

    /// Cancel: the stage goes.
    public func discard(folder: String) {
        try? FileManager.default.removeItem(at: stage(folder: folder))
    }

    /// Whether a stopped import of `folder` left files to resume from.
    public func hasStage(folder: String) -> Bool {
        FileManager.default.fileExists(atPath: stage(folder: folder).path)
    }

    // MARK: files

    /// A clone, where the volume makes one (APFS, the same volume): no space, no time.
    static func clone(_ src: URL, _ dst: URL) -> Bool {
        #if canImport(Darwin)
        return copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) == 0
        #else
        return false
        #endif
    }

    static func copy(_ src: URL, _ dst: URL, _ tick: (UInt64) throws -> Void) throws {
        let fd = sysOpen(src.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
        guard fd >= 0 else { throw ImportError.refused("\(src.lastPathComponent) cannot be read (errno \(errno))") }
        defer { _ = sysClose(fd) }
        try write(dst) { sink in
            let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
            defer { buf.deallocate() }
            while true {
                let n = read(fd, buf.baseAddress, buf.count)
                if n < 0, errno == EINTR { continue }
                guard n >= 0 else { throw ClientError.transport("read \(src.lastPathComponent) errno \(errno)") }
                if n == 0 { return }
                let chunk = UnsafeRawBufferPointer(rebasing: buf[0..<n])
                try sink(chunk)
                try tick(UInt64(n))
            }
        }
    }

    /// Opens `dst` for writing (never through a link), lets `body` fill it, then syncs it.
    static func write(_ dst: URL, _ body: (@escaping (UnsafeRawBufferPointer) throws -> Void) throws -> Void) throws {
        let fd = sysOpen(dst.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ClientError.unsafeContent("cannot create \(dst.lastPathComponent) (errno \(errno))") }
        defer { _ = sysClose(fd) }
        try body { buf in
            var off = 0
            while off < buf.count {
                let n = Glibc_or_Darwin_write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else {
                    if errno == ENOSPC { throw ImportError.insufficientSpace(needed: UInt64(buf.count - off), available: 0) }
                    throw ClientError.transport("write \(dst.lastPathComponent) errno \(errno)")
                }
                off += n
            }
        }
        guard fsync(fd) == 0 else { throw ClientError.transport("fsync \(dst.lastPathComponent) errno \(errno)") }
    }
}

@inline(__always) private func Glibc_or_Darwin_write(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) -> Int {
    #if canImport(Glibc)
    return Glibc.write(fd, p, n)
    #else
    return Darwin.write(fd, p, n)
    #endif
}

/// The launch record a store left in a game's folder: GOG's `goggame-<id>.info`
/// (its name and primary play task), Epic's `.egstore/*.mancpn`. It says how to
/// start the game, never whose copy it is: a folder Playport did not install from
/// a store is a Local game (decision 0057, owner 2026-10-06).
public enum StoreMarkers {
    public struct Marker: Equatable, Sendable {
        public var key: StoreGameKey
        public var name: String?
        public var version: String?
        public var executable: String?
        public var arguments: [String]?
        public var workingDir: String?
    }

    public static func detect(in dir: URL) -> Marker? {
        gog(in: dir) ?? epic(in: dir)
    }

    /// The root game's `goggame-<id>.info` (DLCs have their own), its primary play task.
    static func gog(in dir: URL) -> Marker? {
        struct Info: Decodable {
            struct Task: Decodable {
                var isPrimary: Bool?
                var type: String?
                var category: String?
                var path: String?
                var arguments: String?
                var workingDir: String?
            }
            var gameId: String?
            var rootGameId: String?
            var name: String?
            var buildId: String?
            var playTasks: [Task]?
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.lowercased().hasPrefix("goggame-") && $0.lowercased().hasSuffix(".info") }.sorted()
        let infos = names.compactMap { n -> Info? in
            (try? Data(contentsOf: dir.appendingPathComponent(n))).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
        }
        guard let root = infos.first(where: { $0.gameId != nil && $0.gameId == $0.rootGameId }) ?? infos.first(where: { $0.gameId != nil }),
              let id = root.gameId, !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        let tasks = (root.playTasks ?? []).filter { ($0.type ?? "FileTask") == "FileTask" && $0.path != nil }
        let task = tasks.first { $0.isPrimary == true } ?? tasks.first { ($0.category ?? "game") == "game" }
        let exe = task?.path.flatMap { Adoption.locate($0, in: dir) }
        return Marker(key: StoreGameKey(store: .gog, id: id), name: root.name, version: root.buildId, executable: exe,
                      arguments: task?.arguments.map(LaunchSettings.splitArguments).flatMap { $0.isEmpty ? nil : $0 },
                      workingDir: task?.workingDir.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// `.egstore/<id>.mancpn`: Epic's app name for the folder.
    static func epic(in dir: URL) -> Marker? {
        struct Mancpn: Decodable {
            var AppName: String?
        }
        let store = dir.appendingPathComponent(".egstore", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".mancpn") }.sorted()
        for n in names {
            guard let m = (try? Data(contentsOf: store.appendingPathComponent(n))).flatMap({ try? JSONDecoder().decode(Mancpn.self, from: $0) }),
                  let app = m.AppName, !app.isEmpty,
                  app.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0) })
            else { continue }
            return Marker(key: StoreGameKey(store: .epic, id: app))
        }
        return nil
    }

    /// `steam_appid.txt` at the top or beside an executable one or two folders down: a hint (0045), never an identity.
    public static func steamAppIDHint(in dir: URL) -> UInt32? {
        var queue: [(URL, Int)] = [(dir, 0)]
        while !queue.isEmpty {
            let (at, depth) = queue.removeFirst()
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: at.path)) ?? []).sorted()
            if let n = names.first(where: { $0.lowercased() == "steam_appid.txt" }),
               let text = try? String(contentsOf: at.appendingPathComponent(n), encoding: .utf8),
               let id = UInt32(text.trimmingCharacters(in: .whitespacesAndNewlines)), id > 0 {
                return id
            }
            if depth < 2 {
                for n in names where !n.hasPrefix(".") && Adoption.isDirectory(at.appendingPathComponent(n)) {
                    queue.append((at.appendingPathComponent(n), depth + 1))
                }
            }
        }
        return nil
    }
}
