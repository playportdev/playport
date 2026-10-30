// SPDX-License-Identifier: GPL-3.0-or-later
import PlayportKit
import XCTest

/// The tiers of .work's research-device-ram.md (PLA-351) and decision 0105: RAM per tier, the
/// app's limit L with and without the increased-memory-limit entitlement (12 GB: measured, 8,192
/// with Game Mode; the others from the public crash ceilings), jetsam's level 60 % as at a Play on the
/// reference phone (53–60 % measured) and a 700 MiB footprint (the runtime with its 512 MiB
/// JIT pool, before Wine starts).
final class DonorPoolSizingTests: XCTestCase {
    private func reading(ram: Int, limit: Int, level: Int = 60, footprint: Int = 700) -> DonorPoolSizing.Reading {
        DonorPoolSizing.Reading(availableMB: limit - footprint, footprintMB: footprint, physicalMB: ram, level: level)
    }

    private func auto(_ r: DonorPoolSizing.Reading) -> Int { DonorPoolSizing.decide(.auto, r).targetMB }

    /// Auto takes the tier's pool (decision 0105): 4,096 on 12 GB, 1,024 on 8 GB, whatever the
    /// limit; none on 6 and 4 GB, where it is not offered.
    func testAutoPerTier() {
        XCTAssertEqual(auto(reading(ram: 11734, limit: 8192)), 4096)
        XCTAssertEqual(auto(reading(ram: 11734, limit: 6144)), 4096)  // before Game Mode
        XCTAssertEqual(auto(reading(ram: 11734, limit: 3356)), 4096)  // unentitled
        XCTAssertEqual(auto(reading(ram: 16 * 1024, limit: 8192)), 4096)  // more than 12 GB
        XCTAssertEqual(auto(reading(ram: 7679, limit: 6046)), 1024)
        XCTAssertEqual(auto(reading(ram: 7679, limit: 3355)), 1024)
        for (ram, limit) in [(5734, 3064), (3662, 2090)] {
            let d = DonorPoolSizing.decide(.auto, reading(ram: ram, limit: limit))
            XCTAssertEqual(d.targetMB, 0)
            XCTAssertTrue(d.reason.hasPrefix("phone has"), d.reason)
            XCTAssertFalse(DonorPoolSizing.offered(physicalMB: ram))
        }
        XCTAssertTrue(DonorPoolSizing.offered(physicalMB: 7679))
        XCTAssertTrue(DonorPoolSizing.offered(physicalMB: 11734))
        XCTAssertFalse(DonorPoolSizing.offered(physicalMB: 7 * 1024 - 1))
    }

    func testAutoIsNotGatedOnTheLevelAtPlay() {
        // The reference phone's Play (2026-10-14): level 48, footprint 568, L 8,191.
        let r = DonorPoolSizing.Reading(availableMB: 8191 - 568, footprintMB: 568, physicalMB: 11734, level: 48)
        XCTAssertEqual(DonorPoolSizing.decide(.auto, r),
                       DonorPoolSizing.Decision(targetMB: 4096, reason: "the 12 GB tier's pool"))
        XCTAssertEqual(auto(reading(ram: 11734, limit: 8192, level: 20)), 4096)
    }

    func testAutoReasons() {
        XCTAssertEqual(DonorPoolSizing.decide(.auto, reading(ram: 7679, limit: 6046)).reason, "the 8 GB tier's pool")
        XCTAssertEqual(DonorPoolSizing.decide(.auto, reading(ram: 5734, limit: 3064)).reason,
                       "phone has 5734 MiB, the 6 GB tier has no pool")
        // No limit reported, no level, or the level at its floor: nothing.
        XCTAssertEqual(auto(DonorPoolSizing.Reading(availableMB: 0, footprintMB: 700, physicalMB: 11734, level: 60)), 0)
        XCTAssertEqual(auto(reading(ram: 11734, limit: 3356, level: -1)), 0)
        XCTAssertEqual(auto(reading(ram: 11734, limit: 3356, level: 15)), 0)
    }

    /// L, the tier and the level's cap as the log's lines print them.
    func testReadingParts() {
        let r = reading(ram: 11734, limit: 8192)
        XCTAssertEqual(r.limitMB, 8192)
        XCTAssertEqual(r.tier.ramGB, 12)
        XCTAssertEqual(r.tier.poolMB, 4096)
        XCTAssertEqual(reading(ram: 7679, limit: 6046).tier.poolMB, 1024)
        XCTAssertEqual(r.levelCapMB, 5120)
    }

    /// Growth during play: stops under the spare floor (1,408 MiB on 12 GB) or level 15 %,
    /// resumes 512 MiB over the floor, at level 20 % or on spare memory alone (0105 as amended).
    func testGrowthStopsAndResumes() {
        let ram = 11734
        XCTAssertNil(DonorPoolSizing.growthStop(spareMB: 2051, level: 40, physicalMB: ram))  // KCD's lowest
        XCTAssertNil(DonorPoolSizing.growthStop(spareMB: 1408, level: 15, physicalMB: ram))
        XCTAssertEqual(DonorPoolSizing.growthStop(spareMB: 1407, level: 40, physicalMB: ram), "spare 1407 MiB < 1408")
        XCTAssertEqual(DonorPoolSizing.growthStop(spareMB: 3000, level: 14, physicalMB: ram), "level 14% < 15%")
        XCTAssertNil(DonorPoolSizing.growthStop(spareMB: 3000, level: -1, physicalMB: ram))  // unread level: spare only
        XCTAssertEqual(DonorPoolSizing.growthStop(spareMB: 900, level: 40, physicalMB: 7679), "spare 900 MiB < 921")

        func stopped(_ spare: Int, _ level: Int) -> DonorPoolSizing.Growth {
            var g = DonorPoolSizing.Growth(physicalMB: ram)
            XCTAssertNotNil(g.check(spareMB: spare, level: level))
            XCTAssertFalse(g.growing)
            return g
        }
        XCTAssertEqual(DonorPoolSizing.Growth(physicalMB: ram).resumeSpareMB, 1920)
        var g = stopped(1407, 40)
        XCTAssertNil(g.check(spareMB: 1919, level: 40))
        XCTAssertEqual(g.check(spareMB: 1920, level: 20), .resumed("level 20% >= 20%, spare 1920 MiB >= 1920"))
        XCTAssertNil(g.spareResumeLevel)
        g = stopped(1407, 40)
        XCTAssertEqual(g.check(spareMB: 1920, level: -1), .resumed("spare 1920 MiB >= 1920, level unread"))
        g = stopped(1407, 40)
        XCTAssertEqual(g.check(spareMB: 1920, level: 19),
                       .resumed("spare 1920 MiB >= 1920, level 19% < 20%: on spare memory; the level stop now under 15%"))
        XCTAssertEqual(g.spareResumeLevel, 15)
        // a resume at 15-19 % keeps the 15 % stop as it was
        XCTAssertEqual(g.check(spareMB: 3000, level: 14), .stopped("level 14% < 15%"))
    }

    /// Run l10's pool lines (PLA-476): a resume on spare at 13 %, a stop at 12 %, a resume on
    /// spare at 17 % after the teardowns, a stop at 13 %; then level 15 % with 4,545 MiB spare at
    /// +179.63, where the pool waited for 17 %. A resume at 15-19 % counts from 15 %, so it resumes.
    func testL10ResumeOnSpareOverTheFloorCountsFromTheFloor() {
        var g = DonorPoolSizing.Growth(physicalMB: 11734)
        XCTAssertEqual(g.check(spareMB: 4238, level: 14), .stopped("level 14% < 15%"))
        XCTAssertNotNil(g.check(spareMB: 4149, level: 13))
        XCTAssertEqual(g.spareResumeLevel, 13)
        XCTAssertEqual(g.check(spareMB: 4001, level: 12),
                       .stopped("level 12% < 13%, the level at the resume on spare memory"))
        XCTAssertEqual(g.check(spareMB: 4549, level: 17),
                       .resumed("spare 4549 MiB >= 1920, level 17% < 20%: on spare memory; the level stop now under 15%"))
        XCTAssertEqual(g.spareResumeLevel, 15)
        XCTAssertEqual(g.check(spareMB: 4229, level: 13), .stopped("level 13% < 15%"))
        XCTAssertEqual(g.resumeWait(spareMB: 4261, level: 13), "level 13% < 15% (the last resume on spare memory)")
        XCTAssertNil(g.check(spareMB: 4285, level: 13))
        // +179.63: level 15 %, spare 4,545 MiB
        XCTAssertNil(g.resumeWait(spareMB: 4545, level: 15))
        XCTAssertEqual(g.check(spareMB: 4545, level: 15),
                       .resumed("spare 4545 MiB >= 1920, level 15% < 20%: on spare memory; the level stop now under 15%"))
        XCTAssertEqual(g.spareResumeLevel, 15)
        XCTAssertEqual(g.check(spareMB: 4024, level: 11), .stopped("level 11% < 15%"))
    }

    /// Run l9's pool lines (PLA-476): stopped at level 13 % with 4,105 MiB spare, resumed at 20 %,
    /// stopped at 13 % again, then 11-16 % with 4,064-4,434 MiB spare and never resumed. Under the
    /// amended rule it resumes on spare at 13 %, the level stop then counts from 13 %, and it does
    /// not flap.
    func testL9ResumesOnSpareWithoutFlapping() {
        var g = DonorPoolSizing.Growth(physicalMB: 11734)
        XCTAssertEqual(g.check(spareMB: 4105, level: 13), .stopped("level 13% < 15%"))
        XCTAssertEqual(g.check(spareMB: 4105, level: 13),
                       .resumed("spare 4105 MiB >= 1920, level 13% < 20%: on spare memory; the level stop now under 13%"))
        XCTAssertEqual(g.spareResumeLevel, 13)
        // no stop at the level it resumed at: the old rule's flap
        for _ in 0..<5 { XCTAssertNil(g.check(spareMB: 4064, level: 13)) }
        XCTAssertNil(g.check(spareMB: 4434, level: 16))
        XCTAssertNil(g.check(spareMB: 4200, level: 14))
        XCTAssertEqual(g.check(spareMB: 4200, level: 12),
                       .stopped("level 12% < 13%, the level at the resume on spare memory"))
        // the next resume on spare waits for the level to come back to 13 %
        XCTAssertEqual(g.resumeWait(spareMB: 4200, level: 11), "level 11% < 13% (the last resume on spare memory)")
        XCTAssertNil(g.check(spareMB: 4200, level: 11))
        XCTAssertNil(g.check(spareMB: 4434, level: 12))
        XCTAssertNotNil(g.check(spareMB: 4434, level: 13))
        XCTAssertTrue(g.growing)
        // the run's 20 % resume: a resume on both readings, after which 13 % stops it as before
        XCTAssertEqual(g.check(spareMB: 1900, level: 14), .stopped("level 14% < 15%, spare 1900 MiB < 1920"))
        XCTAssertEqual(g.check(spareMB: 4770, level: 20), .resumed("level 20% >= 20%, spare 4770 MiB >= 1920"))
        XCTAssertNil(g.spareResumeLevel)
        XCTAssertEqual(g.check(spareMB: 4064, level: 13), .stopped("level 13% < 15%"))
        XCTAssertNotNil(g.check(spareMB: 4064, level: 13))
        XCTAssertEqual(g.spareResumeLevel, 13)
    }

    /// The spare floor's stop holds after a resume on spare, and the stats line's `resume_wait`.
    func testGrowthSpareFloorAndResumeWait() {
        var g = DonorPoolSizing.Growth(physicalMB: 11734)
        XCTAssertNotNil(g.check(spareMB: 4059, level: 13))
        XCTAssertNotNil(g.check(spareMB: 4059, level: 13))
        XCTAssertEqual(g.check(spareMB: 1407, level: 13), .stopped("spare 1407 MiB < 1408"))
        XCTAssertEqual(g.resumeWait(spareMB: 1919, level: 13), "spare 1919 MiB < 1920")
        XCTAssertEqual(g.resumeWait(spareMB: 900, level: 12),
                       "level 12% < 13% (the last resume on spare memory), spare 900 MiB < 1920")
        XCTAssertNil(g.resumeWait(spareMB: 1920, level: 13))
        XCTAssertNil(g.resumeWait(spareMB: 1920, level: -1))
        XCTAssertNil(DonorPoolSizing.Growth(physicalMB: 11734).resumeWait(spareMB: 4059, level: 13))
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
