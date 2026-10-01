// SPDX-License-Identifier: GPL-3.0-or-later
// The Cloud save conflict screen (CloudConflict.dc.html): a game whose saves
// changed on the phone and on Steam since the last sync gets one question,
// not one per file. Each side is summed over the conflicting files (how
// many, how big, the newest time), and the answer settles every file the
// same way in one `SteamService.syncCloud(resolve:)` call
// (SteamService.resolveAll). The side not picked is backed up for 30 days
// (Cloud.Backups). Until the player answers, the game does not start.

import Foundation
import SteamClientKit

public struct CloudSides: Equatable, Sendable {
    public struct Side: Equatable, Sendable {
        public var files = 0
        public var bytes = 0
        /// The newest file's time; nil when no file has one.
        public var newest: Date?
    }

    public var phone = Side()
    public var steam = Side()

    public init(_ conflicts: [SteamService.CloudConflict]) {
        for c in conflicts {
            if let size = c.phoneSize {
                phone.files += 1
                phone.bytes += size
                if let t = c.phoneTime { phone.newest = max(phone.newest ?? t, t) }
            }
            if let size = c.steamSize {
                steam.files += 1
                steam.bytes += Int(size)
                if let t = c.steamTime { steam.newest = max(steam.newest ?? t, t) }
            }
        }
    }

    /// Steam has none of these files: the phone's saves are new to Steam
    /// (a game's first sync), and keeping Steam's side keeps them off it.
    public var steamHasNone: Bool { steam.files == 0 }

    /// Which side is newer, when both have a time and they differ.
    public var newer: SteamService.CloudChoice? {
        guard let p = phone.newest, let s = steam.newest, p != s else { return nil }
        return p > s ? .phone : .steam
    }
}
