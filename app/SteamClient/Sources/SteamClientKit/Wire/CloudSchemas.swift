// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// steammessages_cloud.steamclient.proto at the JavaSteam commit Schemas.swift
// pins: the Cloud service methods Cloud.swift uses, each with only the fields
// it reads or writes.

/// An HTTP request Steam hands out for a file body.
public struct CloudHTTPRequest: Sendable, Equatable {
    public var host: String
    public var path: String
    public var https: Bool
    /// EHTTPMethod: 1 GET, 3 POST, 4 PUT.
    public var method: Int32
    public var headers: [(String, String)]
    public var offset: UInt64
    public var length: UInt32
    public var body: [UInt8]?

    public var url: URL? { URL(string: (https ? "https://" : "http://") + host + path) }

    public static func == (a: Self, b: Self) -> Bool {
        a.host == b.host && a.path == b.path && a.https == b.https && a.method == b.method
            && a.headers.map { "\($0.0)=\($0.1)" } == b.headers.map { "\($0.0)=\($0.1)" }
            && a.offset == b.offset && a.length == b.length && a.body == b.body
    }

    static func headers(_ f: ProtoFields, _ field: Int, _ name: String) throws -> [(String, String)] {
        try f.messages(field, as: name).map { (try $0.string(1) ?? "", try $0.string(2) ?? "") }
    }
}

/// Cloud.GetAppFileChangelist#1.
public struct CCloudGetAppFileChangelistRequest: ProtoMessage {
    public var appID: UInt32          // 1
    public var syncedChangeNumber: UInt64 = 0 // 2
    public func encode() -> [UInt8] {
        var w = ProtoWriter(); w.uint32(1, appID); w.uint64(2, syncedChangeNumber); return w.bytes
    }
}

public struct CCloudGetAppFileChangelistResponse: ProtoDecodable {
    public static let protoName = "CCloud_GetAppFileChangelist_Response"
    public struct File: Sendable, Equatable {
        public var name: String           // 1
        public var sha: [UInt8]           // 2
        public var timeStamp: UInt64      // 3
        public var rawSize: UInt32        // 4
        /// ECloudStoragePersistState: 0 persisted, 1 forgotten, 2 deleted.
        public var persistState: UInt32   // 5
        public var prefixIndex: UInt32?   // 7
    }
    public var currentChangeNumber: UInt64 // 1
    public var files: [File]               // 2
    public var onlyDelta: Bool             // 3
    public var pathPrefixes: [String]      // 4
    public init(_ f: ProtoFields) throws {
        currentChangeNumber = try f.uint64(1) ?? 0
        files = try f.messages(2, as: "CCloud_AppFileInfo").map {
            File(name: try $0.string(1) ?? "", sha: try $0.bytes(2) ?? [], timeStamp: try $0.uint64(3) ?? 0,
                 rawSize: try $0.uint32(4) ?? 0, persistState: try $0.uint32(5) ?? 0, prefixIndex: try $0.uint32(7))
        }
        onlyDelta = try f.bool(3) ?? false
        pathPrefixes = try f.repeatedStrings(4)
    }

    /// Each persisted file by its full cloud name (prefix + name).
    public var remote: [String: Cloud.Remote] {
        var out: [String: Cloud.Remote] = [:]
        for file in files where file.persistState == 0 {
            let prefix = file.prefixIndex.flatMap { Int($0) < pathPrefixes.count ? pathPrefixes[Int($0)] : nil } ?? ""
            let name = prefix + file.name
            out[name] = Cloud.Remote(name: name, sha: file.sha.hex, size: file.rawSize, time: file.timeStamp)
        }
        return out
    }
}

/// Cloud.ClientFileDownload#1.
public struct CCloudClientFileDownloadRequest: ProtoMessage {
    public var appID: UInt32      // 1
    public var filename: String   // 2
    public func encode() -> [UInt8] { var w = ProtoWriter(); w.uint32(1, appID); w.string(2, filename); return w.bytes }
}

public struct CCloudClientFileDownloadResponse: ProtoDecodable {
    public static let protoName = "CCloud_ClientFileDownload_Response"
    public var fileSize: UInt32     // 2
    public var rawFileSize: UInt32  // 3
    public var sha: [UInt8]         // 4
    public var timeStamp: UInt64    // 5
    public var request: CloudHTTPRequest // 7 host, 8 path, 9 https, 10 headers
    public var encrypted: Bool      // 11
    public init(_ f: ProtoFields) throws {
        fileSize = try f.uint32(2) ?? 0
        rawFileSize = try f.uint32(3) ?? 0
        sha = try f.bytes(4) ?? []
        timeStamp = try f.uint64(5) ?? 0
        request = CloudHTTPRequest(host: try f.string(7) ?? "", path: try f.string(8) ?? "", https: try f.bool(9) ?? true,
                                   method: 1, headers: try CloudHTTPRequest.headers(f, 10, "HTTPHeaders"),
                                   offset: 0, length: fileSize, body: nil)
        encrypted = try f.bool(11) ?? false
    }
}

/// Cloud.BeginAppUploadBatch#1.
public struct CCloudBeginAppUploadBatchRequest: ProtoMessage {
    public var appID: UInt32         // 1
    public var machineName: String   // 2
    public var filesToUpload: [String] // 3
    public func encode() -> [UInt8] {
        var w = ProtoWriter()
        w.uint32(1, appID); w.string(2, machineName)
        filesToUpload.forEach { w.string(3, $0) }
        return w.bytes
    }
}

public struct CCloudBeginAppUploadBatchResponse: ProtoDecodable {
    public static let protoName = "CCloud_BeginAppUploadBatch_Response"
    public var batchID: UInt64         // 1
    public var appChangeNumber: UInt64 // 4
    public init(_ f: ProtoFields) throws {
        batchID = try f.uint64(1) ?? 0
        appChangeNumber = try f.uint64(4) ?? 0
    }
}

/// Cloud.ClientBeginFileUpload#1.
public struct CCloudClientBeginFileUploadRequest: ProtoMessage {
    public var appID: UInt32     // 1
    public var fileSize: UInt32  // 2 (sent as is: not compressed)
    public var rawFileSize: UInt32 // 3
    public var sha: [UInt8]      // 4
    public var timeStamp: UInt64 // 5
    public var filename: String  // 6
    public var batchID: UInt64   // 13
    public func encode() -> [UInt8] {
        var w = ProtoWriter()
        w.uint32(1, appID); w.uint32(2, fileSize); w.uint32(3, rawFileSize); w.bytes(4, sha)
        w.uint64(5, timeStamp); w.string(6, filename)
        w.bool(10, false)   // can_encrypt
        w.uint64(13, batchID)
        return w.bytes
    }
}

public struct CCloudClientBeginFileUploadResponse: ProtoDecodable {
    public static let protoName = "CCloud_ClientBeginFileUpload_Response"
    public var encryptFile: Bool                // 1
    public var blocks: [CloudHTTPRequest]       // 2 ClientCloudFileUploadBlockDetails
    public init(_ f: ProtoFields) throws {
        encryptFile = try f.bool(1) ?? false
        blocks = try f.messages(2, as: "ClientCloudFileUploadBlockDetails").map {
            CloudHTTPRequest(host: try $0.string(1) ?? "", path: try $0.string(2) ?? "", https: try $0.bool(3) ?? true,
                             method: try $0.int32(4) ?? 4, headers: try CloudHTTPRequest.headers($0, 5, "HTTPHeaders"),
                             offset: try $0.uint64(6) ?? 0, length: try $0.uint32(7) ?? 0, body: try $0.bytes(8))
        }
    }
}

/// Cloud.ClientCommitFileUpload#1.
public struct CCloudClientCommitFileUploadRequest: ProtoMessage {
    public var succeeded: Bool   // 1
    public var appID: UInt32     // 2
    public var sha: [UInt8]      // 3
    public var filename: String  // 4
    public func encode() -> [UInt8] {
        var w = ProtoWriter(); w.bool(1, succeeded); w.uint32(2, appID); w.bytes(3, sha); w.string(4, filename); return w.bytes
    }
}

public struct CCloudClientCommitFileUploadResponse: ProtoDecodable {
    public static let protoName = "CCloud_ClientCommitFileUpload_Response"
    public var committed: Bool // 1
    public init(_ f: ProtoFields) throws { committed = try f.bool(1) ?? false }
}

/// Cloud.CompleteAppUploadBatchBlocking#1.
public struct CCloudCompleteAppUploadBatchRequest: ProtoMessage {
    public var appID: UInt32   // 1
    public var batchID: UInt64 // 2
    public var eresult: UInt32 // 3
    public func encode() -> [UInt8] { var w = ProtoWriter(); w.uint32(1, appID); w.uint64(2, batchID); w.uint32(3, eresult); return w.bytes }
}

/// A response with no fields this client reads.
public struct EmptyResponse: ProtoDecodable {
    public static let protoName = "empty"
    public init(_ f: ProtoFields) throws {}
}
