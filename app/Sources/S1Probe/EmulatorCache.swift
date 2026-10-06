// SPDX-License-Identifier: GPL-3.0-or-later
// FEX's disk cache of translated code (decision 0056): where it lives in the
// prefix, how large it is, a Settings action that clears it (decision 0012:
// through the UI), and the budget a launch keeps it under.
//
// FEX writes one database per machine bucket and process bucket under
// %LOCALAPPDATA%\fex-emu\DiskCache (FEXCore DiskCache::Init; patches/fex 0021
// adds the iOS TEB slot offset to the process bucket). It prunes only on a
// machine-bucket change, so databases for slots, configurations or game
// versions no longer used stay behind; the budget clears the whole cache when
// it grows past it, and FEX fills it again from the next launch.

import Foundation
import PlayportKit

enum EmulatorCache {
    /// The prefix's fex-emu cache directory.
    nonisolated static var directory: URL {
        WineHostRuntime.documents.appendingPathComponent("prefix/drive_c/users/playport/AppData/Local/fex-emu",
                                                          isDirectory: true)
    }

    /// Past this the cache is cleared before a launch: about a dozen games'
    /// routes at the 83 MB a database The Witcher 3's start needed.
    static let budgetBytes: UInt64 = 1 << 30

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

    /// Before a launch: clears the cache when it is over the budget, and says so in the log.
    nonisolated static func keepWithinBudget(log: (String) -> Void) {
        let bytes = size()
        guard bytes > budgetBytes else { return }
        let cleared = clear()
        log("fex: disk cache \(ByteCount.format(bytes)) over its \(ByteCount.format(budgetBytes)) budget: "
            + (cleared ? "cleared" : "could not be cleared"))
    }
}
