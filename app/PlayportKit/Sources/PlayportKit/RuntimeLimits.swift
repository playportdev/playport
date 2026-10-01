// SPDX-License-Identifier: GPL-3.0-or-later
// The runtime's known limits that no measured title reaches (runtime-risks plan,
// item 8; docs/ARCHITECTURE.md, "Known runtime limits"): a W+X request the kernel
// granted without WRITE, which fails; x18 instructions the patcher left to fault
// at run time; and misaligned atomics in native ARM64EC code that the exception
// handler emulates one at a time, which are not atomic against other threads'
// plain stores. A launch logs the counts as `limits:` lines (`Counts.line`), so
// the title that reaches one is named in its run's result.

import Foundation

public enum RuntimeLimits {
    /// The runtime's counts since it started (wine_host_limit_stats).
    public struct Counts: Equatable, Sendable {
        /// W+X requests mprotect granted without WRITE; each one failed.
        public var wxDropped: UInt64
        /// Images whose x18 patching was refused or cut short.
        public var x18Images: UInt64
        /// x18 instructions left to fault at run time.
        public var x18Sites: UInt64
        /// Misaligned exclusives and CAS emulated one at a time.
        public var splitLock: UInt64

        public init(wxDropped: UInt64 = 0, x18Images: UInt64 = 0, x18Sites: UInt64 = 0, splitLock: UInt64 = 0) {
            self.wxDropped = wxDropped
            self.x18Images = x18Images
            self.x18Sites = x18Sites
            self.splitLock = splitLock
        }

        /// `limits: wx_dropped=0 x18_images=0 x18_sites=0 split_lock=0`, the fields
        /// tools/ui.py reads into the result event's `limits`.
        public var line: String {
            let fields: [(String, UInt64)] = [
                ("wx_dropped", wxDropped), ("x18_images", x18Images), ("x18_sites", x18Sites),
                ("split_lock", splitLock),
            ]
            return "limits: " + fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        }

        /// Whether `self` is worth a new `limits:` line after `last`: the first
        /// reading, or any count changed.
        public func worthLogging(after last: Counts?) -> Bool {
            guard let last else { return true }
            return self != last
        }
    }
}
