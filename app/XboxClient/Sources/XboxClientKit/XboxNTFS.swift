// SPDX-License-Identifier: GPL-3.0-only
// Xodus 53ea781dcd073e31d7ea68e894134e9c959bff04 crates/msixvc/src/{xvd.rs
// (parse_ntfs_segment_metadata), streaming_ntfs.rs}; translated to Swift by the
// Playport authors, 2026-10-30. Modified: no gpt/ntfs crates: the GPT's first used
// partition and a linear walk of the $MFT, paths rebuilt from $FILE_NAME parents;
// a file Xodus would skip (resident data, fragments, sparse runs, attribute lists)
// is refused by name rather than left out of the install.
import Foundation
import ContentKit

/// A file of the XVD's NTFS drive: its bytes are `size` from `offset` in the package.
struct XboxNTFSFile: Equatable {
    var path: String
    var size: UInt64
    /// Absolute byte offset in the package; nil for an empty file with no clusters.
    var offset: UInt64?
}

enum XboxNTFS {
    /// `read` returns verified package bytes at an absolute offset.
    static func files(read: (UInt64, Int) throws -> [UInt8], drive: UInt64, driveSize: UInt64, sector: Int) throws -> [XboxNTFSFile] {
        // The GPT header is at LBA 1 of the drive; its first used entry is the volume.
        let gpt = try read(drive + UInt64(sector), 92)
        guard Array(gpt[0..<8]) == Array("EFI PART".utf8) else { throw XboxXVD.damaged("its drive has no GPT") }
        let entriesLBA = gpt.readLE64(at: 72), entryCount = Int(gpt.readLE32(at: 80)), entrySize = Int(gpt.readLE32(at: 84))
        guard entryCount <= 256, entrySize >= 128, entrySize <= 1024, entriesLBA < driveSize / UInt64(sector) else {
            throw XboxXVD.damaged("its GPT lists \(entryCount) partitions")
        }
        let table = try read(drive + entriesLBA * UInt64(sector), entryCount * entrySize)
        var volume: (UInt64, UInt64)?
        for n in 0..<entryCount where table[(n * entrySize)..<(n * entrySize + 16)].contains(where: { $0 != 0 }) {
            let first = table.readLE64(at: n * entrySize + 32), last = table.readLE64(at: n * entrySize + 40)
            guard first <= last, last < driveSize / UInt64(sector) else { throw XboxXVD.damaged("its partition is out of range") }
            volume = (drive + first * UInt64(sector), (last - first + 1) * UInt64(sector))
            break
        }
        guard let (start, length) = volume else { throw XboxXVD.damaged("its drive has no partition") }
        return try volumeFiles(read: read, start: start, length: length)
    }

    static func volumeFiles(read: (UInt64, Int) throws -> [UInt8], start: UInt64, length: UInt64) throws -> [XboxNTFSFile] {
        let boot = try read(start, 512)
        guard Array(boot[3..<11]) == Array("NTFS    ".utf8) else { throw XboxXVD.damaged("its volume is not NTFS") }
        let bytesPerSector = Int(boot.readLE16(at: 11)), perCluster = Int(boot[13])
        guard [512, 1024, 2048, 4096].contains(bytesPerSector), perCluster > 0, perCluster <= 128, perCluster & (perCluster - 1) == 0 else {
            throw XboxXVD.damaged("its NTFS geometry is \(bytesPerSector)×\(perCluster)")
        }
        let cluster = UInt64(bytesPerSector * perCluster)
        let raw = Int8(bitPattern: boot[0x40])
        let recordSize = raw > 0 ? Int(cluster) * Int(raw) : 1 << Int(-raw)
        guard recordSize >= 1024, recordSize <= 65536, recordSize % 512 == 0 else { throw XboxXVD.damaged("its MFT records are \(recordSize) bytes") }
        let mftLCN = boot.readLE64(at: 0x30)
        guard mftLCN < length / cluster else { throw XboxXVD.damaged("its MFT is outside the volume") }

        func clusters(_ lcn: UInt64, _ count: UInt64) throws -> (UInt64, UInt64) {
            guard lcn <= length / cluster, count <= length / cluster - lcn else { throw XboxXVD.damaged("a data run is outside the volume") }
            return (start + lcn * cluster, count * cluster)
        }
        // Record 0 is $MFT: its unnamed $DATA's runs are where every record lives.
        let first = try record(read(start + mftLCN * cluster, recordSize), size: recordSize)
        guard let mft = try attributes(first).first(where: { $0.type == 0x80 && $0.name.isEmpty }), let runs = mft.runs else {
            throw XboxXVD.damaged("its MFT has no data")
        }
        var extents: [(UInt64, UInt64)] = []
        for run in runs {
            guard let lcn = run.lcn else { throw XboxXVD.damaged("its MFT is sparse") }
            extents.append(try clusters(lcn, run.count))
        }
        let total = min(mft.size, extents.reduce(0) { $0 + $1.1 })
        let count = Int(total / UInt64(recordSize))
        guard count <= 1 << 22 else { throw XboxXVD.damaged("its MFT has \(count) records") }

        struct Entry { var parent: UInt64; var name: String; var directory: Bool; var data: Attribute?; var listed: Bool }
        var entries: [UInt64: Entry] = [:]
        var number: UInt64 = 0
        for (offset, bytes) in extents {
            var at: UInt64 = 0
            while at < bytes, number < UInt64(count) {
                let span = Int(min(bytes - at, 1 << 20)) / recordSize * recordSize
                guard span > 0 else { break }
                let block = try read(offset + at, span)
                at += UInt64(span)
                for k in stride(from: 0, to: span, by: recordSize) where number < UInt64(count) {
                    defer { number += 1 }
                    let slice = Array(block[k..<(k + recordSize)])
                    guard slice[0..<4].elementsEqual("FILE".utf8) else { continue }
                    let rec = try record(slice, size: recordSize)
                    let flags = rec.readLE16(at: 0x16)
                    guard flags & 1 != 0, rec.readLE64(at: 0x20) == 0 else { continue }  // in use, a base record
                    var names: [(UInt64, String, UInt8)] = [], data: Attribute?, listed = false
                    for a in try attributes(rec) {
                        switch a.type {
                        case 0x20: listed = true
                        case 0x30:
                            guard let v = a.value, v.count >= 0x42 else { throw XboxXVD.damaged("record \(number) has a bad file name") }
                            let chars = Int(v[0x40])
                            guard 0x42 + 2 * chars <= v.count else { throw XboxXVD.damaged("record \(number) has a bad file name") }
                            let name = String(decoding: (0..<chars).map { v.readLE16(at: 0x42 + 2 * $0) }, as: UTF16.self)
                            names.append((v.readLE64(at: 0) & 0xFFFF_FFFF_FFFF, name, v[0x41]))
                        case 0x80 where a.name.isEmpty: data = a
                        default: break
                        }
                    }
                    // Prefer the Win32/POSIX name over the DOS 8.3 alias.
                    guard let name = names.first(where: { $0.2 != 2 }) ?? names.first else { continue }
                    entries[number] = Entry(parent: name.0, name: name.1, directory: flags & 2 != 0, data: data, listed: listed)
                }
            }
        }

        func path(_ n: UInt64) throws -> String? {
            var parts: [String] = [], current = n
            for _ in 0..<64 {
                if current == 5 { return parts.reversed().joined(separator: "/") }
                guard let e = entries[current], current >= 16 || current == n else { return nil }
                parts.append(e.name)
                current = e.parent
            }
            throw XboxXVD.damaged("its directories loop")
        }
        var out: [XboxNTFSFile] = []
        for (n, e) in entries where !e.directory && n >= 16 {
            guard let p = try path(n), !p.hasPrefix("$") else { continue }
            let clean = try SafePath.normalize(p)
            if e.listed { throw ClientError.unsupported("Xbox package file \(clean) is fragmented across MFT records") }
            guard let data = e.data else { out.append(XboxNTFSFile(path: clean, size: 0, offset: nil)); continue }
            guard let runs = data.runs else {
                guard data.size == 0 else { throw ClientError.unsupported("Xbox package file \(clean) keeps its data in the MFT") }
                out.append(XboxNTFSFile(path: clean, size: 0, offset: nil)); continue
            }
            if data.size == 0 && runs.isEmpty { out.append(XboxNTFSFile(path: clean, size: 0, offset: nil)); continue }
            guard runs.count == 1, let lcn = runs[0].lcn else { throw ClientError.unsupported("Xbox package file \(clean) is fragmented") }
            let (offset, bytes) = try clusters(lcn, runs[0].count)
            guard data.size <= bytes else { throw XboxXVD.damaged("\(clean) is larger than its clusters") }
            out.append(XboxNTFSFile(path: clean, size: data.size, offset: offset))
        }
        return out.sorted { $0.path < $1.path }
    }

    struct Attribute {
        var type: UInt32
        var name: String
        var value: [UInt8]?
        var runs: [(lcn: UInt64?, count: UInt64)]?
        /// The data size (resident: the value's length).
        var size: UInt64
    }

    /// A record with its update sequence applied (the last two bytes of every 512).
    static func record(_ raw: [UInt8], size: Int) throws -> [UInt8] {
        guard raw.count == size, raw[0..<4].elementsEqual("FILE".utf8) else { throw XboxXVD.damaged("an MFT record is not a FILE record") }
        var rec = raw
        let usa = Int(rec.readLE16(at: 4)), n = Int(rec.readLE16(at: 6))
        guard n == size / 512 + 1, usa + 2 * n <= size else { throw XboxXVD.damaged("an MFT record has a bad update sequence") }
        for i in 1..<n {
            let end = i * 512 - 2
            guard rec[end] == rec[usa], rec[end + 1] == rec[usa + 1] else { throw XboxXVD.damaged("an MFT record is torn") }
            rec[end] = rec[usa + 2 * i]; rec[end + 1] = rec[usa + 2 * i + 1]
        }
        return rec
    }

    static func attributes(_ rec: [UInt8]) throws -> [Attribute] {
        var out: [Attribute] = []
        var o = Int(rec.readLE16(at: 0x14))
        while true {
            guard o + 8 <= rec.count else { throw XboxXVD.damaged("an MFT record has no end marker") }
            let type = rec.readLE32(at: o)
            if type == 0xFFFF_FFFF { return out }
            let length = Int(rec.readLE32(at: o + 4))
            guard length >= 24, length % 8 == 0, o + length <= rec.count, out.count < 256 else { throw XboxXVD.damaged("an MFT attribute is out of range") }
            let a = Array(rec[o..<(o + length)])
            let nameChars = Int(a[9]), nameOffset = Int(a.readLE16(at: 10))
            guard nameOffset + 2 * nameChars <= length else { throw XboxXVD.damaged("an MFT attribute name is out of range") }
            let name = String(decoding: (0..<nameChars).map { a.readLE16(at: nameOffset + 2 * $0) }, as: UTF16.self)
            if a[8] == 0 {
                let vlen = Int(a.readLE32(at: 0x10)), voff = Int(a.readLE16(at: 0x14))
                guard voff <= length, vlen <= length - voff else { throw XboxXVD.damaged("an MFT value is out of range") }
                out.append(Attribute(type: type, name: name, value: Array(a[voff..<(voff + vlen)]), runs: nil, size: UInt64(vlen)))
            } else {
                guard length >= 0x40 else { throw XboxXVD.damaged("an MFT attribute is cut short") }
                let roff = Int(a.readLE16(at: 0x20))
                guard roff < length else { throw XboxXVD.damaged("an MFT run list is out of range") }
                out.append(Attribute(type: type, name: name, value: nil, runs: try runs(Array(a[roff...])), size: a.readLE64(at: 0x30)))
            }
            o += length
        }
    }

    /// The run list: (header, length, signed LCN delta) until a zero header.
    static func runs(_ b: [UInt8]) throws -> [(lcn: UInt64?, count: UInt64)] {
        var out: [(lcn: UInt64?, count: UInt64)] = [], o = 0, lcn: Int64 = 0
        while o < b.count, b[o] != 0 {
            let lengthBytes = Int(b[o] & 0x0F), offsetBytes = Int(b[o] >> 4)
            o += 1
            guard lengthBytes >= 1, lengthBytes <= 8, offsetBytes <= 8, o + lengthBytes + offsetBytes <= b.count, out.count < 4096 else {
                throw XboxXVD.damaged("an MFT run list is malformed")
            }
            var count: UInt64 = 0
            for i in 0..<lengthBytes { count |= UInt64(b[o + i]) << (8 * UInt64(i)) }
            o += lengthBytes
            if offsetBytes == 0 {
                out.append((nil, count))
                continue
            }
            var delta: Int64 = 0
            for i in 0..<offsetBytes { delta |= Int64(b[o + i]) << (8 * Int64(i)) }
            if b[o + offsetBytes - 1] & 0x80 != 0, offsetBytes < 8 { delta -= Int64(1) << (8 * Int64(offsetBytes)) }
            o += offsetBytes
            let (next, overflow) = lcn.addingReportingOverflow(delta)
            guard !overflow, next >= 0 else { throw XboxXVD.damaged("an MFT run points before the volume") }
            lcn = next
            out.append((UInt64(lcn), count))
        }
        return out
    }
}
