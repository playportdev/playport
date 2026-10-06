// SPDX-License-Identifier: GPL-3.0-or-later
// FEX's disk cache of translated code (decision 0056): where it lives in the
// prefix, how large it is, a Settings action that clears it (decision 0012:
// through the UI), and the budget a launch keeps it under.
//
// FEX writes one database per machine bucket and process bucket under
// %LOCALAPPDATA%\fex-emu\DiskCache (FEXCore DiskCache::Init; patches/fex 0021
// adds the iOS TEB slot offset to the process bucket). It prunes only on a
// machine-bucket change, so databases for slots, configurations or game
// versions no longer used stay behind. Proton sets no total limit; here a
// launch clears the whole cache when it is past 5 GB or the phone is short of
// space (under 10 GB free), and FEX fills it again from that launch.

import Foundation
import PlayportKit

enum EmulatorCache {
    /// The prefix's fex-emu cache directory.
    nonisolated static var directory: URL {
        WineHostRuntime.documents.appendingPathComponent("prefix/drive_c/users/playport/AppData/Local/fex-emu",
                                                          isDirectory: true)
    }

    /// Past this the cache is cleared before a launch. Generous: clearing costs
    /// every game a cold start, and a game's database grows as more of it is
    /// played (83 MB for The Witcher 3's first minute, per TEB slot offset).
    static let budgetBytes: UInt64 = 5_000_000_000
    /// Below this much free space on the phone the cache is cleared before a launch too.
    static let minimumFreeBytes: UInt64 = 10_000_000_000

    /// The phone's free space for this app's data, nil when iOS does not say.
    nonisolated static func freeBytes() -> UInt64? {
        let v = try? WineHostRuntime.documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
    }

    /// The cache's size on disk, 0 when there is none.
    nonisolated static func size() -> UInt64 {
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: UInt64 = 0
        for case let url as URL in walk {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += UInt64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// Removes the cache; FEX makes it again at the next launch. False when it could not.
    @discardableResult
    nonisolated static func clear() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return true }
        return (try? fm.removeItem(at: directory)) != nil
    }

    /// Before a launch: clears the cache when it is over the budget or the phone
    /// is short of space, and says so in the log.
    nonisolated static func keepWithinBudget(log: (String) -> Void) {
        let bytes = size()
        guard bytes > 0 else { return }
        let free = freeBytes()
        let reason: String
        if bytes > budgetBytes {
            reason = "over its \(ByteCount.format(budgetBytes)) budget"
        } else if let free, free < minimumFreeBytes {
            reason = "with \(ByteCount.format(free)) free on the phone, under \(ByteCount.format(minimumFreeBytes))"
        } else {
            return
        }
        let cleared = clear()
        log("fex: disk cache \(ByteCount.format(bytes)) \(reason): " + (cleared ? "cleared" : "could not be cleared"))
    }
}
