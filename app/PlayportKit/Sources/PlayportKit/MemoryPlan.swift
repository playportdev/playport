// SPDX-License-Identifier: GPL-3.0-or-later
// One memory plan per Play (PLA-352): the RAM the guest is told it has and the
// video budget DXGI reports. Both come from the phone's tier (Tier, decision
// 0105, the owner's table of 2026-10-15), clamped to the app's limit L read
// just before Wine starts: a limit lower than the tier assumes (no
// increased-memory-limit entitlement, or Game Mode not on yet) tells the guest
// L rounded down to a GiB and a video figure about 3/8 of that.
//
// The app passes the plan through the environment: MADEIRA_TOTAL_PHYS_MB
// (ml992's own override) and PLAYPORT_VRAM_MB (patches/dxmt 0011, after
// madeira.cfg `vram-mb`, before ml1042's formula, which stays the fallback). A
// title's own `totalphys` or `vram-mb` (its cohort entry's `config`, the dev
// Runtime keys, the shared madeira.cfg) wins over the plan. The DXMT trim
// (ml1075) still shrinks the budget as the footprint nears the limit.
//
// A dev build's donor pool (DonorPoolSizing) backs guest RAM outside L; its Auto
// size is the tier's too. The pool no longer raises the guest's RAM: the tier's
// figure is what the guest is told.

import Foundation

public struct MemoryPlan: Equatable, Sendable {
    /// The defaults per phone, by its RAM (decision 0105: the owner's 12 and 8 GB rows,
    /// 2026-10-15; the 6 and 4 GB rows extrapolated from them and unmeasured, PLA-355).
    public struct Tier: Equatable, Sendable {
        /// The phone's marketed RAM, GB.
        public var ramGB: Int
        /// The least reported RAM (hw.memsize, MiB) of the tier: phones report less than
        /// their marketed RAM (11,734 MiB on 12 GB, 7,679 on 8, 5,734 on 6, 3,662 on 4).
        public var fromMB: Int
        /// G: the RAM the guest is told.
        public var guestRAMMB: Int
        /// The donor pool Auto asks for (0: the setting is not offered).
        public var poolMB: Int
        /// V: the dedicated video memory DXGI reports.
        public var videoMB: Int

        public static let table: [Tier] = [
            Tier(ramGB: 12, fromMB: 10 * 1024, guestRAMMB: 8192, poolMB: 4096, videoMB: 3072),
            Tier(ramGB: 8, fromMB: 7 * 1024, guestRAMMB: 6144, poolMB: 1024, videoMB: 2048),
            Tier(ramGB: 6, fromMB: 5 * 1024, guestRAMMB: 3072, poolMB: 0, videoMB: 1024),
            Tier(ramGB: 4, fromMB: 0, guestRAMMB: 2048, poolMB: 0, videoMB: 768),
        ]

        /// The tier of a phone with this much RAM; more than 12 GB takes the 12 GB row.
        public init(physicalMB: Int) {
            self = Self.table.first { physicalMB >= $0.fromMB } ?? Self.table[Self.table.count - 1]
        }

        public init(ramGB: Int, fromMB: Int, guestRAMMB: Int, poolMB: Int, videoMB: Int) {
            self.ramGB = ramGB
            self.fromMB = fromMB
            self.guestRAMMB = guestRAMMB
            self.poolMB = poolMB
            self.videoMB = videoMB
        }
    }

    /// The clamp's step: a limit under the tier's G tells the guest L rounded down to this.
    public static let clampStepMB = 1024
    /// Added to L before it is rounded down: the limit is read as available + footprint in
    /// whole MiB, 8,191 for the 8 GiB limit on the reference phone.
    public static let limitSlackMB = 64
    /// The video figure for a clamped G: 3/8 of it, rounded down to videoStepMB, at least
    /// videoFloorMB (the tier table's own V follows the same rule).
    public static let videoStepMB = 512
    public static let videoFloorMB = 768

    /// The video figure that goes with this guest RAM: 3/8 of it rounded down to 512, at least 768.
    public static func videoMB(guestRAMMB g: Int) -> Int {
        max(videoFloorMB, g * 3 / 8 / videoStepMB * videoStepMB)
    }

    /// The environment variables the runtime reads.
    public static let guestRAMVariable = "MADEIRA_TOTAL_PHYS_MB"
    public static let videoVariable = "PLAYPORT_VRAM_MB"
    /// madeira.cfg keys that win over the plan (ml993, ml1095).
    public static let guestRAMKey = "totalphys"
    public static let videoKey = "vram-mb"
    /// madeira.cfg key: 1 clamps DXVK's reported video memory and KosmicKrisp's heap budget
    /// to the plan (off by default).
    public static let vulkanKey = "vulkan-vram-plan"
    /// KosmicKrisp's cap on its heap's VK_EXT_memory_budget budget, MiB (patches/mesa 0036).
    public static let vulkanBudgetVariable = "PLAYPORT_VK_BUDGET_MB"

    /// What the plan reads at Play.
    public struct Inputs: Equatable, Sendable {
        /// L: the app's limit (available + footprint), MiB.
        public var limitMB: Int
        /// The phone's RAM (hw.memsize), MiB.
        public var physicalMB: Int
        /// The donor pool granted for this Play, MiB (0 for none); logged only.
        public var poolMB: Int

        public init(limitMB: Int, physicalMB: Int, poolMB: Int = 0) {
            self.limitMB = limitMB
            self.physicalMB = physicalMB
            self.poolMB = poolMB
        }
    }

    /// A title's own values, which win over the plan's.
    public struct Overrides: Equatable, Sendable {
        /// `totalphys` from madeira.cfg, or MADEIRA_TOTAL_PHYS_MB already set (an `env.` key).
        public var guestRAMMB: Int?
        /// `vram-mb` from madeira.cfg (ml1042 honours 256 or more).
        public var videoMB: Int?
        /// `vulkan-vram-plan = 1`: DXVK's DXGI report and KosmicKrisp's heap budget take the plan's.
        public var vulkan: Bool

        public init(guestRAMMB: Int? = nil, videoMB: Int? = nil, vulkan: Bool = false) {
            self.guestRAMMB = guestRAMMB
            self.videoMB = videoMB
            self.vulkan = vulkan
        }

        /// From the launch's effective madeira.cfg values (`value(key)`: the title's keys over
        /// the shared file) and the environment the runtime will read.
        public static func read(value: (String) -> String?, environment: [String: String]) -> Overrides {
            func int(_ s: String?) -> Int? { s.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
            var ram = int(value(guestRAMKey)).flatMap { $0 > 0 ? $0 : nil }
            if let env = int(environment[guestRAMVariable]), env > 0 { ram = env }
            let video = int(value(videoKey)).flatMap { $0 >= 256 ? $0 : nil }
            return Overrides(guestRAMMB: ram, videoMB: video, vulkan: int(value(vulkanKey)) == 1)
        }
    }

    public var inputs: Inputs
    public var overrides: Overrides
    /// The phone's tier, from its RAM.
    public var tier: Tier
    /// The guest's RAM by the plan, before any override: the tier's, clamped to L.
    public var plannedGuestRAMMB: Int
    /// The video budget by the plan, before any override (DXMT still caps it at Metal's value).
    public var plannedVideoMB: Int

    /// Whether L lowered the tier's G (and so perhaps V).
    public var clamped: Bool { plannedGuestRAMMB < tier.guestRAMMB }
    /// What the guest is told: the override, else the plan.
    public var guestRAMMB: Int { overrides.guestRAMMB ?? plannedGuestRAMMB }
    /// What DXGI reports: the override, else the plan.
    public var videoMB: Int { overrides.videoMB ?? plannedVideoMB }

    public init(_ inputs: Inputs, overrides: Overrides = Overrides()) {
        self.inputs = inputs
        self.overrides = overrides
        tier = Tier(physicalMB: inputs.physicalMB)
        let ceiling = (max(0, inputs.limitMB) + Self.limitSlackMB) / Self.clampStepMB * Self.clampStepMB
        plannedGuestRAMMB = min(tier.guestRAMMB, ceiling)
        plannedVideoMB = min(tier.videoMB, Self.videoMB(guestRAMMB: plannedGuestRAMMB))
    }

    /// The variables to set for the runtime: each value the title does not override; none
    /// when the limit was not read (the runtime's own readings then hold).
    public var environment: [String: String] {
        var env: [String: String] = [:]
        guard inputs.limitMB > 0 else { return env }
        if overrides.guestRAMMB == nil { env[Self.guestRAMVariable] = String(plannedGuestRAMMB) }
        if overrides.videoMB == nil { env[Self.videoVariable] = String(plannedVideoMB) }
        return env
    }

    /// DXVK's option that clamps the dedicated video memory its DXGI reports (heap size,
    /// Metal's recommended working set: 8 GiB on the reference phone) to this plan's;
    /// nil unless `vulkan-vram-plan = 1`.
    public var dxvkOption: String? {
        overrides.vulkan ? "dxgi.maxDeviceMemory = \(videoMB)" : nil
    }

    /// KosmicKrisp's heap budget capped at this plan's video memory (patches/mesa 0036; the
    /// heap's size stays Metal's working set); empty unless `vulkan-vram-plan = 1`.
    public var vulkanEnvironment: [String: String] {
        overrides.vulkan ? [Self.vulkanBudgetVariable: String(videoMB)] : [:]
    }

    /// The one `memory plan:` log line: the tier and its row, L and the clamp, what the guest
    /// is told and DXGI reports, the pool granted, and any override.
    public var logLine: String {
        var f = ["tier=\(tier.ramGB)GB", "ram_mb=\(inputs.physicalMB)",
                 "tier_guest_ram_mb=\(tier.guestRAMMB)", "tier_video_mb=\(tier.videoMB)",
                 "tier_pool_mb=\(tier.poolMB)", "L_mb=\(inputs.limitMB)",
                 "clamp=\(clamped ? "yes" : "none")", "planned_guest_ram_mb=\(plannedGuestRAMMB)",
                 "planned_video_mb=\(plannedVideoMB)", "pool_mb=\(inputs.poolMB)",
                 "guest_ram_mb=\(guestRAMMB)", "video_mb=\(videoMB)"]
        f.append("override=" + ([overrides.guestRAMMB.map { "totalphys=\($0)" }, overrides.videoMB.map { "vram-mb=\($0)" }]
            .compactMap { $0 }.joined(separator: ",")).ifEmpty("none"))
        f.append("vulkan_clamp=\(overrides.vulkan ? 1 : 0)")
        return f.joined(separator: " ")
    }
}

/// Reading madeira.cfg as the runtime does (Madeira build/madeira_cfg.h): `key = value`
/// lines, `#` comments, whitespace trimmed, the last line for a key wins; with no
/// madeira.cfg in the directory, the legacy `madeira-<key>.txt` holds one value.
public enum MadeiraConfig {
    /// The value of `key` in a madeira.cfg's text; nil when it is not set.
    public static func value(_ key: String, in text: String) -> String? {
        var found: String?
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            guard line[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            found = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return found
    }

    /// The value of `key` the runtime reads from `directory` (its MADEIRA_DOCS_DIR).
    public static func value(_ key: String, directory: URL) -> String? {
        let cfg = directory.appendingPathComponent(TitleConfig.fileName)
        if let data = try? Data(contentsOf: cfg) { return value(key, in: String(decoding: data, as: UTF8.self)) }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("madeira-\(key).txt")) else { return nil }
        let first = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        return first.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
