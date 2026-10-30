// SPDX-License-Identifier: GPL-3.0-only
// Xodus 53ea781dcd073e31d7ea68e894134e9c959bff04 crates/msixvc/src/xvd.rs
// (extract_file: a kept-encrypted file's pages decrypted with their data units) and
// Xodus Nexus e0668a12f1da931aed13537ef04295599011317b src/main/game-content.ts
// (MicrosoftGame.config's RelatedProducts); translated to Swift by the Playport
// authors, 2026-10-30. Modified: decrypted from the install record into a file the
// play swaps in place (PlayportKit InPlaceSwap), no memfd; a launch refusal names
// the sign-in or the licence.
import Foundation
import ContentKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// An installed copy's kept-encrypted files for one play: each one's plaintext from its
/// pages on disk, the install record's layout and the licence's content key.
public struct XboxPlayFiles: Sendable {
    private let files: [String: XboxEncryptedFile]
    private let ciphers: [String: XboxXTS]

    /// Throws `XboxPlayRefusal.noKey` when the licence has no key for one of them.
    public init(installed: XboxInstalled, keys: [XboxContentKey]) throws {
        guard let vduid = UUID(uuidString: installed.contentID) else {
            throw ClientError.verificationFailed("Xbox install record has no content ID")
        }
        var files: [String: XboxEncryptedFile] = [:], ciphers: [String: XboxXTS] = [:]
        for f in installed.encrypted {
            guard let key = keys.first(where: { $0.id == f.keyID }) else { throw XboxPlayRefusal.noKey }
            files[f.path] = f
            ciphers[f.path] = try XboxXTS(key: key.key.value, region: f.region, vduid: vduid)
        }
        self.files = files
        self.ciphers = ciphers
    }

    /// The kept-encrypted files, relative to the copy's folder.
    public var paths: [String] { files.keys.sorted() }

    /// Writes `path`'s plaintext to `out` from `original`, its whole encrypted pages.
    public func plaintext(_ path: String, original: URL, out: URL) throws {
        guard let f = files[path], let xts = ciphers[path] else { throw ClientError.notFound("\(path) is not kept encrypted") }
        let page = XboxXTS.page
        guard f.units.count == (Int(f.size) + page - 1) / page,
              let size = InstallFS.fileSize(original), size >= UInt64(f.units.count * page) else {
            throw ClientError.verificationFailed("\(path) is not the installed copy's; Verify the game")
        }
        let input = open(original.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw ClientError.transport("open \(path) errno \(errno)") }
        defer { close(input) }
        let output = open(out.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard output >= 0 else { throw ClientError.transport("create \(out.lastPathComponent) errno \(errno)") }
        defer { close(output) }
        let perRead = 256
        var buffer = [UInt8](repeating: 0, count: perRead * page)
        var first = 0, left = Int(f.size)
        while first < f.units.count {
            let count = min(perRead, f.units.count - first)
            buffer.removeAll(keepingCapacity: true)
            buffer.append(contentsOf: repeatElement(0, count: count * page))
            let got = buffer.withUnsafeMutableBytes { pread(input, $0.baseAddress, count * page, off_t(first * page)) }
            guard got == count * page else { throw ClientError.transport("read \(path) errno \(errno)") }
            xts.decrypt(&buffer, units: f.units[first..<(first + count)])
            let keep = min(left, count * page)
            let wrote = buffer.withUnsafeBytes { write(output, $0.baseAddress, keep) }
            guard wrote == keep else { throw ClientError.transport("write \(out.lastPathComponent) errno \(errno)") }
            first += count
            left -= keep
        }
    }
}

/// What a play reads from the game's MicrosoftGame.config in its folder (the Xbox
/// runtime finds the same file by walking up from the executable).
public struct XboxGameManifest: Sendable, Equatable {
    public var msaAppID: String?
    public var msaFullTrust: Bool
    /// The `RelatedProducts` it declares, well-formed Product IDs only.
    public var relatedProductIDs: [String]
    /// `DesktopRegistration`'s `KnownDependency` names (such as `VC14`).
    public var knownDependencies: [String]

    /// Throws when the folder has no readable config.
    public static func load(folder: URL) throws -> XboxGameManifest {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard let name = names.first(where: { $0.lowercased() == "microsoftgame.config" }),
              let url = try? InstallFS.resolveInside(folder, name, createParents: false),
              let size = InstallFS.fileSize(url), size <= 1 << 20,
              let bytes = try? [UInt8](Data(contentsOf: url)) else {
            throw ClientError.notFound("the game has no MicrosoftGame.config")
        }
        let root = try XboxXML.parse(bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? Array(bytes.dropFirst(3)) : bytes)
        let related = (root.child("RelatedProducts")?.children ?? []).filter { $0.local == "RelatedProduct" }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter(StoreGameKey.isProductID)
        let app = root.value("MSAAppId").flatMap { $0.count == 16 && $0.allSatisfy(\.isHexDigit) ? $0 : nil }
        let known = root.all("KnownDependency").compactMap { $0.attr("Name") }
        return XboxGameManifest(msaAppID: app, msaFullTrust: root.value("MSAFullTrust")?.lowercased() == "true",
                                relatedProductIDs: related, knownDependencies: known)
    }

    /// A prerequisite installer the package itself carries for a dependency it declares:
    /// its path in the copy's folder, its ids for the prefix's record and its arguments.
    public struct Prerequisite: Sendable, Equatable {
        public var ids: [String]
        public var name: String
        public var path: String
        public var arguments: String
    }

    /// Where an Unreal Engine GDK package ships the VC++ 2015-22 x64 installer for `VC14`
    /// (Xodus Nexus store.ts: the only one it runs; Playport ships no redistributable).
    public static let vc14Installer = "Engine/Extras/Redist/en-us/vc_redist.x64.exe"

    /// The installers for the dependencies it declares that the copy carries, from the
    /// install's file list (`files`, relative paths with their sizes): `VC14`'s, run quietly.
    public func prerequisites(files: [XboxInstalledFile]) -> [Prerequisite] {
        guard knownDependencies.contains(where: { $0.uppercased() == "VC14" }),
              let f = files.first(where: { $0.path.lowercased() == Self.vc14Installer.lowercased() }) else { return [] }
        return [Prerequisite(ids: ["VC14 x64:\(f.size)-\(f.sha1.prefix(16))"], name: "Visual C++ 2015-2022 (x64)",
                             path: f.path, arguments: "/install /quiet /norestart")]
    }
}

extension XboxBridgeCopy {
    /// The copy the bridge serves a play: the Product ID and what its game config declares.
    public init(productID: String, manifest: XboxGameManifest) {
        self.init(productID: productID, relatedProductIDs: manifest.relatedProductIDs, msaAppID: manifest.msaAppID,
                  msaFullTrust: manifest.msaFullTrust)
    }
}

/// Why Play of an Xbox copy did not start the game: the account's sign-in, or the
/// copy's licence. Every case's text says which.
public enum XboxPlayRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    /// Xbox is signed out, or the session can't be renewed or its device was rejected.
    case signedOut
    case signIn(XboxSessionError)
    /// Microsoft definitively refused the licence (or the device, at the 10-device limit).
    case refused(XboxLicenseFailure)
    /// Licensing gave no verdict and no stored licence stands in.
    case unavailable(XboxLicenceProblem)
    /// The licence carries no content key for this copy's files.
    case noKey

    public enum Kind: Sendable { case signIn, licence }

    public var kind: Kind {
        switch self {
        case .signedOut, .signIn: .signIn
        case .refused, .unavailable, .noKey: .licence
        }
    }

    /// The launch message's title.
    public var title: String {
        switch self {
        case .signedOut, .signIn: "Xbox sign-in needed"
        case .refused(.deviceLimit): "Xbox licence refused for this device"
        case .refused: "Xbox licence refused"
        case .unavailable(.connectionNeeded): "Connection needed"
        case .unavailable, .noKey: "Xbox licence not available"
        }
    }

    public var description: String {
        switch self {
        case .signedOut: "You are not signed in to Xbox. Sign in under Settings › Accounts › Xbox, then play again."
        case .signIn(.signInRequired): "Microsoft couldn't renew your Xbox sign-in. Sign in again under Settings › Accounts › Xbox, then play again."
        case .signIn(.deviceRejected): "Microsoft rejected the Xbox device. Sign in again under Settings › Accounts › Xbox, then play again."
        case .refused(let f): f.description
        case .unavailable(.connectionNeeded(let why)): why.description
        case .unavailable(let p): "The game needs its licence to start. " + p.description
        case .noKey: "Microsoft's licence for this game has no key for the installed version. Install the game again."
        }
    }

    /// The licence a play goes on with, or why it can't.
    public static func check(_ result: XboxLicenceResult) -> Result<XboxLicence, XboxPlayRefusal> {
        switch result {
        case .licensed(let licence): .success(licence)
        case .refused(let failure): .failure(.refused(failure))
        case .unavailable(.session(let e)): .failure(.signIn(e))
        case .unavailable(let problem): .failure(.unavailable(problem))
        }
    }
}
