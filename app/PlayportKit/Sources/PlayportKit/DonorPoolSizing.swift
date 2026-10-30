// SPDX-License-Identifier: GPL-3.0-or-later
// How large a donor pool a Play takes (the dev build's Settings › Developer ›
// Donor pool, app/Sources/S1Probe/Dev/DonorPool.swift; PLA-351). The pool's
// pages are charged to no process, but they are the phone's RAM: with a pool,
// physical RAM and not the app's limit is the wall
// (docs/evidence/2026-10-14-donor-memory-scale.md). Auto takes the phone's tier's
// pool (MemoryPlan.Tier, decision 0105: 4 GiB on 12 GB, 1 GiB on 8 GB, none
// under), at most what one donor grants (DonorPool). It is not gated on
// jetsam's level at Play: idle processes there are jetsam's to end, and growth
// during play stops on low memory instead (growthStop, Growth). The fixed sizes stay as
// experiments, capped by jetsam's level as before.

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
    /// Under this much available memory in the first donor, no pool (an
    /// extension-class limit would give nothing worth the rounds).
    public static let minimumDonorMB = 1024
    /// The pool leaves jetsam this much of the phone's memory, in percent: the
    /// step-2 rounds' stop rule, and growth's during play.
    public static let levelFloor = 15
    /// Growth resumes once the spare memory is this much over its floor and the level
    /// levelResumeMargin points over levelFloor (so it does not flap at the floor).
    public static let resumeMarginMB = 512
    public static let levelResumeMargin = 5
    /// Objects are 256 MiB.
    public static let granuleMB = 256

    /// Whether a phone with this much RAM is offered a pool at all: its tier has one (8 GB and
    /// up); on 4 and 6 GB phones Settings offers none, and none is taken.
    public static func offered(physicalMB: Int) -> Bool { MemoryPlan.Tier(physicalMB: physicalMB).poolMB > 0 }

    /// The free + inactive + speculative + purgeable memory the phone must keep before
    /// each object, and during play: 12 % of its RAM, at least 768 MiB (1,408 MiB on 12 GB,
    /// 921 on 8 GB).
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
        /// What jetsam's level leaves above levelFloor, rounded down to a granule (the fixed sizes' cap).
        public var levelCapMB: Int { max(0, (level - levelFloor) * physicalMB / 100) / granuleMB * granuleMB }
        /// The phone's tier (MemoryPlan.Tier).
        public var tier: MemoryPlan.Tier { MemoryPlan.Tier(physicalMB: physicalMB) }
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

    /// The pool a Play asks the donors for under this setting and reading; 0 for none. Auto
    /// takes one donor's grant at most (DonorPool), which caps it further.
    public static func decide(_ setting: Setting, _ r: Reading) -> Decision {
        guard setting != .off else { return Decision(targetMB: 0, reason: "off") }
        guard offered(physicalMB: r.physicalMB) else {
            return Decision(targetMB: 0, reason: "phone has \(r.physicalMB) MiB, the \(r.tier.ramGB) GB tier has no pool")
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
            return Decision(targetMB: r.tier.poolMB, reason: "the \(r.tier.ramGB) GB tier's pool")
        }
    }

    /// Why the pool must stop growing (taking pages it has not used since its last purge)
    /// now, or nil: the phone's spare memory (free + inactive + speculative + purgeable) under
    /// the spare floor, or jetsam's level under levelFloor (an unread level, -1, is ignored).
    public static func growthStop(spareMB: Int, level: Int, physicalMB: Int) -> String? {
        let floor = spareFloorMB(physicalMB: physicalMB)
        if spareMB < floor { return "spare \(spareMB) MiB < \(floor)" }
        if level >= 0, level < levelFloor { return "level \(level)% < \(levelFloor)%" }
        return nil
    }

    /// Growth during play, checked every 2 s (DonorPool.watchGrowth): growthStop stops it, and a
    /// stopped pool grows again once the spare memory is resumeMarginMB over its floor (1,920 MiB
    /// on 12 GB) and the level levelResumeMargin points over levelFloor (20 %).
    ///
    /// Decision 0105 as amended 2026-10-30: it also grows again on spare memory alone, at a level
    /// under 20 % (run l9 stopped at level 13 % with 4,105 MiB spare and stayed stopped with
    /// 4,064-4,434). A level stop right after such a resume would flap, so after it the level
    /// stop counts from the level at that resume, at most levelFloor (`spareResumeLevel`): it
    /// fires under that level, or under levelFloor once the spare memory is back under the
    /// resume threshold; and the next resume on spare waits for the level to come back to it.
    /// At or over levelFloor the level stop is the plain rule, so a resume there (15-19 %) counts
    /// from levelFloor: run l10 resumed at 17 %, and counting from 17 % it did not resume at 15 %
    /// with 4,545 MiB spare. The spare floor's stop is unchanged. A resume on both readings ends
    /// this.
    public struct Growth: Equatable, Sendable {
        public enum Change: Equatable, Sendable {
            case stopped(String)
            case resumed(String)
        }

        public let physicalMB: Int
        public private(set) var growing = true
        /// The level at the last resume on spare memory alone, at most levelFloor, until a resume
        /// on both readings.
        public private(set) var spareResumeLevel: Int?

        public init(physicalMB: Int) { self.physicalMB = physicalMB }

        /// The spare memory a stopped pool needs to grow again: 1,920 MiB on 12 GB.
        public var resumeSpareMB: Int { spareFloorMB(physicalMB: physicalMB) + resumeMarginMB }
        public static let resumeLevel = levelFloor + levelResumeMargin

        /// One check: the change, when there is one.
        public mutating func check(spareMB: Int, level: Int) -> Change? {
            if growing {
                guard let why = stopReason(spareMB: spareMB, level: level) else { return nil }
                growing = false
                return .stopped(why)
            }
            guard resumeWait(spareMB: spareMB, level: level) == nil else { return nil }
            growing = true
            let spare = "spare \(spareMB) MiB >= \(resumeSpareMB)"
            if level < 0 {
                spareResumeLevel = nil
                return .resumed(spare + ", level unread")
            }
            if level >= Self.resumeLevel {
                spareResumeLevel = nil
                return .resumed("level \(level)% >= \(Self.resumeLevel)%, " + spare)
            }
            spareResumeLevel = min(level, levelFloor)
            return .resumed(spare + ", level \(level)% < \(Self.resumeLevel)%: on spare memory; the level stop "
                            + "now under \(min(level, levelFloor))%")
        }

        /// Why a growing pool stops now, or nil.
        public func stopReason(spareMB: Int, level: Int) -> String? {
            guard let why = growthStop(spareMB: spareMB, level: level, physicalMB: physicalMB) else { return nil }
            guard let resumedAt = spareResumeLevel, spareMB >= spareFloorMB(physicalMB: physicalMB) else { return why }
            // after a resume on spare memory: under levelFloor, but not under its level
            if level < resumedAt {
                return resumedAt >= levelFloor ? why : "level \(level)% < \(resumedAt)%, the level at the resume on spare memory"
            }
            if spareMB < resumeSpareMB { return "level \(level)% < \(levelFloor)%, spare \(spareMB) MiB < \(resumeSpareMB)" }
            return nil
        }

        /// What a stopped pool still waits for, as the stats line's `resume_wait` prints it, or nil
        /// when it resumes.
        public func resumeWait(spareMB: Int, level: Int) -> String? {
            var short: [String] = []
            if let resumedAt = spareResumeLevel, level >= 0, level < resumedAt {
                short.append("level \(level)% < \(resumedAt)% (the last resume on spare memory)")
            }
            if spareMB < resumeSpareMB { short.append("spare \(spareMB) MiB < \(resumeSpareMB)") }
            return short.isEmpty ? nil : short.joined(separator: ", ")
        }
    }

    /// Why the first donor's own limit stops the pool, or nil.
    public static func donorTooSmall(availableMB: Int) -> String? {
        availableMB < minimumDonorMB ? "donor available \(availableMB) MiB < \(minimumDonorMB)" : nil
    }
}
