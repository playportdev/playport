// SPDX-License-Identifier: GPL-3.0-or-later
// The FEX arena's use (runtime-risks plan, item 5; docs/ARCHITECTURE.md, "The FEX
// host band"). Every emulator thread keeps its host state in one fixed range, the
// arena: its rpmalloc heap's spans, its call-return stack and its L1 lookup cache.
// A title with enough threads fills it, and a thread that finds no room cannot
// start. A launch logs the arena's use as `band:` lines (`Use.line`) and ends with
// a `band:` mark, which tools/ui.py reads into the result event's `band`.

import Foundation

public enum FexBand {
    /// The arena's use at one moment (wine_host_band_stats), in bytes and counts.
    public struct Use: Equatable, Sendable {
        public var size: UInt64
        /// Bytes in the arena's views.
        public var used: UInt64
        /// The most `used` any reading saw.
        public var peak: UInt64
        public var views: UInt64
        /// The largest free range.
        public var largestFree: UInt64
        /// Free 16 MiB-aligned 16 MiB blocks: the rpmalloc spans that still fit.
        public var spanSlots: UInt64
        /// rpmalloc spans (16 MiB each).
        public var spans: UInt64
        /// Call-return stacks: one per live emulator thread.
        public var callret: UInt64
        /// L1 lookup caches: one per live emulator thread.
        public var l1: UInt64
        /// Bytes in every other view.
        public var other: UInt64
        /// Requests inside the arena it could not serve.
        public var refused: UInt64

        public init(size: UInt64, used: UInt64, peak: UInt64 = 0, views: UInt64 = 0, largestFree: UInt64 = 0,
                    spanSlots: UInt64 = 0, spans: UInt64 = 0, callret: UInt64 = 0, l1: UInt64 = 0,
                    other: UInt64 = 0, refused: UInt64 = 0) {
            self.size = size
            self.used = used
            self.peak = peak
            self.views = views
            self.largestFree = largestFree
            self.spanSlots = spanSlots
            self.spans = spans
            self.callret = callret
            self.l1 = l1
            self.other = other
            self.refused = refused
        }

        private static func mb(_ b: UInt64) -> UInt64 { (b + (1 << 20) - 1) >> 20 }

        /// `band: size_mb=16384 used_mb=… threads=…`, the fields tools/ui.py reads
        /// into the result event's `band`: sizes in MiB (rounded up, free space
        /// rounded down), the rest counts. `threads` is the call-return stacks.
        public var line: String {
            let fields: [(String, UInt64)] = [
                ("size_mb", Self.mb(size)), ("used_mb", Self.mb(used)), ("peak_mb", Self.mb(peak)),
                ("free_mb", size > used ? (size - used) >> 20 : 0), ("largest_free_mb", largestFree >> 20),
                ("span_slots", spanSlots), ("threads", callret), ("spans", spans), ("l1", l1),
                ("other_mb", Self.mb(other)), ("views", views), ("refused", refused),
            ]
            return "band: " + fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        }

        /// Whether `self` is worth a new `band:` line after `last`: the first
        /// reading, the use moved by 256 MiB, the thread count by 4, or a refusal.
        public func worthLogging(after last: Use?) -> Bool {
            guard let last else { return true }
            func moved(_ a: UInt64, _ b: UInt64, by s: UInt64) -> Bool { a > b ? a - b >= s : b - a >= s }
            return moved(used, last.used, by: 256 << 20) || moved(callret, last.callret, by: 4)
                || refused != last.refused
        }
    }
}
