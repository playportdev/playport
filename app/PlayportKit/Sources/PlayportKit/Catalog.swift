// SPDX-License-Identifier: GPL-3.0-or-later
// The catalogue of installed titles: Library/Application Support/Playport/catalog.json,
// not a secret. It is rebuilt by adoption, a scan of the prefix's C:\Games,
// every time the library opens, so it never disagrees with what is on disk:
//
//   installed  a folder the install engine wrote (its receipt under installs/ wins)
//   cohort     a folder without a receipt named as a titles.json entry: that pin, Ready
//   found      any other folder with a Windows executable: Ready too
//
// What the scan cannot see is carried over from the previous catalogue: when
// the title was added and last played, its play time, and the last verification (dropped
// when the build changes).

import Foundation
import SteamClientKit

public struct InstalledTitle: Codable, Equatable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable {
        case cohort, installed, found
    }

    public struct Verification: Codable, Equatable, Sendable {
        public var date: Date
        public var files: Int
        public var bad: Int
        public var unlisted: Int
        public var ok: Bool { bad == 0 }

        public init(date: Date, files: Int, bad: Int, unlisted: Int) {
            self.date = date
            self.files = files
            self.bad = bad
            self.unlisted = unlisted
        }
    }

    /// `app-<appID>` when the app is known, else `dir-<lowercased folder>`.
    public var id: String
    public var appID: UInt32?
    public var name: String
    public var developer: String?
    /// The folder under C:\Games.
    public var installDir: String
    /// Relative to the folder (a cohort pin may name one below it, `bin\x64\witcher3.exe`);
    /// nil when none was found.
    public var executable: String?
    public var buildID: UInt32?
    public var depots: [CohortTitle.Depot]
    public var sizeBytes: UInt64?
    public var source: Source
    /// A sha256sum list in the cohort directory, when the title has one.
    public var checksums: String?
    public var note: String?
    public var addedAt: Date
    public var lastPlayed: Date?
    /// Seconds played in all, the sum of its sessions (PlayTime.swift); nil for never.
    public var playSeconds: TimeInterval? = nil
    public var lastVerification: Verification?
    /// The Steam branch a Steam install follows; nil is public.
    public var branch: String? = nil
    /// Legacy routing flag, also written for older catalogue readers. Detection
    /// now includes API function imports, reachable DLLs and dynamic references.
    public var importsDirect3D12: Bool? = nil
    /// Best-effort evidence for available APIs, not the active renderer. Rebuilt
    /// on adoption; nil in older catalogues. Explicit launch settings still win.
    public var direct3D: Direct3D.Detection? = nil
    public var detectsDirect3D12: Bool { direct3D?.hasDirect3D12 ?? (importsDirect3D12 == true) }
    /// The COFF machine of the selected executable (0x14c i386, 0x8664 x86-64); rebuilt
    /// on adoption, nil in older catalogues or when it is no PE.
    public var executableMachine: UInt16? = nil
    /// An i386 (WoW64) title: its default backend is Vulkan (decision 0047).
    public var isI386: Bool { executableMachine == 0x14c }

    public enum Badge: String, Sendable {
        case ready = "Ready"
        case needsRepair = "Needs repair"
        case incomplete = "No executable"
    }

    public var badge: Badge {
        if executable == nil { return .incomplete }
        if let v = lastVerification, !v.ok { return .needsRepair }
        return .ready
    }

    public var canPlay: Bool { executable != nil }

    /// A staged cohort title, or a Steam receipt for that exact app and build,
    /// runs with its pinned arguments, madeira.cfg keys and screen; other builds with none.
    public func launchPlan(cohort: Cohort) throws -> LaunchPlan {
        guard let executable else { throw LaunchPlanError.badPath(installDir) }
        let candidate = cohort.title(installDir: installDir)
        let pin = candidate.flatMap {
            source == .cohort || (source == .installed && appID == $0.appID && buildID == $0.buildID) ? $0 : nil
        }
        return try LaunchPlan.make(installDir: installDir, executable: executable, arguments: pin?.arguments ?? [],
                                   config: pin?.config ?? [:], screen: pin?.screen)
    }
}

public struct Catalog: Codable, Equatable, Sendable {
    public var version = 1
    public var titles: [InstalledTitle]

    public init(titles: [InstalledTitle] = []) {
        self.titles = titles
    }

    public func title(id: String) -> InstalledTitle? { titles.first { $0.id == id } }

    public mutating func update(_ id: String, _ change: (inout InstalledTitle) -> Void) {
        guard let i = titles.firstIndex(where: { $0.id == id }) else { return }
        change(&titles[i])
    }
}

/// Where the catalogue and the titles live in the app container: the install
/// engine's layout (SteamClientKit InstallLayout), resolved once, before the
/// runtime moves HOME into the prefix.
public struct PlayportPaths: Sendable {
    public var layout: InstallLayout
    public var catalog: URL { layout.stateRoot.appendingPathComponent("catalog.json") }
    public var games: URL { layout.gamesRoot }

    public init(layout: InstallLayout) {
        self.layout = layout
    }

    /// `home` is the app container (the parent of Documents).
    public static func container(home: URL) -> PlayportPaths { PlayportPaths(layout: .container(home: home)) }
}

public struct CatalogStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// An absent file is an empty catalogue; so is an unreadable one, which is
    /// kept beside as catalog.json.unreadable for a look later, since adoption
    /// rebuilds everything but the play and verification history.
    public func load() -> Catalog {
        guard let data = try? Data(contentsOf: url) else { return Catalog() }
        if let c = try? Self.decoder.decode(Catalog.self, from: data) { return c }
        let aside = url.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return Catalog()
    }

    public func save(_ catalog: Catalog) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(catalog).write(to: url, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

public enum Adoption {
    /// The catalogue for what is in `games` now, keeping what `previous` knew.
    /// `receipts` are the install engine's records (InstallLayout.installsDir).
    public static func scan(games: URL, cohort: Cohort, receipts: [InstallReceipt], previous: Catalog,
                            now: Date = Date()) -> Catalog {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(atPath: games.path)) ?? [])
            .filter { !$0.hasPrefix(".") && isDirectory(games.appendingPathComponent($0)) }
            .sorted()
        var out: [InstalledTitle] = []
        for folder in folders {
            let dir = games.appendingPathComponent(folder, isDirectory: true)
            let exes = executables(in: dir)
            var t: InstalledTitle
            // A Steam install can reuse a cohort folder with a different build or branch.
            // Its receipt, not the folder name, identifies what is actually installed.
            if let r = receipts.first(where: { $0.installDir.lowercased() == folder.lowercased() }) {
                t = InstalledTitle(id: "app-\(r.appID)", appID: r.appID, name: r.name, developer: nil, installDir: folder,
                                   executable: r.executable.flatMap { isPrelauncher($0) ? nil : locate($0, in: dir) }
                                       ?? pick(exes, folder: folder, in: dir),
                                   buildID: r.buildID,
                                   depots: r.depots.map { .init(depotID: $0.depotID, manifestGID: String($0.gid)) },
                                   sizeBytes: r.bytes, source: .installed, checksums: nil, note: nil, addedAt: now,
                                   lastPlayed: nil, lastVerification: nil)
                t.branch = r.branch
            } else if let c = cohort.title(installDir: folder) {
                t = InstalledTitle(id: "app-\(c.appID)", appID: c.appID, name: c.name, developer: c.developer,
                                   installDir: folder, executable: locate(c.executable, in: dir),
                                   buildID: c.buildID, depots: c.depots, sizeBytes: c.installedSize, source: .cohort,
                                   checksums: c.checksums, note: c.note, addedAt: now, lastPlayed: nil,
                                   lastVerification: nil)
            } else {
                t = InstalledTitle(id: "dir-\(folder.lowercased())", appID: nil, name: folder, developer: nil,
                                   installDir: folder, executable: pick(exes, folder: folder, in: dir), buildID: nil, depots: [],
                                   sizeBytes: nil, source: .found, checksums: nil, note: nil, addedAt: now,
                                   lastPlayed: nil, lastVerification: nil)
            }
            if let old = previous.titles.first(where: { $0.id == t.id }) ?? previous.titles.first(where: {
                $0.installDir.lowercased() == folder.lowercased()
            }) {
                t.addedAt = old.addedAt
                t.lastPlayed = old.lastPlayed
                t.playSeconds = old.playSeconds
                if old.buildID == t.buildID { t.lastVerification = old.lastVerification }
                if t.source == .found, old.source == .found { t.sizeBytes = old.sizeBytes }
            }
            t.direct3D = t.executable.map {
                Direct3D.detect(executable: dir.appendingPathComponent($0.replacingOccurrences(of: "\\", with: "/")), root: dir)
            }
            t.importsDirect3D12 = t.direct3D?.hasDirect3D12 ?? false
            t.executableMachine = t.executable.flatMap {
                SteamAPISwap.peMachine(dir.appendingPathComponent($0.replacingOccurrences(of: "\\", with: "/")))
            }
            if t.sizeBytes == nil { t.sizeBytes = directorySize(dir) }
            out.append(t)
        }
        // Two folders can claim one app (a receipt and a same-named cohort
        // pin); keep the first, so every id stays unique.
        var seen = Set<String>()
        out = out.filter { seen.insert($0.id).inserted }
        return Catalog(titles: out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    /// The install engine's receipts, unreadable ones skipped.
    public static func receipts(in dir: URL) -> [InstallReceipt] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap {
            (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(InstallReceipt.self, from: $0) }
        }
    }

    /// Prefer the game over REDprelauncher's unvalidated install/UI chain,
    /// even when Steam names the launcher (including older receipts with no path).
    /// This is selection policy, not a ban on children: the session supports
    /// child pseudo-processes (decision 0030; launcher-feasibility evidence).
    static func isPrelauncher(_ path: String) -> Bool {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last?.lowercased() == "redprelauncher.exe"
    }

    /// The Windows executables directly in a folder, without Unity's crash
    /// handler or REDprelauncher, which are not the game.
    static func executables(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".exe") && !$0.lowercased().hasPrefix("unitycrashhandler") && !isPrelauncher($0) }
            .sorted()
    }

    /// A pinned executable's path as it is on disk, each component matched
    /// without case as Windows does, `\`-joined; nil when it is not a file there.
    static func locate(_ path: String, in dir: URL) -> String? {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        var at = dir
        var found: [String] = []
        for (i, want) in parts.enumerated() {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: at.path)) ?? []
            guard let name = names.first(where: { $0 == want }) ?? names.first(where: { $0.lowercased() == want.lowercased() })
            else { return nil }
            at = at.appendingPathComponent(name)
            found.append(name)
            if i < parts.count - 1, !isDirectory(at) { return nil }
        }
        return isDirectory(at) ? nil : found.joined(separator: "\\")
    }

    /// The executable named like its folder (`Hollow Knight` / `hollow_knight.exe`),
    /// else the only one, else the first by name; with none in the folder itself,
    /// one below it (`nested`). An Unreal Engine game's
    /// `<Project>.exe` is a bootstrap that only starts
    /// `<Project>\Binaries\Win64\<Project>-Win64-Shipping.exe` as a second
    /// process. Prefer the shipping executable when present, avoiding an extra
    /// unvalidated bootstrap and its JIT cost; the runtime does support children.
    static func pick(_ exes: [String], folder: String, in dir: URL? = nil) -> String? {
        let key = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        guard let exe = exes.first(where: { key(String($0.dropLast(4))) == key(folder) }) ?? exes.first else {
            return dir.flatMap { nested(in: $0, folder: folder) }
        }
        let project = String(exe.dropLast(4))
        if let dir, let shipping = locate("\(project)/Binaries/Win64/\(project)-Win64-Shipping.exe", in: dir) {
            return shipping
        }
        return exe
    }

    /// Names, lowercased, of executables and folders that are not the game:
    /// redistributables, installers, crash reporters, anti-cheat, tools.
    static let notTheGame = ["redist", "directx", "dxsetup", "vcredist", "vc_redist", "dotnet", "physx", "setup",
                             "install", "unins", "crash", "reporter", "easyanticheat", "battleye", "uninstall",
                             "support", "tools", "editor", "sdk", "benchmark", "helper", "unitycrashhandler", "redprelauncher"]

    /// A Windows executable up to three folders below `dir`, for a title
    /// whose executable is not at its top (Kingdom Come's `Bin\Win64\KingdomCome.exe`):
    /// one named like the folder, else one in a 64-bit folder (`Win64`, `x64`,
    /// `bin64`), else the shallowest, first by path. Nothing whose path names
    /// a redistributable, installer, crash reporter or tool.
    static func nested(in dir: URL, folder: String) -> String? {
        let key = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        var found: [[String]] = []
        func walk(_ at: URL, _ path: [String]) {
            guard path.count <= 3 else { return }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: at.path)) ?? []).sorted()
            for name in names where !name.hasPrefix(".") {
                let lower = name.lowercased()
                if notTheGame.contains(where: { lower.contains($0) }) { continue }
                let url = at.appendingPathComponent(name)
                if isDirectory(url) { walk(url, path + [name]) }
                else if !path.isEmpty, lower.hasSuffix(".exe") { found.append(path + [name]) }
            }
        }
        walk(dir, [])
        let is64 = { (p: [String]) in p.dropLast().contains { ["win64", "x64", "bin64", "x86_64"].contains($0.lowercased()) } }
        let ranked = found.sorted { a, b in
            let ka = key(String(a.last!.dropLast(4))), kb = key(String(b.last!.dropLast(4)))
            let na = !ka.isEmpty && key(folder).hasPrefix(ka), nb = !kb.isEmpty && key(folder).hasPrefix(kb)
            if na != nb { return na }
            if is64(a) != is64(b) { return is64(a) }
            if a.count != b.count { return a.count < b.count }
            return a.joined(separator: "\\").lowercased() < b.joined(separator: "\\").lowercased()
        }
        return ranked.first?.joined(separator: "\\")
    }

    static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    static func directorySize(_ dir: URL) -> UInt64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true
            else { continue }
            total += UInt64(v.fileSize ?? 0)
        }
        return total
    }
}

public enum TitleVerifier {
    public enum Failure: Error, CustomStringConvertible {
        case noChecksumList

        public var description: String {
            "no checksum list for this title: only pinned cohort titles can be verified without Steam"
        }
    }

    /// Hashes every file of the title's checksum list (SteamClientKit's
    /// streaming verify); files the list does not name are counted, not failed.
    public static func verify(_ title: InstalledTitle, games: URL, cohort: Cohort,
                              now: Date = Date()) async throws -> (InstalledTitle.Verification, TitleInstaller.VerifyReport) {
        guard let list = cohort.checksumList(named: title.checksums) else { throw Failure.noChecksumList }
        let report = try await TitleInstaller.verifySHA256List(dir: games.appendingPathComponent(title.installDir, isDirectory: true),
                                                               list: list)
        return (InstalledTitle.Verification(date: now, files: report.files, bad: report.bad.count,
                                            unlisted: report.unlisted.count), report)
    }
}

public enum ByteCount {
    /// `5.23 GB`: decimal units, as Steam and the evidence records state sizes.
    public static func format(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(bytes), i = 0
        while v >= 1000, i < units.count - 1 {
            v /= 1000
            i += 1
        }
        return i == 0 ? "\(bytes) B" : String(format: v >= 100 ? "%.0f" : v >= 10 ? "%.1f" : "%.2f", v) + " " + units[i]
    }
}
