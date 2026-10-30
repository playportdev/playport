// SPDX-License-Identifier: GPL-3.0-only
// Xodus pull request #219 (cyberps96/xodus feat/msixvc2-support) at
// e8194a89ea372c809015952bcab255e65b2b3089, crates/msixvc2/src/{cbor.rs (labels,
// tags, algorithms; XboxPackage.cbor, Chunks/<id>.cbor and the chunk secrets),
// crypto.rs (SP800-108 HMAC-SHA256 with "MSIXVC2:PackageData:AES_256_CBC", AES
// key unwrap, AES-256-CBC), package.rs (segments: box hash, decrypt with the first
// 16 bytes of the segment's hash as IV, Deflate, hash)}; translated to Swift by the
// Playport authors, 2026-10-30. Modified: a key is unwrapped by the algorithm the
// package declares for it: AES-256-KW as the pull request does, AES-256-CBC with
// the key source's IV and, for a segment, the chunk's rolling IV (one step per
// wrapped key, file by file; the format as LukeFZ/XvdTool.Streaming pull request
// #3 at 99db4dd describes it, used for the facts only); GUIDs are text; every
// segment's plaintext hash is checked, not only the file's; box manifests and
// their seals are read and every segment must be listed in its box's manifest;
// Brotli and unknown algorithms are refused by name.
import Foundation
import ContentKit

/// MSIXVC2's metadata: a ZIP whose `XboxPackage.cbor` names the package's keys,
/// boxes and chunks; each chunk's `Chunks/<id>.cbor` lists its files as segments
/// (variable-size, content-defined) stored in boxes (`Boxes/<name>`); each file's
/// name is in its chunk's secret, itself a segment. A segment is compressed, then
/// encrypted (AES-256-CBC) under a key wrapped by the licence's content key.
enum XboxMSIXVC2 {
    enum Label {
        static let hash: UInt64 = 1, length: UInt64 = 2, compression: UInt64 = 3, compressedLength: UInt64 = 4
        static let encryptionKey: UInt64 = 5, wrappedKey: UInt64 = 6, wrapIV: UInt64 = 7, boxHash: UInt64 = 8
        static let boxIndex: UInt64 = 9, boxOffset: UInt64 = 10, boxLength: UInt64 = 11, secondary: UInt64 = 12
        static let id: UInt64 = 24, name: UInt64 = 25, secretReference: UInt64 = 26, initialIV: UInt64 = 27
        static let files: UInt64 = 28, segments: UInt64 = 29, keyIndex: UInt64 = 34, chunkID: UInt64 = 35
        static let readProtected: UInt64 = 37
        static let fileFormat: UInt64 = 256, majorVersion: UInt64 = 257, minorVersion: UInt64 = 258, algorithm: UInt64 = 259
        static let contentID: UInt64 = 260, version: UInt64 = 261, keys: UInt64 = 262, boxes: UInt64 = 264, chunks: UInt64 = 265
        static let build: UInt64 = 267, revision: UInt64 = 268, buildID: UInt64 = 269, fileName: UInt64 = 277
        static let fulfillmentContentID: UInt64 = 279, derivationAlgorithm: UInt64 = 284, wrapAlgorithm: UInt64 = 285
        static let kdfContext: UInt64 = 286, sourcePurpose: UInt64 = 287, sourceKeyID: UInt64 = 288, target: UInt64 = 289
    }

    enum Tag {
        static let sha512: UInt64 = 18512, sha384: UInt64 = 18513, sha256: UInt64 = 18540
        /// "XVCB", "XVCC", "XVCP", "XVCZ" as big-endian words.
        static let box: UInt64 = 1_482_048_322, chunk: UInt64 = 1_482_048_323, package: UInt64 = 1_482_048_336, seal: UInt64 = 1_482_048_346
    }

    enum Algorithm {
        static let none: UInt64 = 0, deflate: UInt64 = 1, brotli: UInt64 = 2, aes256CBC: UInt64 = 256, aes256KW: UInt64 = 257
        static let sp800108: UInt64 = 1024
    }

    /// Key purposes; files and chunk secrets are under the content key.
    static let contentPurpose: UInt64 = 0

    struct Hash: Equatable, Hashable {
        enum Kind: Equatable, Hashable { case sha256, sha384, sha512 }
        var kind: Kind
        var bytes: [UInt8]

        static func parse(_ v: XboxCBOR, what: String) throws -> Hash {
            guard case let .tag(tag, .bytes(b)) = v else { throw XboxXVD.damaged("its \(what) hash is not a tagged hash") }
            let kind: Kind
            switch tag {
            case Tag.sha256: kind = .sha256
            case Tag.sha384: kind = .sha384
            case Tag.sha512: kind = .sha512
            default: throw ClientError.unsupported("Xbox package uses hash \(tag)")
            }
            guard b.count == kind.size else { throw XboxXVD.damaged("its \(what) hash is \(b.count) bytes") }
            return Hash(kind: kind, bytes: b)
        }

        func matches(_ data: [UInt8]) -> Bool { data.withUnsafeBytes { matches($0) } }
        func matches(_ data: UnsafeRawBufferPointer) -> Bool {
            var s = Stream(kind)
            s.update(data)
            return s.finalize() == bytes
        }

        struct Stream {
            enum State { case sha256(SHA256Stream), sha512(XboxSHA512) }
            var state: State
            init(_ kind: Kind) {
                switch kind {
                case .sha256: state = .sha256(SHA256Stream())
                case .sha384: state = .sha512(.sha384())
                case .sha512: state = .sha512(.sha512())
                }
            }
            mutating func update(_ data: UnsafeRawBufferPointer) {
                switch state {
                case var .sha256(s): s.update(data); state = .sha256(s)
                case var .sha512(s): s.update(data); state = .sha512(s)
                }
            }
            func finalize() -> [UInt8] {
                switch state {
                case let .sha256(s): s.finalize()
                case let .sha512(s): s.finalize()
                }
            }
        }
    }

    /// The package's 16-byte IV counter: big-endian, the low 64 bits carrying into the high.
    struct IV: Equatable {
        var bytes: [UInt8]
        init(_ v: XboxCBOR, what: String) throws {
            guard case let .bytes(b) = v, b.count == 16 else { throw XboxXVD.damaged("its \(what) IV is not 16 bytes") }
            bytes = b
        }
        init(bytes: [UInt8]) { self.bytes = bytes }
        func next() -> IV {
            var b = bytes
            for i in stride(from: 15, through: 0, by: -1) {
                b[i] &+= 1
                if b[i] != 0 { break }
            }
            return IV(bytes: b)
        }
    }

    struct Segment: Equatable {
        var hash: Hash
        var length: Int
        var compression: UInt64
        var compressedLength: Int
        var encryptionKey: [UInt8]?
        var wrappedKey: [UInt8]?
        /// The IV its wrapped key was wrapped with, when the key source wraps with AES-CBC.
        var wrapIV: IV?
        var boxHash: Hash?
        var box: Int
        var boxOffset: UInt64
        var boxLength: Int

        var encrypted: Bool { encryptionKey != nil || wrappedKey != nil }

        /// Segments are at most 64 MiB (a ContentKit chunk's size is 32-bit; FastCDC's are far smaller).
        static let maxLength = 64 << 20

        /// One segment reference. A wrapped key takes the rolling IV, which then steps.
        static func parse(_ v: XboxCBOR, iv: inout IV?, what: String) throws -> Segment {
            let f = try v.fields(what)
            let length = try f.int(Label.length, max: maxLength) ?? 0
            let compression = try f.uint(Label.compression) ?? Algorithm.none
            guard [Algorithm.none, Algorithm.deflate, Algorithm.brotli].contains(compression) else {
                throw ClientError.unsupported("Xbox package uses compression \(compression)")
            }
            let compressedLength = try f.int(Label.compressedLength, max: maxLength) ?? length
            var wrapIV: IV?
            let wrapped = try f.bytes(Label.wrappedKey)
            if wrapped != nil {
                if let explicit = f[Label.wrapIV] { wrapIV = try IV(explicit, what: what) } else {
                    wrapIV = iv
                    iv = iv?.next()
                }
            }
            let s = Segment(hash: try Hash.parse(try f.required(Label.hash), what: what), length: length, compression: compression,
                            compressedLength: compressedLength, encryptionKey: try f.bytes(Label.encryptionKey), wrappedKey: wrapped,
                            wrapIV: wrapIV, boxHash: try f[Label.boxHash].map { try Hash.parse($0, what: what + " box") },
                            box: try f.int(Label.boxIndex) ?? 0, boxOffset: try f.uint(Label.boxOffset) ?? 0,
                            boxLength: try f.int(Label.boxLength, max: maxLength + 16) ?? length)
            guard s.boxLength >= (s.compression == Algorithm.none ? s.length : s.compressedLength) else {
                throw XboxXVD.damaged("its \(what) is longer than its box bytes")
            }
            // No signature over an MSIXVC2's metadata is known, so its bytes are trusted only
            // under a key the licence wraps: one written in the package, or none, would let
            // anyone on the (plain HTTP) path rewrite the segment and its hash.
            guard s.encryptionKey == nil, s.wrappedKey != nil || s.length == 0 else {
                throw ClientError.verificationFailed("Xbox package has a \(what) not encrypted under its licence")
            }
            return s
        }
    }

    struct KeySource: Equatable {
        var keyID: UUID
        var purpose: UInt64
        var derivation: UInt64
        var kdfContext: [UInt8]
        var wrapAlgorithm: UInt64
        var wrapIV: IV?
        var wrappedKey: [UInt8]
        var algorithm: UInt64

        static func parse(_ v: XboxCBOR) throws -> KeySource {
            let f = try v.fields("key source")
            guard let id = try f.guid(Label.sourceKeyID) else { throw f.bad(Label.sourceKeyID, "is missing") }
            return KeySource(keyID: id, purpose: try f.uint(Label.sourcePurpose) ?? contentPurpose,
                             derivation: try f.uint(Label.derivationAlgorithm) ?? Algorithm.none,
                             kdfContext: try f.bytes(Label.kdfContext) ?? [], wrapAlgorithm: try f.uint(Label.wrapAlgorithm) ?? Algorithm.none,
                             wrapIV: try f[Label.wrapIV].map { try IV($0, what: "key source") },
                             wrappedKey: try f.bytes(Label.wrappedKey) ?? [], algorithm: try f.uint(Label.algorithm) ?? Algorithm.none)
        }
    }

    struct Chunk: Equatable {
        var id: Int
        var keyIndex: Int
        var secret: Segment
    }

    struct File: Equatable {
        var length: UInt64
        var hash: Hash
        var segments: [Segment]
    }

    struct Package {
        var contentID: UUID
        var fulfillmentContentID: UUID?
        /// major.minor.build.revision.
        var version: String
        var keys: [[KeySource]]
        var boxes: [String]
        var chunks: [Chunk]

        static func parse(_ bytes: [UInt8]) throws -> Package {
            let root = try XboxCBOR.decode(bytes, what: "package metadata").tagged(Tag.package, what: "package metadata")
            let f = try root.fields("package metadata")
            let format = try f.required(Label.fileFormat).fields("file format")
            guard let major = try format.uint(Label.majorVersion), major == 1 else {
                throw ClientError.unsupported("Xbox package is MSIXVC2 format \(try format.uint(Label.majorVersion).map(String.init) ?? "?")")
            }
            guard let content = try f.guid(Label.contentID) else { throw f.bad(Label.contentID, "is missing") }
            let v = try f.required(Label.version).fields("version")
            let parts = try [Label.majorVersion, Label.minorVersion, Label.build, Label.revision].map { try v.uint($0, max: 65535) ?? 0 }
            var iv = try f[Label.initialIV].map { try IV($0, what: "package") }
            let keys = try (f[Label.keys]?.list("keys") ?? []).map { try $0.list("key").map(KeySource.parse) }
            let boxes = try (f[Label.boxes]?.list("boxes") ?? []).map { b -> String in
                guard let name = try b.fields("box").text(Label.name), !name.isEmpty, name.count <= 255,
                      !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { throw XboxXVD.damaged("a box has no usable name") }
                return name
            }
            var chunks: [Chunk] = [], ids = Set<Int>()
            for c in try f.required(Label.chunks).list("chunks") {
                let cf = try c.fields("chunk")
                let id = try cf.int(Label.id) ?? 0, keyIndex = try cf.int(Label.keyIndex) ?? 0
                guard ids.insert(id).inserted else { throw XboxXVD.damaged("it lists chunk \(id) twice") }
                let secret = try Segment.parse(try cf.required(Label.secretReference), iv: &iv, what: "chunk \(id) secret")
                chunks.append(Chunk(id: id, keyIndex: keyIndex, secret: secret))
            }
            guard !chunks.isEmpty, chunks.count <= 65536, boxes.count <= 1 << 20 else { throw XboxXVD.damaged("it lists \(chunks.count) chunks") }
            return Package(contentID: content, fulfillmentContentID: try f.guid(Label.fulfillmentContentID),
                           version: parts.map(String.init).joined(separator: "."), keys: keys, boxes: boxes, chunks: chunks)
        }
    }

    /// `Chunks/<id>.cbor`: the chunk's files in order (their names are in its secret).
    static func chunkFiles(_ bytes: [UInt8], id: Int) throws -> [File] {
        let what = "chunk \(id)"
        let f = try XboxCBOR.decode(bytes, what: what).tagged(Tag.chunk, what: what).fields(what)
        guard try f.int(Label.id) ?? 0 == id else { throw XboxXVD.damaged("its \(what) names another chunk") }
        var rolling = try f[Label.initialIV].map { try IV($0, what: what) }
        return try (f[Label.files]?.list("\(what) files") ?? []).enumerated().map { n, item in
            let ff = try item.fields("\(what) file \(n)")
            // A file's own IV starts its segments; the chunk's carries on from where the file left it.
            var iv = try ff[Label.initialIV].map { try IV($0, what: what) } ?? rolling
            let segments = try (ff[Label.segments]?.list("segments") ?? []).map { try Segment.parse($0, iv: &iv, what: "\(what) file \(n) segment") }
            if rolling != nil { rolling = iv }
            return File(length: try ff.uint(Label.length) ?? 0, hash: try Hash.parse(try ff.required(Label.hash), what: "\(what) file \(n)"),
                        segments: segments)
        }
    }

    /// The chunk secret: its files' names, in the chunk's file order.
    static func chunkNames(_ bytes: [UInt8], id: Int) throws -> [String] {
        let what = "chunk \(id) secret"
        let f = try XboxCBOR.decode(bytes, what: what).tagged(Tag.chunk, what: what).fields(what)
        return try (f[Label.files]?.list(what) ?? []).map { item in
            let ff = try item.fields(what)
            guard let name = try ff.text(Label.name) ?? ff.text(Label.fileName), !name.isEmpty else { throw XboxXVD.damaged("its \(what) has a file without a name") }
            return name
        }
    }

    /// A box: "XBOXBOX\0", segment bytes, its manifest (the box's segments), the manifest's
    /// seal (its hash), then the manifest's offset (LE64) and length (LE32).
    static let boxMagic = Array("XBOXBOX\0".utf8)

    /// The manifest's segments' hashes and lengths, once its seal checks.
    static func boxManifest(_ manifest: [UInt8], seal: [UInt8], name: String) throws -> Set<Hash.Listed> {
        let what = "box \(name) seal"
        let s = try XboxCBOR.decode(seal, what: what).tagged(Tag.seal, what: what).fields(what)
        guard try s.uint(Label.target) == Tag.box else { throw XboxXVD.damaged("its \(what) does not seal a box manifest") }
        guard try Hash.parse(try s.required(Label.hash), what: what).matches(manifest) else {
            throw XboxXVD.damaged("box \(name)'s manifest doesn't match its seal")
        }
        let m = try XboxCBOR.decode(manifest, what: "box \(name) manifest").tagged(Tag.box, what: "box \(name) manifest").fields("box \(name) manifest")
        guard try m.text(Label.name) == name else { throw XboxXVD.damaged("box \(name)'s manifest names another box") }
        // Only what identifies a segment: its plaintext hash and length.
        return Set(try (m[Label.segments]?.list("box \(name) segments") ?? []).map { item in
            let f = try item.fields("box \(name) segment")
            return Hash.Listed(hash: try Hash.parse(try f.required(Label.hash), what: "box \(name) segment"),
                               length: try f.int(Label.length, max: Segment.maxLength) ?? 0)
        })
    }
}

extension XboxMSIXVC2.Hash {
    /// What a box manifest says of a segment: its plaintext hash and length.
    struct Listed: Hashable { var hash: XboxMSIXVC2.Hash; var length: Int }
}

extension XboxMSIXVC2.Hash.Kind {
    var size: Int { switch self { case .sha256: 32; case .sha384: 48; case .sha512: 64 } }
}

/// The package's content keys, unwrapped from the licence's: per key index, the key
/// that unwraps (or is) each segment's key.
struct XboxMSIXVC2Keys: Sendable {
    let byIndex: [Int: [UInt8]]

    static let kdfLabel = Array("MSIXVC2:PackageData:AES_256_CBC".utf8)

    /// `licence`: the licence's keys by ID. A package whose content key ID the licence
    /// lacks takes the licence's only key, as Xodus's pull request does (a wrong key
    /// fails every segment's hash).
    init(package: XboxMSIXVC2.Package, licence: [UUID: [UInt8]], log: Logger = .silent) throws {
        var out: [Int: [UInt8]] = [:]
        for index in Set(package.chunks.map(\.keyIndex)) where !package.keys.isEmpty {
            guard index < package.keys.count,
                  let source = package.keys[index].first(where: { $0.purpose == XboxMSIXVC2.contentPurpose }) else {
                throw XboxXVD.damaged("a chunk names content key \(index) the package doesn't list")
            }
            var master = licence[source.keyID]
            if master == nil, licence.count == 1 {
                log.warn("xbox", "the licence's key ID is not the package's; using the licence's only key")
                master = licence.values.first
            }
            guard let master else { throw ClientError.verificationFailed("Xbox licence has no key for this package") }
            guard source.derivation == XboxMSIXVC2.Algorithm.sp800108 else {
                throw ClientError.unsupported("Xbox package derives keys with algorithm \(source.derivation)")
            }
            // The KDF label exists for AES-256-CBC only (both references).
            guard source.wrapAlgorithm == XboxMSIXVC2.Algorithm.aes256CBC else {
                throw ClientError.unsupported("Xbox package derives a key for algorithm \(source.wrapAlgorithm)")
            }
            guard [XboxMSIXVC2.Algorithm.aes256CBC, 1].contains(source.algorithm) else {
                throw ClientError.unsupported("Xbox package encrypts with algorithm \(source.algorithm)")
            }
            out[index] = try Self.unwrap(source.wrappedKey, with: Self.derive(master, context: source.kdfContext), iv: source.wrapIV)
        }
        byIndex = out
    }

    /// NIST SP800-108 counter mode, HMAC-SHA256, one 256-bit block:
    /// [1]₃₂ ‖ label ‖ 0x00 ‖ context ‖ [256]₃₂.
    static func derive(_ master: [UInt8], context: [UInt8]) -> [UInt8] {
        XboxCrypto.hmac(master, [0, 0, 0, 1] + kdfLabel + [0] + context + [0, 0, 1, 0])
    }

    /// A wrapped 256-bit key. With an IV (the key source's, or the chunk's rolling IV
    /// for a segment's key) it is AES-256-CBC without padding, as the declared wrap
    /// algorithm says; without one, AES key wrap (RFC 3394, then RFC 5649), as Xodus's
    /// pull request unwraps every key.
    static func unwrap(_ wrapped: [UInt8], with key: [UInt8], iv: XboxMSIXVC2.IV?) throws -> [UInt8] {
        let aes = try AES256Decryptor(key: key)
        let out: [UInt8]
        if let iv {
            var b = wrapped
            guard !b.isEmpty, b.count % 16 == 0 else { throw XboxXVD.damaged("a wrapped key is \(b.count) bytes") }
            try aes.decryptCBCInPlace(&b, iv: iv.bytes)
            out = b
        } else {
            guard let k = keyUnwrap(wrapped, aes) else { throw ClientError.verificationFailed("Xbox package key doesn't unwrap (wrong licence key?)") }
            out = k
        }
        guard out.count == 32 else { throw XboxXVD.damaged("an unwrapped key is \(out.count) bytes") }
        return out
    }

    /// RFC 3394 §2.2.2 with its default IV, else RFC 5649's alternative IV and padding.
    static func keyUnwrap(_ c: [UInt8], _ aes: AES256Decryptor) -> [UInt8]? {
        guard c.count >= 16, c.count % 8 == 0 else { return nil }
        let n = c.count / 8 - 1
        var a = Array(c[0..<8]), r = (0..<n).map { Array(c[(8 + 8 * $0)..<(16 + 8 * $0)]) }
        if n == 1 {
            var b = c
            aes.decryptBlock(&b)
            a = Array(b[0..<8]); r = [Array(b[8..<16])]
        } else {
            for j in stride(from: 5, through: 0, by: -1) {
                for i in stride(from: n, through: 1, by: -1) {
                    let t = UInt64(n * j + i)
                    for k in 0..<8 { a[k] ^= UInt8(truncatingIfNeeded: t >> UInt64(56 - 8 * k)) }
                    var b = a + r[i - 1]
                    aes.decryptBlock(&b)
                    a = Array(b[0..<8]); r[i - 1] = Array(b[8..<16])
                }
            }
        }
        let plain = r.flatMap { $0 }
        if a == [0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6] { return plain }
        guard a[0..<4].elementsEqual([0xA6, 0x59, 0x59, 0xA6]) else { return nil }
        let mli = Int(a.readBE32(at: 4))
        guard mli <= plain.count, mli > plain.count - 8, plain[mli...].allSatisfy({ $0 == 0 }) else { return nil }
        return Array(plain[0..<mli])
    }

    /// A segment's box bytes to its plaintext: decrypted (its key unwrapped first) with
    /// the first 16 bytes of its hash as IV, decompressed, cut to its length; nil when
    /// that doesn't give the bytes its hash names (a damaged segment, or the wrong key).
    func open(_ s: XboxMSIXVC2.Segment, keyIndex: Int, _ box: [UInt8]) throws -> [UInt8]? {
        var bytes = box
        if s.encrypted {
            let key: [UInt8]
            if let direct = s.encryptionKey { key = direct } else {
                guard let u = byIndex[keyIndex] else { throw XboxXVD.damaged("an encrypted segment is in a package without keys") }
                key = try Self.unwrap(s.wrappedKey!, with: u, iv: s.wrapIV)
            }
            guard key.count == 32 else { throw XboxXVD.damaged("a segment key is \(key.count) bytes") }
            guard bytes.count % 16 == 0 else { return nil }
            try AES256Decryptor(key: key).decryptCBCInPlace(&bytes, iv: Array(s.hash.bytes[0..<16]))
        }
        switch s.compression {
        case XboxMSIXVC2.Algorithm.deflate:
            guard let plain = try? Inflate.decompress(bytes[0..<s.compressedLength], limit: s.length), plain.count == s.length else { return nil }
            bytes = plain
        case XboxMSIXVC2.Algorithm.brotli:
            throw ClientError.unsupported("Xbox package uses Brotli compression, which Playport can't read yet")
        default:
            bytes.removeLast(bytes.count - s.length)
        }
        return s.hash.matches(bytes) ? bytes : nil
    }
}

extension Array where Element == UInt8 {
    fileprivate func readBE32(at o: Int) -> UInt32 {
        UInt32(self[o]) << 24 | UInt32(self[o + 1]) << 16 | UInt32(self[o + 2]) << 8 | UInt32(self[o + 3])
    }
}
