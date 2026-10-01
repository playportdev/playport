// SPDX-License-Identifier: GPL-3.0-or-later
// The JIT pool: the one block of executable memory a launch gets, blessed once
// by the debugger before the runtime starts (docs/ARCHITECTURE.md, "JIT pool
// placement"), which never grows. PE images and guest JIT code (Mono, V8) are
// copied into its head, from the bottom up; FEX's translated code goes into its
// tail, from the top down. Its size is fixed at the Play, and every byte of it
// counts against the app's memory limit from the bless on, so every Play gets the
// least that the games measured need (`sizeMB`, decision 0036, which replaced 0019's
// eighth of the limit). A launch logs its use as `pool:` lines
// (`Use.line`), and one that ran out of it ends with its own outcome
// (`Use.exhaustion`).

import Foundation

public enum JitPool {
    /// What the executable's exec-time reservation is laid out for: 960 MiB holds
    /// this plus 64 MiB of slack at its start at any slide (wine_host.c
    /// host_pool_reserve); a larger pool is placed first fit, which failed about one
    /// launch in four. A dev build's simulated pool may go up to it.
    public static let maximumMB = 896
    /// What every Play gets: the high-water marks measured (The Witcher 3: head
    /// 206 MiB, tail 145 MiB; Kingdom Come: Deliverance: head 182, tail 161) with
    /// FEX's 128 MiB code buffer still granted (docs/evidence/2026-09-28-jit-pool.md,
    /// 2026-10-01-kcd-memory.md). More would come out of the game's memory: Kingdom
    /// Come loads Rattay about 100 MB under the 8 GB limit only with this size.
    public static let minimumMB = 512

    /// The pool a Play gets: `minimumMB`, whatever the memory limit (decision 0036).
    /// The limit is still taken, for the day a size depends on it again.
    public static func sizeMB(limitMB: Int?) -> Int {
        minimumMB
    }

    /// What ran out, from the runtime's refusal counts.
    public enum Exhaustion: String, Equatable, Sendable {
        /// An image, a guest JIT block or a child's ntdll copy found no room in the head.
        case head
        /// FEX asked for a code buffer of 1 MiB or less and was refused: it cannot translate any more.
        case tail
        /// A guest JIT region found no slot in the anonymous-alias table.
        case alias
    }

    /// The pool's use at one moment (wine_host_pool_stats), in bytes and counts.
    public struct Use: Equatable, Sendable {
        public var size: UInt64
        /// The head's bump cursor: the most images and guest JIT blocks have ever reached.
        public var head: UInt64
        public var headLive: UInt64
        public var headFree: UInt64
        /// What FEX's code buffers reserved from the top.
        public var tail: UInt64
        public var tailLive: UInt64
        public var aliasLive: UInt64
        public var aliasSlots: UInt64
        public var aliasCap: UInt64
        public var images: UInt64
        public var childCopies: UInt64
        public var childBytes: UInt64
        public var headExhausted: UInt64
        public var tailRefused: UInt64
        public var tailFatal: UInt64
        public var aliasFull: UInt64

        public init(size: UInt64, head: UInt64, headLive: UInt64 = 0, headFree: UInt64 = 0, tail: UInt64,
                    tailLive: UInt64 = 0, aliasLive: UInt64 = 0, aliasSlots: UInt64 = 0, aliasCap: UInt64 = 0,
                    images: UInt64 = 0, childCopies: UInt64 = 0, childBytes: UInt64 = 0, headExhausted: UInt64 = 0,
                    tailRefused: UInt64 = 0, tailFatal: UInt64 = 0, aliasFull: UInt64 = 0) {
            self.size = size
            self.head = head
            self.headLive = headLive
            self.headFree = headFree
            self.tail = tail
            self.tailLive = tailLive
            self.aliasLive = aliasLive
            self.aliasSlots = aliasSlots
            self.aliasCap = aliasCap
            self.images = images
            self.childCopies = childCopies
            self.childBytes = childBytes
            self.headExhausted = headExhausted
            self.tailRefused = tailRefused
            self.tailFatal = tailFatal
            self.aliasFull = aliasFull
        }

        /// Room between the head and the tail.
        public var room: UInt64 { size > head + tail ? size - head - tail : 0 }

        /// What ran out, the first of head, tail and alias table that did; nil for none.
        /// A refused code buffer larger than 1 MiB is not one: FEX asks again for half.
        public var exhaustion: Exhaustion? {
            if headExhausted > 0 { return .head }
            if tailFatal > 0 { return .tail }
            if aliasFull > 0 { return .alias }
            return nil
        }

        private static func mb(_ b: UInt64) -> UInt64 { (b + (1 << 20) - 1) >> 20 }

        /// `pool: size_mb=896 head_mb=153 …`, the fields tools/ui.py reads into the
        /// result event's `pool`: sizes in MiB (rounded up), the rest counts.
        public var line: String {
            let fields: [(String, UInt64)] = [
                ("size_mb", Self.mb(size)), ("head_mb", Self.mb(head)), ("head_live_mb", Self.mb(headLive)),
                ("head_free_mb", Self.mb(headFree)), ("tail_mb", Self.mb(tail)), ("tail_live_mb", Self.mb(tailLive)),
                ("room_mb", room >> 20), ("alias", aliasLive), ("alias_slots", aliasSlots), ("alias_cap", aliasCap),
                ("images", images), ("children", childCopies), ("children_mb", Self.mb(childBytes)),
                ("head_exhausted", headExhausted), ("tail_refused", tailRefused), ("tail_fatal", tailFatal),
                ("alias_full", aliasFull),
            ]
            return "pool: " + fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
                + " exhausted=" + (exhaustion?.rawValue ?? "none")
        }

        /// Whether `self` is worth a new `pool:` line after `last`: the first
        /// reading, the head or tail moved by 8 MiB, the alias table's slots by 64,
        /// a child copy was made, or a refusal was counted.
        public func worthLogging(after last: Use?) -> Bool {
            guard let last else { return true }
            let step: UInt64 = 8 << 20
            func moved(_ a: UInt64, _ b: UInt64, by s: UInt64) -> Bool { a > b ? a - b >= s : b - a >= s }
            return moved(head, last.head, by: step) || moved(tail, last.tail, by: step)
                || moved(aliasSlots, last.aliasSlots, by: 64) || childCopies != last.childCopies
                || headExhausted != last.headExhausted || tailRefused != last.tailRefused
                || tailFatal != last.tailFatal || aliasFull != last.aliasFull
        }
    }

    /// ` pool=exhausted:<part>`, what a launch's result line carries when the
    /// pool ran out (LaunchCoordinator); tools/ui.py does not count such a run ok.
    public static func resultField(_ e: Exhaustion) -> String { "pool=exhausted:\(e.rawValue)" }

    /// The part a result line names as exhausted; nil for any other line.
    public static func parseExhaustion(_ line: String) -> Exhaustion? {
        for field in line.split(separator: " ") where field.hasPrefix("pool=exhausted:") {
            return Exhaustion(rawValue: String(field.dropFirst("pool=exhausted:".count)))
        }
        return nil
    }
}
