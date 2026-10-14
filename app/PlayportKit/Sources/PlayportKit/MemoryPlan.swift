// SPDX-License-Identifier: GPL-3.0-or-later
// One memory plan per Play (PLA-352): the RAM the guest is told it has and the
// video budget DXGI reports, from one reading of the app's limit, so the two
// add up under it. Before, ntdll's ml992 told the guest the whole limit (8,192
// MiB on the reference phone) while DXMT's ml1042 budgeted video memory as if
// the guest were told 4 GiB, with a 2.5 GiB overhead measured with the old
// 896 MiB JIT pool, read at the first DXGI query (so a query before Game Mode
// raised the limit gave the 1 GiB floor for the whole run).
//
// The app computes the plan just before Wine starts and passes it through the
// environment: MADEIRA_TOTAL_PHYS_MB (ml992's own override) and
// PLAYPORT_VRAM_MB (patches/dxmt 0011, after madeira.cfg `vram-mb`, before
// ml1042's formula, which stays the fallback). A title's own `totalphys` or
// `vram-mb` (its cohort entry's `config`, the dev Runtime keys, the shared
// madeira.cfg) wins over the plan. The DXMT trim (ml1075) still shrinks the
// budget as the footprint nears the limit.
//
// A donor pool backs guest RAM only, outside the app's limit; GPU memory stays
// ordinary, and with a pool physical RAM is the wall
// (docs/evidence/2026-10-14-donor-memory-scale.md). So a pool may raise the
// guest's RAM only up to the game's budget, the RAM Auto sizes the pool from
// (DonorPoolSizing.gameBudgetMB, less L), never the video budget.

import Foundation

public struct MemoryPlan: Equatable, Sendable {
    /// The runtime's own share of the limit, neither the guest's heap nor the GPU: Kingdom
    /// Come's census with the 512 MiB JIT pool had JIT 512 + FEX band 473 + images 132 +
    /// host about 820 = 1,937 MiB (docs/evidence/2026-10-14-donor-pool-widen.md), rounded up.
    public static let overheadMB = 2048
    /// The guest heap's share of the limit the video budget leaves room for (Kingdom Come's
    /// guest reached about 4.1–4.4 GiB at its peak).
    public static let guestShareMB = 4096
    /// Kept under the limit: Kingdom Come's peak (7,914 MB) left 278 MiB; the 384 MiB the
    /// 512 MiB JIT pool freed (decision 0036) stays as headroom.
    public static let marginMB = 512
    /// At or under this limit the guest is told less than the limit (the runtime's share is not its).
    public static let lowLimitMB = 6144
    /// The video budget's floor (ml1042's) above lowVideoLimitMB, and at or under it (an
    /// unentitled limit, 2–3.4 GB) ml1075's trim floor: 1 GiB is more than such a limit affords.
    public static let videoFloorMB = 1024
    public static let lowVideoFloorMB = 768
    public static let lowVideoLimitMB = 4096
    /// Guest RAM is a multiple of this when the plan lowers it.
    public static let granuleMB = 256

    /// The environment variables the runtime reads.
    public static let guestRAMVariable = "MADEIRA_TOTAL_PHYS_MB"
    public static let videoVariable = "PLAYPORT_VRAM_MB"
    /// madeira.cfg keys that win over the plan (ml993, ml1095).
    public static let guestRAMKey = "totalphys"
    public static let videoKey = "vram-mb"
    /// madeira.cfg key: 1 clamps DXVK's reported video memory to the plan (off by default).
    public static let vulkanKey = "vulkan-vram-plan"

    /// What the plan reads at Play.
    public struct Inputs: Equatable, Sendable {
        /// L: the app's limit (available + footprint), MiB.
        public var limitMB: Int
        /// The phone's RAM (hw.memsize), MiB.
        public var physicalMB: Int
        /// The donor pool granted for this Play, MiB (0 for none).
        public var poolMB: Int

        public init(limitMB: Int, physicalMB: Int, poolMB: Int = 0) {
            self.limitMB = limitMB
            self.physicalMB = physicalMB
            self.poolMB = poolMB
        }

        /// What the game may use of the phone's RAM (DonorPoolSizing.gameBudgetMB).
        public var budgetMB: Int { DonorPoolSizing.gameBudgetMB(physicalMB: physicalMB) }
    }

    /// A title's own values, which win over the plan's.
    public struct Overrides: Equatable, Sendable {
        /// `totalphys` from madeira.cfg, or MADEIRA_TOTAL_PHYS_MB already set (an `env.` key).
        public var guestRAMMB: Int?
        /// `vram-mb` from madeira.cfg (ml1042 honours 256 or more).
        public var videoMB: Int?
        /// `vulkan-vram-plan = 1`.
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
    /// The guest's RAM by the plan, before any override.
    public var plannedGuestRAMMB: Int
    /// What a pool added to it.
    public var poolRaiseMB: Int
    /// The video budget by the plan, before any override (DXMT still caps it at Metal's value).
    public var plannedVideoMB: Int

    /// What the guest is told: the override, else the plan.
    public var guestRAMMB: Int { overrides.guestRAMMB ?? plannedGuestRAMMB }
    /// What DXGI reports: the override, else the plan.
    public var videoMB: Int { overrides.videoMB ?? plannedVideoMB }

    public init(_ inputs: Inputs, overrides: Overrides = Overrides()) {
        self.inputs = inputs
        self.overrides = overrides
        let l = max(0, inputs.limitMB)
        let base: Int
        if l > Self.lowLimitMB {
            base = l
        } else {
            base = max(l - Self.overheadMB, l / 2) / Self.granuleMB * Self.granuleMB
        }
        let room = inputs.physicalMB > 0 ? max(0, inputs.budgetMB - l) / Self.granuleMB * Self.granuleMB : 0
        poolRaiseMB = min(max(0, inputs.poolMB), room)
        plannedGuestRAMMB = max(0, min(base + poolRaiseMB, inputs.physicalMB > 0 ? inputs.physicalMB : Int.max))
        let floor = l > Self.lowVideoLimitMB ? Self.videoFloorMB : Self.lowVideoFloorMB
        plannedVideoMB = max(floor, l - min(base, Self.guestShareMB) - Self.overheadMB - Self.marginMB)
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

    /// The one `memory plan:` log line.
    public var logLine: String {
        var f = ["L_mb=\(inputs.limitMB)", "ram_mb=\(inputs.physicalMB)",
                 "budget_mb=\(inputs.budgetMB)", "pool_mb=\(inputs.poolMB)",
                 "guest_ram_mb=\(guestRAMMB)", "video_mb=\(videoMB)",
                 "planned_guest_ram_mb=\(plannedGuestRAMMB)", "pool_raise_mb=\(poolRaiseMB)",
                 "planned_video_mb=\(plannedVideoMB)",
                 "overhead_mb=\(Self.overheadMB)", "guest_share_mb=\(Self.guestShareMB)", "margin_mb=\(Self.marginMB)"]
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
