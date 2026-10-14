// SPDX-License-Identifier: GPL-3.0-or-later
import PlayportKit
import XCTest

/// The tiers of .work's research-device-ram.md (PLA-351): RAM per tier, the app's limit L
/// with and without the increased-memory-limit entitlement (12 GB: measured, 8,192 with Game
/// Mode; the others from the public crash ceilings), jetsam's level 60 % as at a Play on the
/// reference phone (53–60 % measured) and a 700 MiB footprint (the runtime with its 512 MiB
/// JIT pool, before Wine starts).
final class DonorPoolSizingTests: XCTestCase {
    private func reading(ram: Int, limit: Int, level: Int = 60, footprint: Int = 700) -> DonorPoolSizing.Reading {
        DonorPoolSizing.Reading(availableMB: limit - footprint, footprintMB: footprint, physicalMB: ram, level: level)
    }

    private func auto(_ r: DonorPoolSizing.Reading) -> Int { DonorPoolSizing.decide(.auto, r).targetMB }

    /// Auto from the headroom (docs/evidence/2026-10-15-donor-pool-auto-headroom.md): the game's
    /// budget (RAM - 2,048 system reserve - the spare floor) less the app's part (min(L, 4,096)),
    /// rounded down to 256, at most 6,144, none under 1,024.
    func testAutoPerTier() {
        // 12 GB (11,734 MiB): budget 8,278. Entitled (with Game Mode or before it) the app's part
        // is 4,096: 4,182 -> 4,096. Unentitled it is L: 4,922 -> 4,864.
        XCTAssertEqual(auto(reading(ram: 11734, limit: 8192)), 4096)
        XCTAssertEqual(auto(reading(ram: 11734, limit: 6144)), 4096)  // before Game Mode
        XCTAssertEqual(auto(reading(ram: 11734, limit: 3356)), 4864)
        // 8 GB (7,679 MiB): budget 4,710. Entitled, 614 is under a GiB; unentitled, 1,355 -> 1,280.
        XCTAssertEqual(auto(reading(ram: 7679, limit: 6046)), 0)
        XCTAssertEqual(auto(reading(ram: 7679, limit: 3355)), 1280)
        // 6 and 4 GB: no pool offered (no public entitled limit; the unentitled one stands in).
        for (ram, limit) in [(5734, 3064), (3662, 2090)] {
            let d = DonorPoolSizing.decide(.auto, reading(ram: ram, limit: limit))
            XCTAssertEqual(d.targetMB, 0)
            XCTAssertTrue(d.reason.hasPrefix("phone has"), d.reason)
            XCTAssertFalse(DonorPoolSizing.offered(physicalMB: ram))
        }
        XCTAssertTrue(DonorPoolSizing.offered(physicalMB: 7679))
        XCTAssertTrue(DonorPoolSizing.offered(physicalMB: 11734))
    }

    func testAutoIsNotGatedOnTheLevelAtPlay() {
        // The reference phone's Play (2026-10-14): level 48, footprint 568, L 8,191. P - L was
        // -3,751 and Auto took nothing; from the headroom it takes 4,096.
        let r = DonorPoolSizing.Reading(availableMB: 8191 - 568, footprintMB: 568, physicalMB: 11734, level: 48)
        XCTAssertEqual(DonorPoolSizing.decide(.auto, r),
                       DonorPoolSizing.Decision(targetMB: 4096, reason: "budget 8278 MiB - app 4096 MiB = 4182"))
        XCTAssertEqual(auto(reading(ram: 11734, limit: 8192, level: 20)), 4096)
    }

    func testAutoReasons() {
        XCTAssertEqual(DonorPoolSizing.decide(.auto, reading(ram: 7679, limit: 6046)).reason,
                       "budget 4710 MiB - app 4096 MiB = 614 < 1024")
        XCTAssertEqual(DonorPoolSizing.decide(.auto, reading(ram: 11734, limit: 3356)).reason,
                       "budget 8278 MiB - app 3356 MiB = 4922")
        // A phone with more RAM: the maximum caps it.
        XCTAssertEqual(DonorPoolSizing.decide(.auto, reading(ram: 16 * 1024, limit: 8192)),
                       DonorPoolSizing.Decision(targetMB: 6144, reason: "budget 12370 MiB - app 4096 MiB = 8274, the maximum"))
        // No limit reported, no level, or the level at its floor: nothing.
        XCTAssertEqual(auto(DonorPoolSizing.Reading(availableMB: 0, footprintMB: 700, physicalMB: 11734, level: 60)), 0)
        XCTAssertEqual(auto(reading(ram: 11734, limit: 3356, level: -1)), 0)
        XCTAssertEqual(auto(reading(ram: 11734, limit: 3356, level: 15)), 0)
    }

    /// L, the budget, the app's part and the level's cap as the log's lines print them.
    func testReadingParts() {
        let r = reading(ram: 11734, limit: 8192)
        XCTAssertEqual(r.limitMB, 8192)
        XCTAssertEqual(r.budgetMB, 8278)
        XCTAssertEqual(r.appMB, 4096)
        XCTAssertEqual(reading(ram: 11734, limit: 3356).appMB, 3356)
        XCTAssertEqual(r.levelCapMB, 5120)
        XCTAssertEqual(DonorPoolSizing.gameBudgetMB(physicalMB: 7679), 4710)
        XCTAssertEqual(DonorPoolSizing.gameBudgetMB(physicalMB: 1000), 0)
    }

    /// Growth during play: stops under the spare floor (1,408 MiB on 12 GB) or level 15 %,
    /// resumes 512 MiB and 5 points above them.
    func testGrowthStopsAndResumes() {
        let ram = 11734
        XCTAssertNil(DonorPoolSizing.growthStop(spareMB: 2051, level: 40, physicalMB: ram))  // KCD's lowest
        XCTAssertNil(DonorPoolSizing.growthStop(spareMB: 1408, level: 15, physicalMB: ram))
        XCTAssertEqual(DonorPoolSizing.growthStop(spareMB: 1407, level: 40, physicalMB: ram), "spare 1407 MiB < 1408")
        XCTAssertEqual(DonorPoolSizing.growthStop(spareMB: 3000, level: 14, physicalMB: ram), "level 14% < 15%")
        XCTAssertNil(DonorPoolSizing.growthStop(spareMB: 3000, level: -1, physicalMB: ram))  // unread level: spare only
        XCTAssertEqual(DonorPoolSizing.growthStop(spareMB: 900, level: 40, physicalMB: 7679), "spare 900 MiB < 921")
        XCTAssertFalse(DonorPoolSizing.growthResumes(spareMB: 1919, level: 40, physicalMB: ram))
        XCTAssertFalse(DonorPoolSizing.growthResumes(spareMB: 1920, level: 19, physicalMB: ram))
        XCTAssertTrue(DonorPoolSizing.growthResumes(spareMB: 1920, level: 20, physicalMB: ram))
        XCTAssertTrue(DonorPoolSizing.growthResumes(spareMB: 1920, level: -1, physicalMB: ram))
    }

    /// The fixed sizes stay, capped by the level as before; off is off.
    func testFixedAndOff() {
        let r = reading(ram: 11734, limit: 8192)
        XCTAssertEqual(DonorPoolSizing.decide(.fixed(4096), r), DonorPoolSizing.Decision(targetMB: 4096, reason: "fixed 4096"))
        XCTAssertEqual(DonorPoolSizing.decide(.fixed(6144), r).targetMB, 5120)
        XCTAssertEqual(DonorPoolSizing.decide(.off, r).targetMB, 0)
        XCTAssertEqual(DonorPoolSizing.decide(.fixed(2048), reading(ram: 5734, limit: 3064)).targetMB, 0)
        XCTAssertEqual(DonorPoolSizing.decide(.fixed(4096), reading(ram: 11734, limit: 8192, level: 30)),
                       DonorPoolSizing.Decision(targetMB: 1536, reason: "fixed 4096, capped by the level"))
    }

    func testSpareFloorScalesWithRAM() {
        XCTAssertEqual(DonorPoolSizing.spareFloorMB(physicalMB: 11734), 1408)
        XCTAssertEqual(DonorPoolSizing.spareFloorMB(physicalMB: 7679), 921)
        XCTAssertEqual(DonorPoolSizing.spareFloorMB(physicalMB: 5734), 768)
        XCTAssertEqual(DonorPoolSizing.spareFloorMB(physicalMB: 3662), 768)
    }

    func testDonorGate() {
        XCTAssertNil(DonorPoolSizing.donorTooSmall(availableMB: 6137))
        XCTAssertEqual(DonorPoolSizing.donorTooSmall(availableMB: 180), "donor available 180 MiB < 1024")
    }

    /// Settings stores an Int; the driver's set: stores an Int for a number and a string otherwise.
    func testSettingFromStoredValue() {
        typealias S = DonorPoolSizing.Setting
        XCTAssertEqual(S(stored: nil), .off)
        XCTAssertEqual(S(stored: 0), .off)
        XCTAssertEqual(S(stored: -1), .auto)
        XCTAssertEqual(S(stored: "auto"), .auto)
        XCTAssertEqual(S(stored: "off"), .off)
        XCTAssertEqual(S(stored: 4096), .fixed(4096))
        XCTAssertEqual(S(stored: "2048"), .fixed(2048))
        XCTAssertEqual(S(stored: "bogus"), .off)
        XCTAssertEqual(S.auto.stored, -1)
        XCTAssertEqual(S.fixed(6144).stored, 6144)
    }
}
