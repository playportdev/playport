// SPDX-License-Identifier: GPL-3.0-or-later
// FEX's disk cache of translated code (decision 0056): where it lives in the
// prefix, how large it is, a Settings action that clears it (decision 0012:
// through the UI), and the budget a launch keeps it under.
//
// FEX writes one database per machine bucket and process bucket under
// %LOCALAPPDATA%\fex-emu\DiskCache (FEXCore DiskCache::Init; patches/fex 0041
// adds the FEX build to the machine bucket, so an app update with a new FEX
// starts over). It prunes only on a machine-bucket change, so databases for
// configurations or game versions no longer used stay behind. Proton sets no total limit; here a
// launch clears the whole cache when it is past 5 GB or the phone is short of
// space (under 10 GB free), and FEX fills it again from that launch.
//
// The row also counts and clears the runtime's copies of large x86-64 images
// (decision 0167, Library/Caches/images, wine_host.c's PLAYPORT_IMAGE_CACHE_DIR):
// the runtime keeps them within their own 1 GiB budget, so a launch's budget
// check leaves them alone.

import Foundation
import PlayportKit

enum EmulatorCache {
    /// The prefix's fex-emu cache directory.
    nonisolated static var directory: URL {
        WineHostRuntime.documents.appendingPathComponent("prefix/drive_c/users/playport/AppData/Local/fex-emu",
                                                          isDirectory: true)
    }

    /// The runtime's re-laid-out image copies (decision 0167).
    nonisolated static var imageDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("images", isDirectory: true)
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

    /// The cache's size on disk with the image copies, 0 when there is none.
    nonisolated static func size() -> UInt64 {
        size(of: directory) + size(of: imageDirectory)
    }

    nonisolated private static func size(of dir: URL) -> UInt64 {
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: UInt64 = 0
        for case let url as URL in walk {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += UInt64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// Removes the cache and the image copies; FEX and the runtime make them again from the next
    /// launch (the image directory itself stays: wine_host.c makes it only at start). False when
    /// something could not be removed. Only while no game runs.
    @discardableResult
    nonisolated static func clear() -> Bool {
        let fm = FileManager.default
        var ok = clearFEX()
        if let items = try? fm.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil) {
            for item in items where (try? fm.removeItem(at: item)) == nil { ok = false }
        }
        return ok
    }

    nonisolated private static func clearFEX() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return true }
        return (try? fm.removeItem(at: directory)) != nil
    }

    /// Before a launch: clears the cache when it is over the budget or the phone
    /// is short of space, and says so in the log.
    nonisolated static func keepWithinBudget(log: (String) -> Void) {
        let bytes = size(of: directory)
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
        let cleared = clearFEX()
        log("fex: disk cache \(ByteCount.format(bytes)) \(reason): " + (cleared ? "cleared" : "could not be cleared"))
    }
}
