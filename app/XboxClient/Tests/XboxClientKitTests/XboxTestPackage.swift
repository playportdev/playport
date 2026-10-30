// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit
@testable import XboxClientKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A tiny MSIXVC with the pilot's real layout (PLA-487): XVD header, hash tree, user
/// data with MicrosoftGame.config and SegmentMetadata.bin, XVC information with an
/// unencrypted FS-MD region, an unencrypted data region and an encrypted region (key
/// index 0, XTS under a test key), and a GPT drive holding NTFS with 4 KiB clusters and
/// 4 KiB MFT records. Nothing here is a real key or package.
struct XboxTestPackage {
    struct File {
        var path: String
        var data: [UInt8]
        var encrypted = true
        var keep = false
    }

    static let key: [UInt8] = (0..<32).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 11) }
    static let keyID = UUID(uuidString: "6B1C8E2A-90F4-4D17-A3B5-0C9E7D21F4A8")!
    static let contentID = UUID(uuidString: "5E7A3C19-2B84-4F60-9D1E-A8C47B03E6F2")!
    static let region: UInt32 = 0x3E8
    static let scid = "00000000-0000-0000-0000-00001234abcd"
    static let page = 4096

    var bytes: [UInt8]
    var files: [File]
    /// Where each file's first byte is in the package.
    var offsets: [String: Int]
    var prefixBytes: Int
    var units: [String: [UInt32]]

    static func config(exe: String = "Game.exe", version: String = "1.2.3.0") -> [UInt8] {
        Array(("\u{FEFF}<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<Game configVersion=\"1\">\n"
            + "  <Identity Name=\"Playport.TestGame\" Publisher=\"CN=Playport\" Version=\"\(version)\" />\n"
            + "  <ExecutableList>\n    <Executable Name=\"\(exe)\" Id=\"Game\" TargetDeviceFamily=\"PC\" />\n  </ExecutableList>\n"
            + "  <StoreId>9TESTGAME001</StoreId>\n  <MSAAppId>0000000040ABCDEF</MSAAppId>\n  <TitleId>1234ABCD</TitleId>\n"
            + "  <ExtendedAttributeList>\n    <ExtendedAttribute Name=\"Scid\" Value=\"\(scid)\" />\n  </ExtendedAttributeList>\n</Game>\n").utf8)
    }

    /// Bytes that differ per file and offset, so a misplaced page is caught.
    static func content(_ seed: Int, _ count: Int) -> [UInt8] {
        var x = UInt32(truncatingIfNeeded: seed &* 2654435761 &+ 12345)
        return (0..<count).map { _ in x = x &* 1103515245 &+ 12345; return UInt8(truncatingIfNeeded: x >> 16) }
    }

    /// The standard fixture: nested folders, an empty file, a plain-region image, a
    /// kept-encrypted .exe, a decrypted .dll and a file larger than one 1 MiB chunk.
    static func standard(segmentMetadata: Bool = true) -> XboxTestPackage {
        build([
            File(path: "Game.exe", data: content(1, 3 * page + 77), keep: true),
            File(path: "Game_Data/level0", data: content(2, 1_300_000)),
            File(path: "Game_Data/Managed/Assembly.dll", data: content(3, 9000)),
            File(path: "Game_Data/empty.txt", data: []),
            File(path: "Tools/Crash.exe", data: content(4, 5000), keep: true),
            File(path: "Logo.png", data: content(5, 6000), encrypted: false),
            File(path: "MicrosoftGame.Config", data: config(), encrypted: false),
        ], segmentMetadata: segmentMetadata)
    }

    /// `version`: major, minor, build, revision (the header's, the package name's and MicrosoftGame.config's).
    static func build(_ files: [File], segmentMetadata: Bool = true, version: [UInt16] = [1, 2, 3, 0]) -> XboxTestPackage {
        let versionText = version.map(String.init).joined(separator: ".")
        let page = Self.page
        func pages(_ n: Int) -> Int { (n + page - 1) / page }

        // The drive: MBR, GPT header, GPT entries, a spare LBA, then the NTFS volume.
        // Volume clusters: boot sector, the MFT, plain files' data, then encrypted files' data.
        var dirs: [String] = []
        for f in files {
            var parts = f.path.split(separator: "/").dropLast().map(String.init)
            while !parts.isEmpty { let d = parts.joined(separator: "/"); if !dirs.contains(d) { dirs.append(d) }; parts.removeLast() }
        }
        dirs.sort()
        let mftRecords = 16 + dirs.count + files.count
        var lcn = 1 + mftRecords
        var clusterOf: [String: Int] = [:]
        for f in files where !f.encrypted && !f.data.isEmpty { clusterOf[f.path] = lcn; lcn += pages(f.data.count) }
        let encryptedFirstCluster = lcn
        for f in files where f.encrypted && !f.data.isEmpty { clusterOf[f.path] = lcn; lcn += pages(f.data.count) }
        let volumeClusters = lcn
        let drivePages = 4 + volumeClusters
        var drive = [UInt8](repeating: 0, count: drivePages * page)
        func put(_ bytes: [UInt8], at: Int) { drive.replaceSubrange(at..<(at + bytes.count), with: bytes) }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { var b = [UInt8](); b.appendLE(v); return b }
        func le64(_ v: UInt64) -> [UInt8] { var b = [UInt8](); b.appendLE(v); return b }

        var gpt = Array("EFI PART".utf8) + [0, 0, 1, 0] + le32(92)
        gpt += [UInt8](repeating: 0, count: 72 - gpt.count)
        gpt += le64(2) + le32(1) + le32(128)
        put(gpt, at: page)
        put(Array(repeating: 0xA2, count: 16) + Array(repeating: 0x5C, count: 16) + le64(4) + le64(UInt64(4 + volumeClusters - 1)), at: 2 * page)

        let volume = 4 * page
        var boot = [UInt8](repeating: 0, count: 512)
        boot.replaceSubrange(3..<11, with: Array("NTFS    ".utf8))
        boot.replaceSubrange(11..<13, with: le16(4096)); boot[13] = 1
        boot.replaceSubrange(0x28..<0x30, with: le64(UInt64(volumeClusters)))
        boot.replaceSubrange(0x30..<0x38, with: le64(1))
        boot[0x40] = UInt8(bitPattern: -12)
        put(boot, at: volume)

        func fileName(_ parent: Int, _ name: String) -> [UInt8] {
            let units = Array(name.utf16)
            var v = le64(UInt64(parent) | 1 << 48) + [UInt8](repeating: 0, count: 0x38) + [UInt8(units.count), 1]
            for u in units { v += le16(Int(u)) }
            var a = le32(0x30) + le32(0) + [0, 0] + le16(0x18) + [0, 0, 0, 0] + le32(UInt32(v.count)) + le16(0x18) + [0, 0] + v
            while a.count % 8 != 0 { a.append(0) }
            a.replaceSubrange(4..<8, with: le32(UInt32(a.count)))
            return a
        }
        func data(_ size: Int, cluster: Int?) -> [UInt8] {
            guard let cluster, size > 0 else {
                return le32(0x80) + le32(24) + [0, 0] + le16(0x18) + [0, 0, 0, 0] + le32(0) + le16(0x18) + [0, 0]
            }
            let count = pages(size)
            var runs: [UInt8] = [0x44] + le32(UInt32(count)) + le32(UInt32(cluster)) + [0]
            while runs.count % 8 != 0 { runs.append(0) }
            var a = le32(0x80) + le32(0) + [1, 0] + le16(0x40) + [0, 0, 0, 0] + le64(0) + le64(UInt64(count - 1))
            a += le16(0x40) + [0, 0, 0, 0, 0, 0] + le64(UInt64(count * page)) + le64(UInt64(size)) + le64(UInt64(size)) + runs
            a.replaceSubrange(4..<8, with: le32(UInt32(a.count)))
            return a
        }
        func record(_ n: Int, directory: Bool, _ attributes: [[UInt8]]) {
            var r = [UInt8](repeating: 0, count: page)
            r.replaceSubrange(0..<4, with: Array("FILE".utf8))
            r.replaceSubrange(4..<6, with: le16(0x30)); r.replaceSubrange(6..<8, with: le16(9))
            r.replaceSubrange(0x10..<0x12, with: le16(1)); r.replaceSubrange(0x12..<0x14, with: le16(1))
            r.replaceSubrange(0x14..<0x16, with: le16(0x48)); r.replaceSubrange(0x16..<0x18, with: le16(directory ? 3 : 1))
            var o = 0x48
            for a in attributes { r.replaceSubrange(o..<(o + a.count), with: a); o += a.count }
            r.replaceSubrange(o..<(o + 4), with: [0xFF, 0xFF, 0xFF, 0xFF])
            r.replaceSubrange(0x18..<0x1C, with: le32(UInt32(o + 8))); r.replaceSubrange(0x1C..<0x20, with: le32(UInt32(page)))
            r.replaceSubrange(0x2C..<0x30, with: le32(UInt32(n)))
            // Update sequence: the last two bytes of every 512 move into the array.
            r[0x30] = 1; r[0x31] = 0
            for i in 1..<9 { r[0x30 + 2 * i] = r[i * 512 - 2]; r[0x31 + 2 * i] = r[i * 512 - 1]; r[i * 512 - 2] = 1; r[i * 512 - 1] = 0 }
            put(r, at: volume + (1 + n) * page)
        }
        record(0, directory: false, [fileName(5, "$MFT"), data(mftRecords * page, cluster: 1)])
        record(5, directory: true, [fileName(5, ".")])
        var recordOf: [String: Int] = ["": 5]
        for (i, d) in dirs.enumerated() {
            recordOf[d] = 16 + i
            let parent = d.split(separator: "/").dropLast().joined(separator: "/")
            record(16 + i, directory: true, [fileName(recordOf[parent]!, String(d.split(separator: "/").last!))])
        }
        for (i, f) in files.enumerated() {
            let parent = f.path.split(separator: "/").dropLast().joined(separator: "/")
            record(16 + dirs.count + i, directory: false, [fileName(recordOf[parent]!, String(f.path.split(separator: "/").last!)),
                                                           data(f.data.count, cluster: clusterOf[f.path])])
            if let c = clusterOf[f.path] { put(f.data, at: volume + c * page) }
        }

        // User data: MicrosoftGame.config and (optionally) SegmentMetadata.bin.
        var packaged: [(String, [UInt8])] = [("MicrosoftGame.config", config(version: versionText))]
        if segmentMetadata {
            let ordered = files.filter { !$0.encrypted } + files.filter(\.encrypted)
            var paths = [UInt8](), segs = [UInt8]()
            for f in ordered {
                let name = Array(f.path.replacingOccurrences(of: "/", with: "\\").utf16)
                segs += le16(f.keep ? 1 : 0) + le16(name.count) + le32(UInt32(paths.count)) + le64(UInt64(f.data.count))
                for u in name { paths += le16(Int(u)) }
            }
            var head = Array(" PFX".utf8) + le32(4) + le32(2) + le32(100) + le32(UInt32(ordered.count)) + le32(UInt32(paths.count))
            head += [UInt8](repeating: 0x33, count: 16)
            head += [UInt8](repeating: 0, count: 100 - head.count)
            packaged.append(("SegmentMetadata.bin", head + segs + paths))
        }
        func utf16Field(_ s: String, _ chars: Int) -> [UInt8] {
            var b = [UInt8](); for u in s.utf16.prefix(chars - 1) { b += le16(Int(u)) }
            return b + [UInt8](repeating: 0, count: 2 * chars - b.count)
        }
        var user = le32(16) + le32(1) + le32(0) + le32(0)
        user += le32(1) + utf16Field("Playport.TestGame_\(versionText)_x64__test", 260) + le32(UInt32(packaged.count))
        var blob = [UInt8](), entries = [UInt8]()
        let dataStart = 528 + packaged.count * 528
        for (name, bytes) in packaged {
            entries += utf16Field(name, 260) + le32(UInt32(bytes.count)) + le32(UInt32(dataStart + blob.count))
            blob += bytes
        }
        user += entries + blob

        // Package pages: header 3, mutable 1, hash tree, user data, XVC information, drive.
        let regionCount = 3
        let xvcLength = 3496 + regionCount * 128
        let hashed = pages(user.count) + pages(xvcLength) + drivePages
        let tree = XboxHashTreeLayout(hashedPages: UInt64(hashed))
        let treeStart = 4, userStart = treeStart + Int(tree.pages)
        let xvcStart = userStart + pages(user.count), driveStart = xvcStart + pages(xvcLength)
        let total = driveStart + drivePages
        let encryptedStart = driveStart + 4 + encryptedFirstCluster
        let plainDataStart = driveStart + 4 + 1 + mftRecords

        var xvc = [UInt8](repeating: 0, count: xvcLength)
        func xput(_ b: [UInt8], _ at: Int) { xvc.replaceSubrange(at..<(at + b.count), with: b) }
        xput(XboxXTS.guidBytes(UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!), 0)
        xput(XboxXTS.guidBytes(keyID), 16)
        xput(le32(2) + le32(UInt32(regionCount)) + le32(7), 16 + 16 * 0xC0 + 0x100)
        for (n, r) in [(UInt32(0x4000_0002), 0xFFFF, driveStart, plainDataStart, 0),
                       (UInt32(0x4000_0003), 0xFFFF, plainDataStart, encryptedStart, 0),
                       (region, 0, encryptedStart, total, files.filter { !$0.encrypted }.count)].enumerated() {
            let o = 3496 + n * 128
            xput(le32(r.0) + le16(r.1) + [0, 0] + le32(r.1 == 0 ? 4 : 1) + le32(UInt32(r.4)), o)
            xput(le64(UInt64(r.2 * page)) + le64(UInt64((r.3 - r.2) * page)), o + 80)
        }

        var bytes = [UInt8](repeating: 0, count: total * page)
        bytes.replaceSubrange((userStart * page)..<(userStart * page + user.count), with: user)
        bytes.replaceSubrange((xvcStart * page)..<(xvcStart * page + xvc.count), with: xvc)
        bytes.replaceSubrange((driveStart * page)..<(driveStart * page + drive.count), with: drive)

        // Encrypt the encrypted region page by page, each with its own data unit.
        let xts = try! XboxXTS(key: key, region: region, vduid: contentID)
        var unitOf: [Int: UInt32] = [:]
        for p in encryptedStart..<total {
            let unit = UInt32(0x2E19_0000 + (p * 7919) % 100_000)
            unitOf[p] = unit
            var one = Array(bytes[(p * page)..<((p + 1) * page)])
            xts.encrypt(&one, units: [unit][...])
            bytes.replaceSubrange((p * page)..<((p + 1) * page), with: one)
        }

        // The hash tree from level 0 (every page from the user data on) up to the header.
        var level0 = [UInt8]()
        for i in 0..<hashed {
            let p = userStart + i
            let h = bytes.withUnsafeBytes { XboxXVD.pageHash(UnsafeRawBufferPointer(rebasing: $0[(p * page)..<((p + 1) * page)])) }
            let entry = unitOf[p].map { Array(h[0..<20]) + le32($0) } ?? h
            level0 += entry
            if (i + 1) % 170 == 0 { level0 += [UInt8](repeating: 0, count: 16) }
        }
        var levels = [level0]
        while levels.last!.count > page || levels.count < 1 {
            let below = levels.last!
            var up = [UInt8]()
            let count = (below.count + page - 1) / page
            for p in 0..<count {
                var pg = Array(below[(p * page)..<min((p + 1) * page, below.count)])
                pg += [UInt8](repeating: 0, count: page - pg.count)
                up += pg.withUnsafeBytes { XboxXVD.pageHash($0) }
                if (p + 1) % 170 == 0 { up += [UInt8](repeating: 0, count: 16) }
            }
            levels.append(up)
        }
        for (k, level) in levels.enumerated() {
            let at = (treeStart + Int(tree.start[k])) * page
            bytes.replaceSubrange(at..<(at + level.count), with: level)
        }
        let topAt = (treeStart + Int(tree.start[tree.top])) * page
        let top = SHA256Stream.hash(Array(bytes[topAt..<(topAt + page)]))

        var header = [UInt8](repeating: 0, count: 3 * page)
        func hput(_ b: [UInt8], _ at: Int) { header.replaceSubrange(at..<(at + b.count), with: b) }
        hput(Array("msft-xvd".utf8), 0x200)
        hput(le32(0x41) + le32(3), 0x208)
        hput(le64(UInt64(drivePages * page)), 0x218)
        hput(XboxXTS.guidBytes(contentID), 0x220)
        hput(top, 0x240)
        hput(le32(0) + le32(1) + le32(0) + le32(UInt32(user.count)) + le32(UInt32(xvcLength)) + le32(0) + le32(0xAA000), 0x280)
        hput(le16(Int(version[3])) + le16(Int(version[2])) + le16(Int(version[1])) + le16(Int(version[0])), 0x3BC)
        header[0x470] = 1
        bytes.replaceSubrange(0..<(3 * page), with: header)

        var offsets: [String: Int] = [:], units: [String: [UInt32]] = [:]
        for f in files {
            guard let c = clusterOf[f.path] else { continue }
            let first = driveStart + 4 + c
            offsets[f.path] = first * page
            if f.encrypted { units[f.path] = (0..<pages(f.data.count)).map { unitOf[first + $0]! } }
        }
        return XboxTestPackage(bytes: bytes, files: files, offsets: offsets, prefixBytes: encryptedStart * page, units: units)
    }
}

/// An HTTP/1.1 range server for one package on 127.0.0.1, one thread per connection.
final class XboxTestCDN: @unchecked Sendable {
    let lock = NSLock()
    var body: [UInt8]
    /// A byte to flip in every response that covers it.
    var flip: Int?
    /// Responses still to cut off half-way (a dropped connection).
    var dropNext = 0
    private(set) var ranges: [ClosedRange<Int>] = []
    private(set) var served = 0
    let fd: Int32
    let port: UInt16
    var url: URL { URL(string: "http://127.0.0.1:\(port)/12/test/package.msixvc")! }

    init(_ body: [UInt8]) throws {
        self.body = body
        #if canImport(Glibc)
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(s, 64) == 0 else { _ = close(s); throw ClientError.transport("test CDN bind") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        fd = s
        port = UInt16(bigEndian: addr.sin_port)
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    func stop() { _ = shutdown(fd, Int32(SHUT_RDWR)); _ = close(fd) }
    var bytesServed: Int { lock.withLock { served } }
    var requestCount: Int { lock.withLock { ranges.count } }
    func reset() { lock.withLock { ranges = []; served = 0 } }

    private func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            Thread { [self] in serve(c) }.start()
        }
    }

    private func write(_ c: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            #if canImport(Glibc)
            let n = bytes.withUnsafeBytes { send(c, $0.baseAddress! + sent, bytes.count - sent, Int32(MSG_NOSIGNAL)) }
            #else
            let n = bytes.withUnsafeBytes { send(c, $0.baseAddress! + sent, bytes.count - sent, 0) }
            #endif
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    private func serve(_ c: Int32) {
        defer { _ = close(c) }
        var buffer = [UInt8](), chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            while XboxRangeClient.find(buffer, [13, 10, 13, 10]) == nil {
                let n = chunk.withUnsafeMutableBytes { recv(c, $0.baseAddress, $0.count, 0) }
                if n <= 0 { return }
                buffer += chunk[0..<n]
            }
            let end = XboxRangeClient.find(buffer, [13, 10, 13, 10])!
            let head = String(decoding: buffer[0..<end], as: UTF8.self)
            buffer.removeFirst(end + 4)
            guard let line = head.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("range: bytes=") }) else {
                _ = write(c, Array("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n".utf8)); return
            }
            let spec = line.dropFirst("range: bytes=".count).split(separator: "-")
            let (from, to) = (Int(spec[0])!, Int(spec[1])!)
            let taken = lock.withLock { () -> ([UInt8], Int?, Bool, Int) in
                let drop = dropNext > 0
                if drop { dropNext -= 1 }
                ranges.append(from...to)
                let slice = from < body.count ? Array(body[from...min(to, body.count - 1)]) : []
                served += slice.count
                return (slice, flip, drop, body.count)
            }
            var payload = taken.0
            let (flipAt, drop, size) = (taken.1, taken.2, taken.3)
            if let f = flipAt, f >= from, f <= to, f - from < payload.count { payload[f - from] ^= 0x40 }
            guard to < size else {
                _ = write(c, Array("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\n\r\n".utf8)); continue
            }
            let header = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(from)-\(to)/\(size)\r\nContent-Length: \(payload.count)\r\n\r\n"
            if drop { _ = write(c, Array(header.utf8) + Array(payload.prefix(payload.count / 2))); return }
            guard write(c, Array(header.utf8) + payload) else { return }
        }
    }
}

/// An install's calls to Microsoft, answered by the test.
actor XboxTestServices: XboxInstallServices {
    var location: XboxPackageLocation
    var licenceResult: XboxLicenceResult
    var locationError: Error?
    var licences = 0
    init(_ cdn: XboxTestCDN, size: Int) {
        location = XboxPackageLocation(contentID: XboxTestPackage.contentID.uuidString.lowercased(), version: "1.2.3.0",
                                       fileName: "Playport.TestGame_1.2.3.0_x64__test.msixvc", size: UInt64(size), urls: [cdn.url])
        licenceResult = .licensed(XboxLicence(contentID: XboxTestPackage.contentID.uuidString.lowercased(),
                                              keys: [XboxContentKey(id: XboxTestPackage.keyID, key: Secret(XboxTestPackage.key))],
                                              expiresAt: .distantFuture, offlineLease: nil, source: .microsoft))
    }
    func refuse(_ failure: XboxLicenseFailure) { licenceResult = .refused(failure) }
    func fail(_ error: Error) { locationError = error }
    func packageLocation(contentID: String) async throws -> XboxPackageLocation {
        if let locationError { throw locationError }
        return location
    }
    func licence(contentID: String, market: String) async throws -> XboxLicenceResult { licences += 1; return licenceResult }
}
