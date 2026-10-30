// SPDX-License-Identifier: GPL-3.0-only
// Xodus 53ea781dcd073e31d7ea68e894134e9c959bff04 crates/xodus-cli/src/commands/
// streaming.rs (licence first, then every file, kept-encrypted ones as their
// encrypted pages) and crates/msixvc/src/xvd.rs (download_file_http/extract_file);
// translated to Swift by the Playport authors, 2026-10-30. Modified: ContentKit's
// resumable install engine stages the files (journal, free-space checks), every page
// is checked against the hash tree before it is decrypted or written, the stage is
// committed with one rename, and the record keeps what a play needs to decrypt.
// MSIXVC2 (Xodus pull request #219, e8194a89ea372c809015952bcab255e65b2b3089) goes
// through the same engine; see XboxMSIXVC2Package.swift.
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

/// Installs an Xbox copy's MSIXVC or MSIXVC2 into C:\Games through ContentKit's
/// engine: the account's package and licence first, then the package's metadata,
/// then every file straight from the CDN into the stage, checked against the
/// package's hashes (MSIXVC: page by page against its hash tree; MSIXVC2: segment by
/// segment, then each whole file). MSIXVC's plain files are written decrypted, its
/// kept-encrypted ones as their encrypted pages; MSIXVC2's are all written decrypted.
/// An interrupted install resumes from its journal.
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
        let s = try await stage(product: product, contentID: contentID, options: options, progress: progress)
        let config = s.config.flatMap { try? XboxGameConfig.parse($0) }
        let folder = Self.unique(Self.folderName(title, fallback: product), in: layout.gamesRoot)
        try InstallFS.makeDirectory(layout.gamesRoot)
        guard rename(s.tree.path, layout.gamesRoot.appendingPathComponent(folder, isDirectory: true).path) == 0 else {
            throw ClientError.transport("cannot move the Xbox install into C:\\Games (errno \(errno))")
        }
        let installed = XboxInstalled(
            productID: product, contentID: s.contentID, version: s.version, packageName: s.packageName,
            installDir: folder, executable: config?.executable, titleID: config?.titleID, msaAppID: config?.msaAppID, scid: config?.scid,
            files: s.files, encrypted: s.encrypted, bytes: s.bytes)
        try InstallFS.makeDirectory(layout.manifestsDir)
        try InstallFS.writeAtomically(recordFile(product), StoreReceipt.encoder.encode(installed))
        discardStages(product)
        log.info("xbox", "\(product) installed in C:\\Games\\\(folder): \(s.files.count) files, \(installed.encrypted.count) kept encrypted")
        return Result(installed: installed, bytesWritten: s.bytesWritten, downloadedBytes: s.downloadedBytes)
    }

    /// A package staged and checked, its stage tree not yet moved into place.
    struct StagedPackage {
        var contentID: String
        var version: String
        var packageName: String
        var tree: URL
        var files: [XboxInstalledFile]
        var config: [UInt8]?
        var encrypted: [XboxEncryptedFile]
        var bytes: UInt64
        var bytesWritten: UInt64
        var downloadedBytes: UInt64
    }

    /// The account's package `contentID` for `product` and its licence, then every file
    /// through the engine into the product's stage, each checked for the record.
    func stage(product: String, contentID: String, options: InstallEngine.Options,
               progress: @escaping @Sendable (InstallEngine.Progress) -> Void) async throws -> StagedPackage {
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
        let metadata: @Sendable (UInt64) -> Void = { done in
            progress(InstallEngine.Progress(bytesDone: 0, bytesTotal: location.size, downloadedBytes: done, chunksDownloaded: 0,
                                            chunksToDownload: 0, filesVerified: 0, filesTotal: 0, seconds: Date().timeIntervalSince(started)))
        }
        var byID: [UUID: [UInt8]] = [:]
        for k in keys { byID[k.id] = k.key.value }
        let staged = location.isMSIXVC2
            ? try await stageMSIXVC2(location, remote: remote, name: name, keys: byID, metadata: metadata)
            : try await stageMSIXVC(location, remote: remote, name: name, keys: byID, metadata: metadata)
        let plan = staged.plan
        let engine = InstallEngine(tree: layout.stagingTree(name: name), journal: layout.journal(name: name), source: staged.source,
                                   log: log, options: options)
        log.info("xbox", "\(product) \(staged.version): \(plan.files.count) files, \(plan.totalBytes) bytes "
                 + "(\(staged.keptEncrypted) kept encrypted); metadata \(staged.metadataBytes) bytes")
        let r = try await engine.run(plan, progress: progress)

        let tree = layout.stagingTree(name: name)
        let (files, configBytes, encrypted) = try staged.finish(tree)
        return StagedPackage(contentID: location.contentID, version: staged.version, packageName: staged.packageName, tree: tree,
                             files: files, config: configBytes, encrypted: encrypted, bytes: plan.totalBytes, bytesWritten: r.bytes,
                             downloadedBytes: r.downloadedBytes + staged.metadataBytes)
    }

    /// One package format's install: its plan and chunk source, then, once the engine
    /// has staged it, each file checked for the record, MicrosoftGame.config, and the
    /// kept-encrypted files' layout.
    struct Staged {
        var plan: ContentPlan
        var source: any ContentChunkSource
        var version: String
        var packageName: String
        var metadataBytes: UInt64
        var keptEncrypted: Int
        var finish: (URL) throws -> (files: [XboxInstalledFile], config: [UInt8]?, encrypted: [XboxEncryptedFile])
    }

    /// MSIXVC: the XVD's metadata prefix, then pages checked against its hash tree.
    func stageMSIXVC(_ location: XboxPackageLocation, remote: any XboxPackageBytes, name: String, keys: [UUID: [UInt8]],
                     metadata: @escaping @Sendable (UInt64) -> Void) async throws -> Staged {
        let package = try await XboxPackage.fetch(remote, into: prefixFile(name), log: log) { done, _ in metadata(done) }
        guard package.contentID.uuidString.lowercased() == location.contentID else {
            throw ClientError.verificationFailed("Xbox package is for another content ID")
        }
        for id in package.keyIDs where keys[id] == nil {
            throw ClientError.verificationFailed("Xbox licence has no key for this package")
        }
        let source = try XboxPackageSource(package: package, prefix: prefixFile(name), remote: remote, keys: keys, log: log)
        return Staged(plan: package.plan(), source: source, version: package.version, packageName: package.packageName,
                      metadataBytes: package.prefixBytes, keptEncrypted: package.files.filter(\.keepEncrypted).count) { tree in
            var files: [XboxInstalledFile] = []
            for f in package.files {
                try Task.checkCancellation()
                let url = try InstallFS.resolveInside(tree, f.path, createParents: false)
                guard let sha = InstallFS.sha1(url, expectedSize: f.installedSize) else {
                    throw ClientError.verificationFailed("\(f.path) changed after it was checked")
                }
                files.append(XboxInstalledFile(path: f.path, size: f.installedSize, sha1: sha.hex))
            }
            return (files, package.gameConfig, try package.encryptedLayout(source))
        }
    }

    /// MSIXVC2: the ZIP's metadata by ranges, then segments checked by their hashes;
    /// every file is installed decrypted and checked whole against its hash.
    func stageMSIXVC2(_ location: XboxPackageLocation, remote: any XboxPackageBytes, name: String, keys: [UUID: [UInt8]],
                      metadata: @escaping @Sendable (UInt64) -> Void) async throws -> Staged {
        let package = try await XboxMSIXVC2Package.fetch(remote, into: prefixFile(name), licence: keys, log: log, progress: metadata)
        guard [package.contentID, package.fulfillmentContentID].contains(where: { $0?.uuidString.lowercased() == location.contentID }) else {
            throw ClientError.verificationFailed("Xbox package is for another content ID")
        }
        let source = XboxMSIXVC2Source(package: package, remote: remote, log: log)
        let packageName = location.fileName.lowercased().hasSuffix(".msixvc2")
            ? String(location.fileName.dropLast(".msixvc2".count)) : location.fileName
        return Staged(plan: package.plan(), source: source, version: package.version, packageName: packageName,
                      metadataBytes: package.metadataBytes, keptEncrypted: 0) { tree in
            var files: [XboxInstalledFile] = [], config: [UInt8]?
            for f in package.files {
                try Task.checkCancellation()
                let url = try InstallFS.resolveInside(tree, f.path, createParents: false)
                files.append(XboxInstalledFile(path: f.path, size: f.size, sha1: try package.verify(f, at: url).hex))
                if f.path == package.gameConfigPath, f.size <= 4 << 20 { config = Array(try Data(contentsOf: url)) }
            }
            return (files, config, [])
        }
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

    /// Removes the copy's record and stages, its add-ons' records and stages (their files
    /// are in its folder), and, unless `keepSaves`, the saves its runtime keeps for its
    /// SCID under the prefix's `%LOCALAPPDATA%` (`localAppData`). The game's folder is
    /// the library's to delete.
    public func forget(_ product: String, keepSaves: Bool, localAppData: URL) {
        if !keepSaves, let scid = loadRecord(product)?.scid {
            for dir in XboxSaves.folders(scid: scid, localAppData: localAppData) { try? FileManager.default.removeItem(at: dir) }
        }
        forgetAddOns(product)
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
