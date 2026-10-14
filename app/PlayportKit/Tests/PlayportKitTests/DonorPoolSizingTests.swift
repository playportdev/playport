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

    func testAutoPerTier() {
        // 12 GB (11,734 MiB): entitled, L is above P, so no pool; unentitled, P − L is 2,624.
        XCTAssertEqual(auto(reading(ram: 11734, limit: 8192)), 0)
        XCTAssertEqual(auto(reading(ram: 11734, limit: 6144)), 0)  // before Game Mode
        XCTAssertEqual(auto(reading(ram: 11734, limit: 3356)), 3072)
        // 8 GB (7,679 MiB): entitled, L is above P; unentitled, P − L is 800, under a GiB.
        XCTAssertEqual(auto(reading(ram: 7679, limit: 6046)), 0)
        XCTAssertEqual(auto(reading(ram: 7679, limit: 3355)), 0)
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

    func testAutoReasons() {
        let entitled = DonorPoolSizing.decide(.auto, reading(ram: 11734, limit: 8192))
        XCTAssertEqual(entitled.reason, "P-L -2212 MiB < 1024")
        let unentitled = DonorPoolSizing.decide(.auto, reading(ram: 11734, limit: 3356))
        XCTAssertEqual(unentitled.reason, "P-L 2624 MiB, P-L+margin")
        // An idle phone with lots free: the maximum caps it.
        XCTAssertEqual(DonorPoolSizing.decide(.auto, reading(ram: 11734, limit: 3356, level: 95)),
                       DonorPoolSizing.Decision(targetMB: 6144, reason: "P-L 6731 MiB, the maximum"))
        // No limit reported, or no level: nothing.
        XCTAssertEqual(auto(DonorPoolSizing.Reading(availableMB: 0, footprintMB: 700, physicalMB: 11734, level: 60)), 0)
        XCTAssertEqual(auto(reading(ram: 11734, limit: 3356, level: -1)), 0)
        XCTAssertEqual(auto(reading(ram: 11734, limit: 3356, level: 15)), 0)
    }

    /// L and P as the log's auto line prints them.
    func testLimitAndPhone() {
        let r = reading(ram: 11734, limit: 8192)
        XCTAssertEqual(r.limitMB, 8192)
        XCTAssertEqual(r.phoneMB, 5280 + 700)
        XCTAssertEqual(r.levelCapMB, 5120)
    }

    /// The fixed sizes stay, capped by the level as before; off is off.
    func testFixedAndOff() {
        let r = reading(ram: 11734, limit: 8192)
        XCTAssertEqual(DonorPoolSizing.decide(.fixed(4096), r), DonorPoolSizing.Decision(targetMB: 4096, reason: "fixed 4096"))
        XCTAssertEqual(DonorPoolSizing.decide(.fixed(6144), r).targetMB, 5120)
        XCTAssertEqual(DonorPoolSizing.decide(.off, r).targetMB, 0)
        XCTAssertEqual(DonorPoolSizing.decide(.fixed(2048), reading(ram: 5734, limit: 3064)).targetMB, 0)
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
