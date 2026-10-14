// SPDX-License-Identifier: GPL-3.0-or-later
// The graphics backends' shader caches under Library/Caches (PLA-279): Mesa's
// disk cache in kosmickrisp/ (KosmicKrisp's translated shaders, mesa 0015, and
// Zink's) and DXMT's converted shaders in dxmt/. wine_host.c points
// MESA_SHADER_CACHE_DIR and DXMT_SHADER_CACHE_PATH there and caps Mesa's at
// 1 GB, which Mesa trims itself. Settings > Storage shows their size and clears
// them (decision 0012: through the UI); each backend fills its cache again
// from the next launch. DXVK's cache lives in the prefix's AppData\Local\dxvk
// and is not one of these.

import Foundation

enum ShaderCache {
    /// The cache directories, in the app's Library/Caches.
    nonisolated static var directories: [URL] {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ["kosmickrisp", "dxmt"].map { caches.appendingPathComponent($0, isDirectory: true) }
    }

    /// Their size on disk, 0 when there is none: the space their files take,
    /// which is what Mesa counts against its limit (most entries are a few KB,
    /// so this is about a quarter more than their byte lengths).
    nonisolated static func size() -> UInt64 {
        let fm = FileManager.default
        var total: UInt64 = 0
        for dir in directories {
            guard let walk = fm.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else {
                continue
            }
            for case let url as URL in walk {
                let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true { total += UInt64(values?.totalFileAllocatedSize ?? 0) }
            }
        }
        return total
    }

    /// Removes the contents of every cache directory, keeping the directories
    /// (wine_host.c makes kosmickrisp/ only when it sets the path). False when
    /// something could not be removed. Only while no game runs.
    @discardableResult
    nonisolated static func clear() -> Bool {
        let fm = FileManager.default
        var ok = true
        for dir in directories {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in items where (try? fm.removeItem(at: item)) == nil { ok = false }
        }
        return ok
    }
}
