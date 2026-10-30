// SPDX-License-Identifier: GPL-3.0-only
// Xodus 53ea781dcd073e31d7ea68e894134e9c959bff04 crates/xodus-cli/src/commands/
// streaming.rs (licence first, then every file, kept-encrypted ones as their
// encrypted pages) and crates/msixvc/src/xvd.rs (download_file_http/extract_file);
// translated to Swift by the Playport authors, 2026-10-30. Modified: ContentKit's
// resumable install engine stages the files (journal, free-space checks), every page
// is checked against the hash tree before it is decrypted or written, the stage is
// committed with one rename, and the record keeps what a play needs to decrypt.
import Foundation
import ContentKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A kept-encrypted file as a play needs it (PLA-499): its pages are XTS-AES under the
/// content key `keyID`, each page's tweak its data unit, `region` and the package's
/// content ID (`XboxInstalled.contentID`). The file on disk is its whole pages; the
/// plaintext is the first `size` bytes.
public struct XboxEncryptedFile: Codable, Sendable, Equatable {
    public let path: String
    public let size: UInt64
    public let region: UInt32
    public let keyID: UUID
    public let units: [UInt32]
}

public struct XboxInstalledFile: Codable, Sendable, Equatable {
    public let path: String
    public let size: UInt64
    /// SHA-1 of the bytes on disk, taken once the stage verified against the package.
    public let sha1: String
}

/// What an Xbox install keeps beside its receipt (`manifests/xbox-<ProductId>.json`):
/// no key, ticket or account identifier.
public struct XboxInstalled: Codable, Sendable, Equatable {
    public let productID: String
    /// The package's content ID (VDUID, lower case): licensing's and the tweak's.
    public let contentID: String
    public let version: String
    public let packageName: String
    public let installDir: String
    /// MicrosoftGame.config's: the game's executable (`\`-separated), Title ID, MSA app ID and SCID.
    public let executable: String?
    public let titleID: String?
    public let msaAppID: String?
    public let scid: String?
    public let files: [XboxInstalledFile]
    public let encrypted: [XboxEncryptedFile]
    public let bytes: UInt64
}

/// Installs an Xbox copy's MSIXVC into C:\Games through ContentKit's engine: the
/// account's package and licence first, then the metadata prefix, then every file
/// straight from the CDN into the stage, checked page by page against the package's
/// hash tree. Plain files are written decrypted, kept-encrypted ones as their
/// encrypted pages. An interrupted install resumes from its journal.
public struct XboxInstaller: Sendable {
    public let layout: InstallLayout
    let services: any XboxInstallServices
    let log: Logger
    let market: String
    let bytes: @Sendable (XboxPackageLocation) -> any XboxPackageBytes

    public init(layout: InstallLayout, services: any XboxInstallServices, log: Logger = .silent, market: String = "US",
                bytes: @escaping @Sendable (XboxPackageLocation) -> any XboxPackageBytes = { XboxCDNPackage($0) }) {
        self.layout = layout; self.services = services; self.log = log; self.market = market; self.bytes = bytes
    }

    public struct Result: Sendable {
        public var installed: XboxInstalled
        public var bytesWritten: UInt64
        public var downloadedBytes: UInt64
    }

    func stem(_ product: String) -> String { StoreGameKey(store: .xbox, id: product).fileStem }
    public func recordFile(_ product: String) -> URL { layout.manifestsDir.appendingPathComponent(stem(product) + ".json") }
    public func loadRecord(_ product: String) -> XboxInstalled? {
        (try? Data(contentsOf: recordFile(product))).flatMap { try? JSONDecoder().decode(XboxInstalled.self, from: $0) }
    }
    func stageName(_ product: String, _ version: String) -> String {
        "\(stem(product))_\(version.filter { $0.isNumber || $0 == "." }.prefix(32))"
    }
    func prefixFile(_ name: String) -> URL { layout.stagingRoot.appendingPathComponent(name + ".package") }

    /// Installs the copy `product` from its package `contentID` into a new folder named for `title`.
    public func install(product: String, contentID: String, title: String, options: InstallEngine.Options = .init(),
                        progress: @escaping @Sendable (InstallEngine.Progress) -> Void = { _ in }) async throws -> Result {
        guard StoreGameKey.isProductID(product) else { throw ClientError.unsupported("not an Xbox Product ID") }
        let location = try await services.packageLocation(contentID: contentID)
        let keys: [XboxContentKey]
        switch try await services.licence(contentID: location.contentID, market: market) {
        case .licensed(let licence): keys = licence.keys
        case .refused(let failure): throw XboxInstallRefusal.licence(failure)
        case .unavailable(let problem): throw problem
        }
        let name = stageName(product, location.version.isEmpty ? "0" : location.version)
        let remote = bytes(location)
        let started = Date()
        let package = try await XboxPackage.fetch(remote, into: prefixFile(name), log: log) { done, total in
            progress(InstallEngine.Progress(bytesDone: 0, bytesTotal: location.size, downloadedBytes: done, chunksDownloaded: 0,
                                            chunksToDownload: 0, filesVerified: 0, filesTotal: 0, seconds: Date().timeIntervalSince(started)))
        }
        guard package.contentID.uuidString.lowercased() == location.contentID else {
            throw ClientError.verificationFailed("Xbox package is for another content ID")
        }
        var byID: [UUID: [UInt8]] = [:]
        for k in keys { byID[k.id] = k.key.value }
        for id in package.keyIDs where byID[id] == nil {
            throw ClientError.verificationFailed("Xbox licence has no key for this package")
        }
        let plan = package.plan()
        let source = try XboxPackageSource(package: package, prefix: prefixFile(name), remote: remote, keys: byID, log: log)
        let engine = InstallEngine(tree: layout.stagingTree(name: name), journal: layout.journal(name: name), source: source,
                                   log: log, options: options)
        log.info("xbox", "\(product) \(package.version): \(plan.files.count) files, \(plan.totalBytes) bytes "
                 + "(\(package.files.filter(\.keepEncrypted).count) kept encrypted); metadata \(package.prefixBytes) bytes")
        let r = try await engine.run(plan, progress: progress)

        let tree = layout.stagingTree(name: name)
        var files: [XboxInstalledFile] = []
        for f in package.files {
            try Task.checkCancellation()
            let url = try InstallFS.resolveInside(tree, f.path, createParents: false)
            guard let sha = InstallFS.sha1(url, expectedSize: f.installedSize) else {
                throw ClientError.verificationFailed("\(f.path) changed after it was checked")
            }
            files.append(XboxInstalledFile(path: f.path, size: f.installedSize, sha1: sha.hex))
        }
        let config = package.gameConfig.flatMap { try? XboxGameConfig.parse($0) }
        let folder = Self.unique(Self.folderName(title, fallback: product), in: layout.gamesRoot)
        try InstallFS.makeDirectory(layout.gamesRoot)
        guard rename(tree.path, layout.gamesRoot.appendingPathComponent(folder, isDirectory: true).path) == 0 else {
            throw ClientError.transport("cannot move the Xbox install into C:\\Games (errno \(errno))")
        }
        let installed = XboxInstalled(
            productID: product, contentID: location.contentID, version: package.version, packageName: package.packageName,
            installDir: folder, executable: config?.executable, titleID: config?.titleID, msaAppID: config?.msaAppID, scid: config?.scid,
            files: files, encrypted: try package.encryptedLayout(source), bytes: plan.totalBytes)
        try InstallFS.makeDirectory(layout.manifestsDir)
        try InstallFS.writeAtomically(recordFile(product), StoreReceipt.encoder.encode(installed))
        discardStages(product)
        log.info("xbox", "\(product) installed in C:\\Games\\\(folder): \(files.count) files, \(installed.encrypted.count) kept encrypted")
        return Result(installed: installed, bytesWritten: r.bytes, downloadedBytes: r.downloadedBytes + package.prefixBytes)
    }

    public struct VerifyReport: Sendable {
        public var files: Int
        public var bad: [String]
    }

    /// Every installed file by size, then SHA-1.
    public func verify(_ product: String) throws -> VerifyReport {
        guard let rec = loadRecord(product) else { throw ClientError.notFound("no Xbox install record for \(product)") }
        let dir = layout.gamesRoot.appendingPathComponent(rec.installDir, isDirectory: true)
        var bad: [String] = []
        for f in rec.files {
            try Task.checkCancellation()
            guard let url = try? InstallFS.resolveInside(dir, f.path, createParents: false),
                  InstallEngine.fileMatches(url, size: f.size, hash: .sha1(Array(hexBytes: f.sha1) ?? [])) else { bad.append(f.path); continue }
        }
        return VerifyReport(files: rec.files.count, bad: bad)
    }

    /// Removes the copy's record and stages, and, unless `keepSaves`, the saves its
    /// runtime keeps for its SCID under the prefix's `%LOCALAPPDATA%` (`localAppData`).
    /// The game's folder is the library's to delete.
    public func forget(_ product: String, keepSaves: Bool, localAppData: URL) {
        if !keepSaves, let scid = loadRecord(product)?.scid {
            for dir in XboxSaves.folders(scid: scid, localAppData: localAppData) { try? FileManager.default.removeItem(at: dir) }
        }
        try? FileManager.default.removeItem(at: recordFile(product))
        discardStages(product)
    }

    public func discardStages(_ product: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.stagingRoot.path)) ?? []
        for n in names where n.hasPrefix(stem(product) + "_") {
            try? FileManager.default.removeItem(at: layout.stagingRoot.appendingPathComponent(n))
        }
    }

    public func hasStage(_ product: String) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: layout.stagingRoot.path)) ?? []).contains { $0.hasPrefix(stem(product) + "_") }
    }

    /// A folder name Windows and the library accept, from the copy's title.
    static func folderName(_ title: String, fallback: String) -> String {
        let bad = Set("<>:\"/\\|?*")
        var name = String(title.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init).filter { !bad.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        while name.hasSuffix(".") { name.removeLast() }
        name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
        return (try? WindowsName.check(name)) != nil ? name : fallback
    }

    static func unique(_ name: String, in games: URL) -> String {
        let have = Set(((try? FileManager.default.contentsOfDirectory(atPath: games.path)) ?? []).map { $0.lowercased() })
        if !have.contains(name.lowercased()) { return name }
        let tagged = "\(name) (Xbox)"
        if !have.contains(tagged.lowercased()) { return tagged }
        var n = 2
        while have.contains("\(tagged) \(n)".lowercased()) { n += 1 }
        return "\(tagged) \(n)"
    }
}

/// Where the Xbox runtime keeps a title's local saves under `%LOCALAPPDATA%`, by SCID
/// (Xodus Nexus's xgameruntime: `XodusGameSave\<xuid>\<scid with non [A-Za-z0-9-] as _>`,
/// `XodusGameSaveFiles[Cache]\<xuid>\<scid as lower-case hex>`), for every account.
public enum XboxSaves {
    public static func folders(scid: String, localAppData: URL) -> [URL] {
        let plain = String(scid.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "_" })
        let hex = Array(scid.utf8).hex
        var out: [URL] = []
        for (root, leaf) in [("XodusGameSave", plain), ("XodusGameSaveFiles", hex), ("XodusGameSaveFilesCache", hex)] {
            let base = localAppData.appendingPathComponent(root, isDirectory: true)
            for user in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] where user.allSatisfy(\.isNumber) {
                let dir = base.appendingPathComponent(user, isDirectory: true).appendingPathComponent(leaf, isDirectory: true)
                if FileManager.default.fileExists(atPath: dir.path) { out.append(dir) }
            }
        }
        return out
    }
}

/// The fields of MicrosoftGame.config an install keeps.
struct XboxGameConfig: Equatable {
    var executable: String?
    var titleID: String?
    var msaAppID: String?
    var scid: String?

    static func parse(_ bytes: [UInt8]) throws -> XboxGameConfig {
        let root = try XboxXML.parse(bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? Array(bytes.dropFirst(3)) : bytes)
        let executables = root.all("Executable")
        let game = executables.first { $0.attr("Id") == "Game" } ?? executables.first
        let exe = game?.attr("Name").flatMap { try? SafePath.normalize($0) }?.replacingOccurrences(of: "/", with: "\\")
        let scid = root.all("ExtendedAttribute").first { $0.attr("Name") == "Scid" }?.attr("Value")
        func id(_ s: String?, _ ok: (Character) -> Bool, max: Int) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.count <= max, s.allSatisfy(ok) else { return nil }
            return s
        }
        return XboxGameConfig(executable: exe, titleID: id(root.value("TitleId"), \.isHexDigit, max: 8),
                              msaAppID: id(root.value("MSAAppId"), \.isHexDigit, max: 16),
                              scid: id(scid, { $0.isHexDigit || $0 == "-" }, max: 36))
    }
}

extension Array where Element == UInt8 {
    init?(hexBytes s: String) {
        guard s.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        self = out
    }
}
