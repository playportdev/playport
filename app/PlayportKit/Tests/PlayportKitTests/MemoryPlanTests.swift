// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import PlayportKit
import XCTest

/// Decision 0105's per-phone defaults: the tier from the phone's RAM (11,734, 7,679, 5,734 and
/// 3,662 MiB reported by the 12, 8, 6 and 4 GB phones), clamped to the app's limit L (12 GB:
/// measured, 8,191 with Game Mode and 6,144 before it; the others from the public crash ceilings)
/// when L is more than 512 MiB under the tier's G (decision 0106).
final class MemoryPlanTests: XCTestCase {
    private func plan(_ limit: Int, ram: Int = 11734, pool: Int = 0,
                      _ o: MemoryPlan.Overrides = MemoryPlan.Overrides()) -> MemoryPlan {
        MemoryPlan(MemoryPlan.Inputs(limitMB: limit, physicalMB: ram, poolMB: pool), overrides: o)
    }

    /// The owner's table (12 and 8 GB) and its extrapolation (6 and 4 GB), each at a limit
    /// that does not clamp it.
    func testPerTier() {
        // (RAM, L, tier, G, Auto pool, V)
        let table: [(Int, Int, Int, Int, Int, Int)] = [
            (11734, 8191, 12, 8192, 4096, 3072),  // 12 GB with Game Mode: L read as 8,191
            (16 * 1024, 8192, 12, 8192, 4096, 3072),  // more than 12 GB: the 12 GB row
            (7679, 6144, 8, 6144, 1024, 2048),
            (7679, 6046, 8, 6144, 1024, 2048),  // 8 GB at the public figure: the owner's row in full
            (5734, 3064, 6, 3072, 0, 1024),   // 6 GB unentitled (public figure): L within the slack
            (3662, 2090, 4, 2048, 0, 768),    // 4 GB unentitled
        ]
        for (ram, limit, gb, guest, pool, video) in table {
            let p = plan(limit, ram: ram)
            XCTAssertEqual(p.tier.ramGB, gb, "RAM \(ram)")
            XCTAssertEqual(p.tier.poolMB, pool, "RAM \(ram)")
            XCTAssertFalse(p.clamped, "RAM \(ram)")
            XCTAssertEqual(p.guestRAMMB, guest, "RAM \(ram)")
            XCTAssertEqual(p.videoMB, video, "RAM \(ram)")
            XCTAssertEqual(p.environment, ["MADEIRA_TOTAL_PHYS_MB": "\(guest)", "PLAYPORT_VRAM_MB": "\(video)"])
        }
    }

    /// The tier boundaries: 10, 7 and 5 GiB of reported RAM.
    func testTierBoundaries() {
        let tiers = [(10 * 1024, 12), (10 * 1024 - 1, 8), (7 * 1024, 8), (7 * 1024 - 1, 6),
                     (5 * 1024, 6), (5 * 1024 - 1, 4), (0, 4)]
        for (ram, gb) in tiers {
            XCTAssertEqual(MemoryPlan.Tier(physicalMB: ram).ramGB, gb, "RAM \(ram)")
        }
    }

    /// The table's V is the rule a clamped G follows: 3/8 of G rounded down to 512, at least 768.
    func testTableVideoFollowsTheRule() {
        for t in MemoryPlan.Tier.table {
            XCTAssertEqual(MemoryPlan.videoMB(guestRAMMB: t.guestRAMMB), t.videoMB, "\(t.ramGB) GB")
        }
    }

    /// A limit more than 512 MiB under the tier's G: G is L rounded down to a GiB (after 64 MiB
    /// of slack), V the lesser of the tier's and 3/8 of that G.
    func testClampToTheLimit() {
        // 12 GB before Game Mode raises the limit: 6,144.
        let g = plan(6144)
        XCTAssertTrue(g.clamped)
        XCTAssertEqual(g.guestRAMMB, 6144)
        XCTAssertEqual(g.videoMB, 2048)
        // 12 GB unentitled (3,356): 3,072 and 1,024.
        let u = plan(3356)
        XCTAssertEqual(u.guestRAMMB, 3072)
        XCTAssertEqual(u.videoMB, 1024)
        // 8 GB unentitled (3,355): 3,072 and 1,024.
        XCTAssertEqual(plan(3355, ram: 7679).guestRAMMB, 3072)
        XCTAssertEqual(plan(3355, ram: 7679).videoMB, 1024)
        // 6 GB under its tier: 2,048 and the 768 floor.
        XCTAssertEqual(plan(2500, ram: 5734).guestRAMMB, 2048)
        XCTAssertEqual(plan(2500, ram: 5734).videoMB, 768)
        // The margin: 512 MiB under the tier's G keeps the row, 513 clamps (and rounds down).
        XCTAssertFalse(plan(8192 - 512).clamped)
        XCTAssertEqual(plan(8192 - 512).guestRAMMB, 8192)
        XCTAssertTrue(plan(8192 - 513).clamped)
        XCTAssertEqual(plan(8192 - 513).guestRAMMB, 7168)
        XCTAssertEqual(plan(8192 - 513).videoMB, 2560)
        XCTAssertFalse(plan(6144 - 512, ram: 7679).clamped)
        XCTAssertEqual(plan(6144 - 513, ram: 7679).guestRAMMB, 5120)
        XCTAssertEqual(plan(6144 - 513, ram: 7679).videoMB, 1536)
        // 8 GB before Game Mode, if its limit then reads a GiB lower: clamped.
        XCTAssertEqual(plan(5120, ram: 7679).guestRAMMB, 5120)
        XCTAssertTrue(g.logLine.contains("clamp=yes planned_guest_ram_mb=6144 planned_video_mb=2048"), g.logLine)
    }

    /// A pool no longer raises the guest's RAM: G is the tier's whatever was granted.
    func testPoolDoesNotRaiseGuestRAM() {
        XCTAssertEqual(plan(8191, pool: 4096).guestRAMMB, 8192)
        XCTAssertEqual(plan(8191, pool: 4096).videoMB, 3072)
        XCTAssertEqual(plan(6144, pool: 4096).guestRAMMB, 6144)
        XCTAssertEqual(plan(6144, ram: 7679, pool: 1024).guestRAMMB, 6144)
    }

    func testOverridesWin() {
        let o = MemoryPlan.Overrides(guestRAMMB: 9216, videoMB: 1536)
        let p = plan(8191, o)
        XCTAssertEqual(p.guestRAMMB, 9216)
        XCTAssertEqual(p.videoMB, 1536)
        XCTAssertEqual(p.plannedGuestRAMMB, 8192)
        XCTAssertEqual(p.plannedVideoMB, 3072)
        XCTAssertEqual(p.environment, [:])  // the runtime reads the title's own keys
        XCTAssertEqual(plan(8191, MemoryPlan.Overrides(videoMB: 2048)).environment, ["MADEIRA_TOTAL_PHYS_MB": "8192"])
        XCTAssertEqual(plan(8191, MemoryPlan.Overrides(guestRAMMB: 4096)).environment, ["PLAYPORT_VRAM_MB": "3072"])
        XCTAssertTrue(p.logLine.contains("override=totalphys=9216,vram-mb=1536"), p.logLine)
        // An override wins over a clamped plan too.
        let c = plan(6144, MemoryPlan.Overrides(videoMB: 3072))
        XCTAssertTrue(c.clamped)
        XCTAssertEqual(c.videoMB, 3072)
        XCTAssertEqual(c.environment, ["MADEIRA_TOTAL_PHYS_MB": "6144"])
    }

    func testOverridesRead() {
        let cfg = ["totalphys": "6144", "vram-mb": " 2048 ", "vulkan-vram-plan": "1"]
        let o = MemoryPlan.Overrides.read(value: { cfg[$0] }, environment: [:])
        XCTAssertEqual(o, MemoryPlan.Overrides(guestRAMMB: 6144, videoMB: 2048, vulkan: true))
        // ml992 reads MADEIRA_TOTAL_PHYS_MB before madeira.cfg; ml1042 ignores vram-mb under 256.
        let e = MemoryPlan.Overrides.read(value: { ["totalphys": "6144", "vram-mb": "100"][$0] },
                                          environment: ["MADEIRA_TOTAL_PHYS_MB": "4096"])
        XCTAssertEqual(e, MemoryPlan.Overrides(guestRAMMB: 4096, videoMB: nil, vulkan: true))
        XCTAssertEqual(MemoryPlan.Overrides.read(value: { _ in nil }, environment: [:]), MemoryPlan.Overrides())
        // The Vulkan clamp is on unless the title sets 0.
        XCTAssertTrue(MemoryPlan.Overrides.read(value: { _ in nil }, environment: [:]).vulkan)
        XCTAssertFalse(MemoryPlan.Overrides.read(value: { ["vulkan-vram-plan": " 0 "][$0] }, environment: [:]).vulkan)
        XCTAssertTrue(MemoryPlan.Overrides.read(value: { ["vulkan-vram-plan": "1"][$0] }, environment: [:]).vulkan)
    }

    func testVulkanClampIsOnByDefault() {
        XCTAssertEqual(plan(8192).dxvkOption, "dxgi.maxDeviceMemory = 3072")
        XCTAssertEqual(plan(8192).vulkanEnvironment, ["PLAYPORT_VK_BUDGET_MB": "3072"])
        // The tier's V, and a clamped plan's.
        XCTAssertEqual(plan(6046, ram: 7679).dxvkOption, "dxgi.maxDeviceMemory = 2048")
        XCTAssertEqual(plan(6144).vulkanEnvironment, ["PLAYPORT_VK_BUDGET_MB": "2048"])
        // An explicit vram-mb wins.
        XCTAssertEqual(plan(8192, MemoryPlan.Overrides(videoMB: 2048)).dxvkOption, "dxgi.maxDeviceMemory = 2048")
        XCTAssertEqual(plan(8192, MemoryPlan.Overrides(videoMB: 2048)).vulkanEnvironment,
                       ["PLAYPORT_VK_BUDGET_MB": "2048"])
        // vulkan-vram-plan = 0 turns both off.
        XCTAssertNil(plan(8192, MemoryPlan.Overrides(vulkan: false)).dxvkOption)
        XCTAssertEqual(plan(8192, MemoryPlan.Overrides(vulkan: false)).vulkanEnvironment, [:])
        // KosmicKrisp's cap is set apart from the runtime's plan variables.
        XCTAssertNil(plan(8192).environment["PLAYPORT_VK_BUDGET_MB"])
    }

    func testUnreadLimitSetsNothing() {
        XCTAssertEqual(plan(0).environment, [:])
    }

    func testLogLine() {
        XCTAssertEqual(plan(8191, pool: 4096).logLine,
                       "tier=12GB ram_mb=11734 tier_guest_ram_mb=8192 tier_video_mb=3072 tier_pool_mb=4096 L_mb=8191 "
                       + "clamp=none planned_guest_ram_mb=8192 planned_video_mb=3072 pool_mb=4096 "
                       + "guest_ram_mb=8192 video_mb=3072 override=none vulkan_clamp=1")
    }

    func testMadeiraConfigReadsAsTheRuntime() throws {
        let text = "# c\n vram-mb = 1024\nvram-mbx = 1\ntotalphys=6144\nvram-mb = 2048 \n"
        XCTAssertEqual(MadeiraConfig.value("vram-mb", in: text), "2048")
        XCTAssertEqual(MadeiraConfig.value("totalphys", in: text), "6144")
        XCTAssertNil(MadeiraConfig.value("pool", in: text))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("3072\n".utf8).write(to: dir.appendingPathComponent("madeira-vram-mb.txt"))
        XCTAssertEqual(MadeiraConfig.value("vram-mb", directory: dir), "3072")  // legacy, no madeira.cfg
        try Data("pool = 512\n".utf8).write(to: dir.appendingPathComponent("madeira.cfg"))
        XCTAssertNil(MadeiraConfig.value("vram-mb", directory: dir))  // a madeira.cfg hides the legacy files
    }
}
