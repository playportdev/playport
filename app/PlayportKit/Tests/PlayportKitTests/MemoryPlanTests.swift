// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import PlayportKit
import XCTest

/// PLA-352's tiers (.work's research-device-ram.md): the app's limit L per tier, with and
/// without the increased-memory-limit entitlement (12 GB: measured, 8,192 with Game Mode and
/// 6,144 before it; the others from the public crash ceilings).
final class MemoryPlanTests: XCTestCase {
    private func plan(_ limit: Int, ram: Int = 11734, pool: Int = 0,
                      _ o: MemoryPlan.Overrides = MemoryPlan.Overrides()) -> MemoryPlan {
        MemoryPlan(MemoryPlan.Inputs(limitMB: limit, physicalMB: ram, poolMB: pool), overrides: o)
    }

    func testPerTier() {
        // (limit, RAM, guest RAM, video budget)
        let table: [(Int, Int, Int, Int)] = [
            (8192, 11734, 8192, 1536),  // 12 GB, Game Mode: what ml992 and ml1042 gave before
            (6144, 11734, 4096, 1024),  // 12 GB before Game Mode, or an 8 GB phone entitled
            (6046, 7679, 3840, 1024),   // 8 GB entitled (public figure)
            (3356, 11734, 1536, 768),   // 12 GB unentitled
            (3355, 7679, 1536, 768),    // 8 GB unentitled
            (3064, 5734, 1280, 768),    // 6 GB unentitled
            (2090, 3662, 1024, 768),    // 4 GB unentitled
            (7000, 11734, 7000, 1024),  // between: the guest keeps the limit, video at its floor
        ]
        for (limit, ram, guest, video) in table {
            let p = plan(limit, ram: ram)
            XCTAssertEqual(p.guestRAMMB, guest, "L \(limit)")
            XCTAssertEqual(p.videoMB, video, "L \(limit)")
            XCTAssertEqual(p.environment, ["MADEIRA_TOTAL_PHYS_MB": "\(guest)", "PLAYPORT_VRAM_MB": "\(video)"])
        }
    }

    func testReferencePhoneKeepsTodaysNumbers() {
        // KCD's log: "8,192 MiB physical RAM and 1,536 MiB dedicated video memory".
        let p = plan(8192)
        XCTAssertEqual(p.guestRAMMB, 8192)
        XCTAssertEqual(p.videoMB, 8192 - 4096 - 2560)
        XCTAssertGreaterThanOrEqual(plan(8191).videoMB, 1535)
    }

    /// A pool raises the guest's RAM up to the game's budget (DonorPoolSizing.gameBudgetMB, the
    /// one Auto sizes the pool from), never the video budget.
    func testPoolRaisesGuestRAMNotVideo() {
        // The reference phone: the budget (8,278) is 86 over L, under a granule: nothing.
        let r = plan(8192, pool: 4096)
        XCTAssertEqual(r.poolRaiseMB, 0)
        XCTAssertEqual(r.guestRAMMB, 8192)
        XCTAssertEqual(r.videoMB, 1536)
        // Before Game Mode (6,144): the budget leaves 2,134 -> 2,048 of a 4,096 pool.
        let g = plan(6144, pool: 4096)
        XCTAssertEqual(g.poolRaiseMB, 2048)
        XCTAssertEqual(g.guestRAMMB, 4096 + 2048)
        XCTAssertEqual(g.videoMB, 1024)
        // Unentitled 12 GB with Auto's 4,864: the budget leaves 4,922 -> 4,864, all of it.
        let u = plan(3356, pool: 4864)
        XCTAssertEqual(u.guestRAMMB, 1536 + 4864)
        XCTAssertEqual(u.videoMB, 768)
        // Unentitled 8 GB with Auto's 1,280: the budget (4,710) leaves 1,355 -> 1,280.
        XCTAssertEqual(plan(3355, ram: 7679, pool: 1280).guestRAMMB, 1536 + 1280)
        // No pool, no raise.
        XCTAssertEqual(plan(3356).poolRaiseMB, 0)
    }

    func testOverridesWin() {
        let o = MemoryPlan.Overrides(guestRAMMB: 6144, videoMB: 3072)
        let p = plan(8192, o)
        XCTAssertEqual(p.guestRAMMB, 6144)
        XCTAssertEqual(p.videoMB, 3072)
        XCTAssertEqual(p.plannedVideoMB, 1536)
        XCTAssertEqual(p.environment, [:])  // the runtime reads the title's own keys
        XCTAssertEqual(plan(8192, MemoryPlan.Overrides(videoMB: 2048)).environment, ["MADEIRA_TOTAL_PHYS_MB": "8192"])
        XCTAssertTrue(p.logLine.contains("override=totalphys=6144,vram-mb=3072"), p.logLine)
    }

    func testOverridesRead() {
        let cfg = ["totalphys": "6144", "vram-mb": " 2048 ", "vulkan-vram-plan": "1"]
        let o = MemoryPlan.Overrides.read(value: { cfg[$0] }, environment: [:])
        XCTAssertEqual(o, MemoryPlan.Overrides(guestRAMMB: 6144, videoMB: 2048, vulkan: true))
        // ml992 reads MADEIRA_TOTAL_PHYS_MB before madeira.cfg; ml1042 ignores vram-mb under 256.
        let e = MemoryPlan.Overrides.read(value: { ["totalphys": "6144", "vram-mb": "100"][$0] },
                                          environment: ["MADEIRA_TOTAL_PHYS_MB": "4096"])
        XCTAssertEqual(e, MemoryPlan.Overrides(guestRAMMB: 4096, videoMB: nil, vulkan: false))
        XCTAssertEqual(MemoryPlan.Overrides.read(value: { _ in nil }, environment: [:]), MemoryPlan.Overrides())
    }

    func testVulkanClampIsOptIn() {
        XCTAssertNil(plan(8192).dxvkOption)
        XCTAssertEqual(plan(8192, MemoryPlan.Overrides(vulkan: true)).dxvkOption, "dxgi.maxDeviceMemory = 1536")
        XCTAssertEqual(plan(8192, MemoryPlan.Overrides(videoMB: 3072, vulkan: true)).dxvkOption, "dxgi.maxDeviceMemory = 3072")
    }

    func testUnreadLimitSetsNothing() {
        XCTAssertEqual(plan(0).environment, [:])
    }

    func testLogLine() {
        XCTAssertEqual(plan(8192, pool: 0).logLine,
                       "L_mb=8192 ram_mb=11734 budget_mb=8278 pool_mb=0 guest_ram_mb=8192 video_mb=1536 "
                       + "planned_guest_ram_mb=8192 pool_raise_mb=0 planned_video_mb=1536 overhead_mb=2048 "
                       + "guest_share_mb=4096 margin_mb=512 override=none vulkan_clamp=0")
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
