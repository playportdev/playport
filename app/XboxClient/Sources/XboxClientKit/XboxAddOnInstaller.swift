// SPDX-License-Identifier: GPL-3.0-only
// Xodus Nexus e0668a12f1da931aed13537ef04295599011317b src/main/game-content.ts
// (validate: the add-on's Store ID, its main package and allowed products against the
// game's; the install marker) and src/main/index.ts (an add-on streamed by its content
// ID like a game); the folder rule from nexus-xgameruntime
// ab2fac35b500b87fefe51add26a0672a71d11576 src/System/Package/Content.h
// (content_discover: the game's `DLC` folder's children; content_load); translated to
// Swift by the Playport authors, 2026-10-30. Modified: the add-on goes into the game's
// own folder, `DLC\<ProductId>`, not a launcher data root, so the game's Remove takes
// it too; the record sits beside the game's under `manifests/`.
import Foundation
import ContentKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// An add-on installed in its game's folder. `installed.installDir` is relative to the
/// game's folder (`DLC/<ProductId>`); the rest is a copy's record (no key, ticket or
/// account identifier).
public struct XboxInstalledAddOn: Codable, Sendable, Equatable {
    public let baseProductID: String
    public let installed: XboxInstalled
}

/// Why an add-on was not installed. Each text says what to do.
public enum XboxAddOnRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    case gameNotInstalled
    case notForThisGame
    case keptEncrypted
    public var description: String {
        switch self {
        case .gameNotInstalled: "Install the game first: its add-ons go into its folder."
        case .notForThisGame: "Microsoft's package for this add-on is not for this game, so Playport did not install it."
        case .keptEncrypted: "This add-on's package keeps files encrypted, which Playport supports for games only."
        }
    }
}

extension XboxInstaller {
    /// The game folder's subfolder the runtime scans for add-on packages.
    public static let addOnsFolder = "DLC"

    func addOnsDir(_ base: String) -> URL { layout.manifestsDir.appendingPathComponent(stem(base) + ".addons", isDirectory: true) }
    func addOnRecordFile(_ addOn: String, base: String) -> URL { addOnsDir(base).appendingPathComponent(stem(addOn) + ".json") }

    /// The game's installed add-ons, by Product ID: those whose folder is in the game's
    /// folder now (a game installed again into a new folder left its add-ons behind).
    public func addOnRecords(base: String) -> [XboxInstalledAddOn] {
        guard let folder = gameFolder(base) else { return [] }
        return storedAddOns(base).filter { a in
            guard let at = try? InstallFS.resolveInside(folder, a.installed.installDir, createParents: false) else { return false }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: at.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// Every add-on record kept for the game, its folder there or not.
    func storedAddOns(_ base: String) -> [XboxInstalledAddOn] {
        let dir = addOnsDir(base)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        return names.compactMap { name in
            (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(XboxInstalledAddOn.self, from: $0) }
        }.filter { $0.baseProductID == base && StoreGameKey.isProductID($0.installed.productID) }
    }

    func gameFolder(_ base: String) -> URL? {
        loadRecord(base).map { layout.gamesRoot.appendingPathComponent($0.installDir, isDirectory: true) }
    }

    /// Where Windows sees the game's add-ons (`C:\Games\<folder>\DLC`), for the play's
    /// `XODUS_CONTENT_ROOTS`; none until one is installed.
    public func addOnRoots(base: String) -> [String] {
        guard let rec = loadRecord(base), !addOnRecords(base: base).isEmpty else { return [] }
        return ["C:\\Games\\" + rec.installDir + "\\" + Self.addOnsFolder]
    }

    /// Installs the add-on `addOn` of the installed game `base` from its package
    /// `contentID`, through the copy's own path (licence, package, engine), checks that
    /// the package is this game's, and moves it into the game's `DLC\<ProductId>`.
    public func installAddOn(_ addOn: String, contentID: String, base: String, options: InstallEngine.Options = .init(),
                             progress: @escaping @Sendable (InstallEngine.Progress) -> Void = { _ in }) async throws -> Result {
        guard StoreGameKey.isProductID(addOn), StoreGameKey.isProductID(base), addOn != base else {
            throw ClientError.unsupported("not an Xbox add-on's Product ID")
        }
        guard let folder = gameFolder(base), let game = try? XboxPackageConfig.load(folder: folder) else {
            throw XboxAddOnRefusal.gameNotInstalled
        }
        let s = try await stage(product: addOn, contentID: contentID, options: options, progress: progress)
        do {
            guard Self.isAddOn(s.tree, addOn: addOn, of: game, base: base) else { throw XboxAddOnRefusal.notForThisGame }
            guard s.encrypted.isEmpty else { throw XboxAddOnRefusal.keptEncrypted }
        } catch {
            discardStages(addOn)
            throw error
        }
        let target = try InstallFS.resolveInside(folder, Self.addOnsFolder + "/" + addOn, createParents: true)
        // Installed again: the new package replaces the old one whole.
        try? FileManager.default.removeItem(at: target)
        guard rename(s.tree.path, target.path) == 0 else {
            throw ClientError.transport("cannot move the Xbox add-on into its game's folder (errno \(errno))")
        }
        let installed = XboxInstalled(
            productID: addOn, contentID: s.contentID, version: s.version, packageName: s.packageName,
            installDir: Self.addOnsFolder + "/" + addOn, executable: nil, titleID: nil, msaAppID: nil, scid: nil,
            msaFullTrust: nil, relatedProductIDs: nil, files: s.files, encrypted: [], bytes: s.bytes)
        try InstallFS.makeDirectory(addOnsDir(base))
        try InstallFS.writeAtomically(addOnRecordFile(addOn, base: base),
                                      StoreReceipt.encoder.encode(XboxInstalledAddOn(baseProductID: base, installed: installed)))
        discardStages(addOn)
        log.info("xbox", "\(base): add-on \(addOn) \(s.version) installed in its folder's \(Self.addOnsFolder): \(s.files.count) files")
        return Result(installed: installed, bytesWritten: s.bytesWritten, downloadedBytes: s.downloadedBytes)
    }

    /// What the runtime asks of an add-on's folder (content_load), checked before it is
    /// placed: its MicrosoftGame.config and appxmanifest.xml name the same package, its
    /// own Store ID, the game's identity as main package and the game's Store ID as
    /// allowed, and it has one `layout_<id>.xml`.
    static func isAddOn(_ folder: URL, addOn: String, of game: XboxPackageConfig, base: String) -> Bool {
        guard let config = try? XboxPackageConfig.load(folder: folder), config.storeID == addOn, config.dependency == game.name,
              config.publisher == game.publisher, config.allowed.contains(base) else { return false }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard names.filter({ $0.lowercased().hasPrefix("layout_") && $0.lowercased().hasSuffix(".xml") }).count == 1,
              let name = names.first(where: { $0.lowercased() == "appxmanifest.xml" }),
              let url = try? InstallFS.resolveInside(folder, name, createParents: false),
              let size = InstallFS.fileSize(url), size <= 1 << 20,
              let appx = try? XboxXML.parse(Array(Data(contentsOf: url))), appx.local == "Package",
              let identity = appx.child("Identity") else { return false }
        return identity.attr("Name") == config.name && identity.attr("Publisher") == config.publisher
            && identity.attr("Version") == config.version
            && appx.child("Dependencies")?.child("MainPackageDependency")?.attr("Name") == game.name
    }

    /// Every file of the add-on by size, then SHA-1.
    public func verifyAddOn(_ addOn: String, base: String) throws -> VerifyReport {
        guard let rec = addOnRecords(base: base).first(where: { $0.installed.productID == addOn })?.installed, let folder = gameFolder(base) else {
            throw ClientError.notFound("no Xbox install record for the add-on \(addOn)")
        }
        let dir = try InstallFS.resolveInside(folder, rec.installDir, createParents: false)
        var bad: [String] = []
        for f in rec.files {
            try Task.checkCancellation()
            guard let url = try? InstallFS.resolveInside(dir, f.path, createParents: false),
                  InstallEngine.fileMatches(url, size: f.size, hash: .sha1(Array(hexBytes: f.sha1) ?? [])) else { bad.append(f.path); continue }
        }
        return VerifyReport(files: rec.files.count, bad: bad)
    }

    /// Removes the add-on's folder, record and stages; the game stays.
    public func removeAddOn(_ addOn: String, base: String) throws {
        guard StoreGameKey.isProductID(addOn) else { throw ClientError.unsupported("not an Xbox add-on's Product ID") }
        if let folder = gameFolder(base) {
            let target = try InstallFS.resolveInside(folder, Self.addOnsFolder + "/" + addOn, createParents: false)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
        try? FileManager.default.removeItem(at: addOnRecordFile(addOn, base: base))
        discardStages(addOn)
        log.info("xbox", "\(base): add-on \(addOn) removed")
    }

    /// The game's Remove: its add-ons' records and stages (their files go with its folder).
    func forgetAddOns(_ base: String) {
        for a in storedAddOns(base) { discardStages(a.installed.productID) }
        try? FileManager.default.removeItem(at: addOnsDir(base))
    }
}
