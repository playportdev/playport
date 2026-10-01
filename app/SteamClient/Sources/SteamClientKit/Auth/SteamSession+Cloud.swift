// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A game's Steam Cloud files for the logged-on account (Cloud.swift): the
/// Cloud service methods over the CM, the bodies over HTTP.
extension SteamSession {
    /// The largest cloud file taken (Steam's per-file limit is lower).
    static let cloudFileLimit = 256 << 20

    public func cloudChangelist(appID: UInt32, timeout: Double) async throws -> CCloudGetAppFileChangelistResponse {
        guard case .loggedOn(anonymous: false) = state else { throw SteamError.notLoggedOn }
        let body = try await requireCM().serviceCall("Cloud.GetAppFileChangelist#1",
                                                     CCloudGetAppFileChangelistRequest(appID: appID), authed: true, timeout: timeout)
        return try CCloudGetAppFileChangelistResponse.decode(body)
    }

    /// A file's content, checked against Steam's size and SHA-1.
    public func cloudDownload(appID: UInt32, name: String, timeout: Double) async throws -> [UInt8] {
        guard case .loggedOn(anonymous: false) = state else { throw SteamError.notLoggedOn }
        let body = try await requireCM().serviceCall("Cloud.ClientFileDownload#1",
                                                     CCloudClientFileDownloadRequest(appID: appID, filename: name),
                                                     authed: true, timeout: timeout)
        let r = try CCloudClientFileDownloadResponse.decode(body)
        guard !r.encrypted else { throw SteamError.unsupported("encrypted cloud files are not supported") }
        let raw = try await http.send(r.request, body: nil, maxBytes: Self.cloudFileLimit, label: "cloud download")
        return try Cloud.content(raw, rawSize: r.rawFileSize, sha: r.sha.hex)
    }

    /// Uploads files in one batch; returns the names Steam committed.
    public func cloudUpload(appID: UInt32, files: [(name: String, data: [UInt8], time: UInt64)], timeout: Double) async throws -> [String] {
        guard case .loggedOn(anonymous: false) = state else { throw SteamError.notLoggedOn }
        let cm = try requireCM()
        let batch = try CCloudBeginAppUploadBatchResponse.decode(try await cm.serviceCall(
            "Cloud.BeginAppUploadBatch#1",
            CCloudBeginAppUploadBatchRequest(appID: appID, machineName: deviceName, filesToUpload: files.map(\.name)),
            authed: true, timeout: timeout))
        var committed: [String] = []
        var result: UInt32 = 1
        for f in files {
            let sha = SHA1.hash(f.data)
            var ok = false
            do {
                let begin = try CCloudClientBeginFileUploadResponse.decode(try await cm.serviceCall(
                    "Cloud.ClientBeginFileUpload#1",
                    CCloudClientBeginFileUploadRequest(appID: appID, fileSize: UInt32(f.data.count), rawFileSize: UInt32(f.data.count),
                                                       sha: sha, timeStamp: f.time, filename: f.name, batchID: batch.batchID),
                    authed: true, timeout: timeout))
                for b in begin.blocks {
                    let start = Int(b.offset), end = min(f.data.count, start + Int(b.length))
                    guard start <= end else { throw SteamError.protocolChanged("cloud upload block past the file's end") }
                    _ = try await http.send(b, body: b.body ?? Array(f.data[start..<end]), maxBytes: 1 << 20, label: "cloud upload")
                }
                ok = true
            } catch {
                result = 2
            }
            let commit = try CCloudClientCommitFileUploadResponse.decode(try await cm.serviceCall(
                "Cloud.ClientCommitFileUpload#1",
                CCloudClientCommitFileUploadRequest(succeeded: ok, appID: appID, sha: sha, filename: f.name),
                authed: true, timeout: timeout))
            if ok, commit.committed { committed.append(f.name) } else { result = 2 }
        }
        _ = try await cm.serviceCall("Cloud.CompleteAppUploadBatchBlocking#1",
                                     CCloudCompleteAppUploadBatchRequest(appID: appID, batchID: batch.batchID, eresult: result),
                                     authed: true, timeout: timeout)
        return committed
    }
}
