// SPDX-License-Identifier: GPL-3.0-or-later
// Epic's older JSON manifest, as served (store game sign-in plan, step 1; measured
// 2026-10-07 on the four in the owner's library: Football Manager 2022, its Editor
// and Resource Archiver, Scarf), read into the binary form's model:
//
//   ManifestFileVersion, AppNameString, BuildVersionString, LaunchExeString,
//   LaunchCommand, PrereqIds; ChunkHashList, ChunkShaList, DataGroupList,
//   ChunkFilesizeList (dictionaries keyed by chunk GUID); FileManifestList
//   (Filename, FileHash, FileChunkParts {Guid, Offset, Size}, optional flags
//   and InstallTags); CustomFields.
//
// Numbers and hashes are "blobs": one `%03d` per byte, little-endian for a number
// (`"000000016000"` is 1 048 576). A GUID is 32 hex digits, four big-endian words.
// The form names no window size: every chunk is 1 MiB of plain data, and
// `EpicChunkFile.decode` checks that, so a smaller one fails the install rather
// than corrupting it. The same caps as the binary form; a damaged manifest throws.

import Foundation
import ContentKit

extension EpicManifest {
    static let jsonWindow: UInt32 = 1 << 20

    /// A number as the JSON form stores it, at most `width` bytes.
    static func blob(_ s: String, width: Int) throws -> UInt64 {
        let u = Array(s.utf8)
        guard width <= 8, !u.isEmpty, u.count % 3 == 0, u.count / 3 <= width else {
            throw ClientError.unsafeContent("Epic JSON manifest: a number of \(u.count) digits")
        }
        var v: UInt64 = 0
        for i in stride(from: 0, to: u.count, by: 3) {
            var b = 0
            for d in u[i..<(i + 3)] {
                guard d >= 0x30, d <= 0x39 else { throw ClientError.unsafeContent("Epic JSON manifest: not a number") }
                b = b * 10 + Int(d - 0x30)
            }
            guard b <= 255 else { throw ClientError.unsafeContent("Epic JSON manifest: a byte of \(b)") }
            v |= UInt64(b) << UInt64(8 * (i / 3))
        }
        return v
    }

    /// A hash as the JSON form stores it: `count` bytes, one `%03d` each, in order.
    static func blobBytes(_ s: String, count: Int) throws -> [UInt8] {
        let u = Array(s.utf8)
        guard u.count == count * 3 else { throw ClientError.unsafeContent("Epic JSON manifest: a hash of \(u.count) digits") }
        return try stride(from: 0, to: u.count, by: 3).map { i in
            UInt8(try blob(String(decoding: u[i..<(i + 3)], as: UTF8.self), width: 1))
        }
    }

    /// A JSON GUID (four big-endian words in hex) as the binary form stores it (each word little-endian).
    static func jsonGUID(_ s: String) throws -> [UInt8] {
        guard s.utf8.count == 32, let b = EpicContent.hex(s) else { throw ClientError.unsafeContent("Epic JSON manifest: a GUID") }
        return stride(from: 0, to: 16, by: 4).flatMap { b[$0..<($0 + 4)].reversed() }
    }

    private struct JSONForm: Decodable {
        struct File: Decodable {
            struct Part: Decodable {
                var Guid: String
                var Offset: String
                var Size: String
            }
            var Filename: String
            var FileHash: String
            var bIsReadOnly: Bool?
            var bIsCompressed: Bool?
            var bIsUnixExecutable: Bool?
            var InstallTags: [String]?
            var FileChunkParts: [Part]
        }
        var ManifestFileVersion: String
        var AppNameString: String?
        var BuildVersionString: String?
        var LaunchExeString: String?
        var LaunchCommand: String?
        var PrereqIds: [String]?
        var FileManifestList: [File]
        var ChunkHashList: [String: String]
        var ChunkShaList: [String: String]
        var DataGroupList: [String: String]
        var ChunkFilesizeList: [String: String]
        var CustomFields: [String: String]?
    }

    static func parseJSON(_ data: [UInt8]) throws -> EpicManifest {
        guard data.count <= maxBody else { throw ClientError.unsafeContent("Epic JSON manifest: \(data.count) bytes") }
        let raw: JSONForm
        do { raw = try JSONDecoder().decode(JSONForm.self, from: Data(data)) } catch {
            throw ClientError.protocolChanged("Epic JSON manifest: unexpected shape")
        }
        let nc = raw.ChunkFilesizeList.count
        guard nc <= maxCount, raw.FileManifestList.count <= maxCount, raw.ChunkHashList.count == nc,
              raw.ChunkShaList.count == nc, raw.DataGroupList.count == nc else {
            throw ClientError.unsafeContent("Epic JSON manifest: the chunk lists disagree")
        }
        var chunks: [Chunk] = []
        chunks.reserveCapacity(nc)
        var byGUID: [String: Int] = [:]
        // A stable order: by GUID.
        for key in raw.ChunkFilesizeList.keys.sorted() {
            guard let hash = raw.ChunkHashList[key], let sha = raw.ChunkShaList[key], let group = raw.DataGroupList[key],
                  let size = raw.ChunkFilesizeList[key], sha.utf8.count == 40, let sha1 = EpicContent.hex(sha) else {
                throw ClientError.unsafeContent("Epic JSON manifest: the chunk lists disagree")
            }
            let g = try blob(group, width: 1), fileSize = try blob(size, width: 8)
            guard g < 100, fileSize <= 128 << 20 else { throw ClientError.unsafeContent("Epic chunk: sizes out of range") }
            guard byGUID.updateValue(chunks.count, forKey: key.uppercased()) == nil else {
                throw ClientError.unsafeContent("Epic chunk GUID listed twice")
            }
            chunks.append(Chunk(guid: try jsonGUID(key), hash: try blob(hash, width: 8), sha1: sha1, group: UInt8(g),
                                window: jsonWindow, fileSize: fileSize))
        }
        var files: [File] = []
        files.reserveCapacity(raw.FileManifestList.count)
        for f in raw.FileManifestList {
            guard f.FileChunkParts.count <= maxCount else { throw ClientError.unsafeContent("Epic JSON manifest: a file of \(f.FileChunkParts.count) parts") }
            let parts = try f.FileChunkParts.map { p -> Part in
                guard let k = byGUID[p.Guid.uppercased()] else {
                    throw ClientError.unsafeContent("Epic file part names a chunk the manifest lacks")
                }
                let offset = try blob(p.Offset, width: 4), size = try blob(p.Size, width: 4)
                guard size > 0, offset + size <= UInt64(jsonWindow) else { throw ClientError.unsafeContent("Epic file part outside its chunk") }
                return Part(chunk: k, offset: UInt32(offset), size: UInt32(size))
            }
            let flags = (f.bIsReadOnly == true ? 1 : 0) | (f.bIsCompressed == true ? 2 : 0) | (f.bIsUnixExecutable == true ? 4 : 0)
            files.append(File(path: try SafePath.normalize(f.Filename), symlinkTarget: "", sha1: try blobBytes(f.FileHash, count: 20),
                              flags: UInt8(flags), installTags: f.InstallTags ?? [], parts: parts))
        }
        return EpicManifest(featureLevel: UInt32(try blob(raw.ManifestFileVersion, width: 4)), appName: raw.AppNameString ?? "",
                            buildVersion: raw.BuildVersionString ?? "", launchExe: raw.LaunchExeString ?? "",
                            launchCommand: raw.LaunchCommand ?? "", prerequisites: raw.PrereqIds ?? [], chunks: chunks,
                            files: files, custom: raw.CustomFields ?? [:])
    }
}
