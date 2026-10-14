// SPDX-License-Identifier: GPL-3.0-or-later
// How large a donor pool a Play takes (the dev build's Settings › Developer ›
// Donor pool, app/Sources/S1Probe/Dev/DonorPool.swift; PLA-351). The pool's
// pages are charged to no process, but they are the phone's RAM: with a pool,
// physical RAM and not the app's limit is the wall
// (docs/evidence/2026-10-14-donor-memory-scale.md). A game's resident set W
// must fit in what jetsam lets the phone give (P), and its ordinary part under
// the app's limit (L), so a pool can add at most P − L. Auto asks for that,
// plus a margin for the ordinary memory the pool replaces, and nothing when
// P − L is under a GiB: on a phone where the limit is not the wall
// (an 8 GB phone with the entitlement, or the 12 GB one at Play) it is off by
// itself. The fixed sizes stay as experiments, capped by jetsam's level as before.

import Foundation

public enum DonorPoolSizing {
    /// What the setting asks for.
    public enum Setting: Equatable, Sendable {
        case off
        case auto
        /// A fixed size in MiB (an experiment).
        case fixed(Int)

        /// The value Settings stores for `auto` (the driver's `set:donorPoolMB=auto` stores the string).
        public static let autoStored = -1

        /// The setting from its UserDefaults value: an Int (0 off, -1 auto, MiB) or a string
        /// (`auto`, `off`, a number), as `pp ui --action set:donorPoolMB=…` writes it.
        public init(stored: Any?) {
            var n: Int?
            if let i = stored as? Int { n = i }
            if let s = stored as? String {
                if s.lowercased() == "auto" { self = .auto; return }
                n = s.lowercased() == "off" ? 0 : Int(s)
            }
            switch n {
            case .some(Self.autoStored): self = .auto
            case .some(let mb) where mb > 0: self = .fixed(mb)
            default: self = .off
            }
        }

        /// The Int Settings stores for it.
        public var stored: Int {
            switch self {
            case .off: return 0
            case .auto: return Self.autoStored
            case .fixed(let mb): return mb
            }
        }
    }

    /// The fixed sizes the dev Settings offers, in MiB.
    public static let fixedSizesMB = [2048, 4096, 6144]
    /// The most Auto asks for (the largest fixed size).
    public static let autoMaximumMB = 6144
    /// What Auto adds to P − L for the ordinary memory the pool replaces.
    public static let marginMB = 512
    /// Under this much P − L, Auto takes no pool: too little to be worth the risk.
    public static let minimumGainMB = 1024
    /// Under this much available memory in the first donor, no pool (an
    /// extension-class limit would give nothing worth the rounds).
    public static let minimumDonorMB = 1024
    /// The pool leaves jetsam this much of the phone's memory, in percent: the
    /// step-2 rounds' stop rule.
    public static let levelFloor = 15
    /// Below this much RAM (4 and 6 GB phones) Settings offers no pool, and none is taken.
    public static let offeredFromMB = 7 * 1024
    /// Objects are 256 MiB.
    public static let granuleMB = 256

    /// Whether a phone with this much RAM is offered a pool at all.
    public static func offered(physicalMB: Int) -> Bool { physicalMB >= offeredFromMB }

    /// The free + inactive + speculative + purgeable memory the phone must keep before
    /// each object: 12 % of its RAM, at least 768 MiB (1,408 MiB on 12 GB, 921 on 8 GB).
    public static func spareFloorMB(physicalMB: Int) -> Int { max(768, physicalMB * 12 / 100) }

    /// The phone at Play: the app's available memory and footprint (its limit L is
    /// their sum), its RAM and jetsam's level (kern.memorystatus_level, percent).
    public struct Reading: Equatable, Sendable {
        public var availableMB: Int
        public var footprintMB: Int
        public var physicalMB: Int
        public var level: Int

        public init(availableMB: Int, footprintMB: Int, physicalMB: Int, level: Int) {
            self.availableMB = availableMB
            self.footprintMB = footprintMB
            self.physicalMB = physicalMB
            self.level = level
        }

        /// L: the app's limit.
        public var limitMB: Int { availableMB + footprintMB }
        /// What jetsam's level leaves above levelFloor, rounded down to a granule.
        public var levelCapMB: Int { max(0, (level - levelFloor) * physicalMB / 100) / granuleMB * granuleMB }
        /// P: what the phone can give the app and its pool, the level's room plus what the app already holds.
        public var phoneMB: Int { max(0, (level - levelFloor) * physicalMB / 100) + footprintMB }
    }

    /// A Play's pool size and why.
    public struct Decision: Equatable, Sendable {
        public var targetMB: Int
        public var reason: String

        public init(targetMB: Int, reason: String) {
            self.targetMB = targetMB
            self.reason = reason
        }
    }

    /// The pool a Play asks the donors for under this setting and reading; 0 for none.
    public static func decide(_ setting: Setting, _ r: Reading) -> Decision {
        guard setting != .off else { return Decision(targetMB: 0, reason: "off") }
        guard offered(physicalMB: r.physicalMB) else {
            return Decision(targetMB: 0, reason: "phone has \(r.physicalMB) MiB, under \(offeredFromMB)")
        }
        guard r.level >= 0 else { return Decision(targetMB: 0, reason: "memorystatus level unreadable") }
        guard r.levelCapMB > 0 else { return Decision(targetMB: 0, reason: "level \(r.level)% leaves no room over \(levelFloor)%") }
        switch setting {
        case .off:
            return Decision(targetMB: 0, reason: "off")
        case .fixed(let mb):
            let target = min(mb, r.levelCapMB)
            return Decision(targetMB: target, reason: target < mb ? "fixed \(mb), capped by the level" : "fixed \(mb)")
        case .auto:
            guard r.availableMB > 0 else { return Decision(targetMB: 0, reason: "app limit not reported") }
            let gain = r.phoneMB - r.limitMB
            guard gain >= minimumGainMB else {
                return Decision(targetMB: 0, reason: "P-L \(gain) MiB < \(minimumGainMB)")
            }
            let wanted = (gain + marginMB) / granuleMB * granuleMB
            let target = min(autoMaximumMB, wanted, r.levelCapMB)
            let by = target == wanted ? "P-L+margin" : target == autoMaximumMB ? "the maximum" : "the level"
            return Decision(targetMB: target, reason: "P-L \(gain) MiB, \(by)")
        }
    }

    /// Why the first donor's own limit stops the pool, or nil.
    public static func donorTooSmall(availableMB: Int) -> String? {
        availableMB < minimumDonorMB ? "donor available \(availableMB) MiB < \(minimumDonorMB)" : nil
    }
}
