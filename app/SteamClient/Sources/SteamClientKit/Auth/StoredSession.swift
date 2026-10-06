// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum SecretKeys {
    public static let service = "dev.playport.app.steamclient"
    public static let session = "session"
    public static let machineID = "machine-id"
}

/// What a session persists, serialised as JSON into one secret item.
public struct StoredSession: Codable, Sendable, Equatable {
    public var accountName: String
    public var steamID: UInt64
    public var refreshToken: String
    public var guardData: String?
    public var savedAt: Date
}
