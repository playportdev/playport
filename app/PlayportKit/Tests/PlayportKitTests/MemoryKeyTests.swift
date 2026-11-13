// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit

/// One memory layout for every game (decision 0183): no compatibility entry, cohort entry, launcher
/// or every game's default carries a memory key, a key that reserves, places, commits or sizes guest
/// memory for one game.
final class MemoryKeyTests: XCTestCase {
    /// The memory keys gone so far (TitleConfig.deletedKeys) and those no title may set
    /// (TitleConfig.refusedKeys); each ticket that deletes or refuses one adds it there.
    static let memoryKeys = TitleConfig.deletedKeys.union(TitleConfig.refusedKeys)

    /// A cohort entry's own memory figure (PLA-847): no Play is refused or warned about from a stored
    /// figure. Cohort entries are read raw, since the decoder skips a key it no longer knows.
    static let cohortMemoryFigure = "memoryMB"

    /// The shipped cohort's entries as titles.json has them.
    static func shippedCohort() throws -> [[String: Any]] {
        let data = try Data(contentsOf: CompatDefaultsTests.shipped.appendingPathComponent("titles.json"))
        let file = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(file["titles"] as? [[String: Any]])
    }

    /// Where a memory key is carried, one `place: key` line each: a compatibility entry's runtime keys
    /// or graphics options, a cohort entry's config or memory figure, a launcher's runtime keys or
    /// environment, and every game's default. An environment variable counts as its `env.` key.
    static func carriers(compat: CompatDefaults, cohort: [[String: Any]], launchers: [PublisherLauncher],
                         everyGame: LaunchSettings) -> [String] {
        func keys(_ s: LaunchSettings) -> [String] {
            func names(_ line: String) -> [String] {
                LaunchSettings.splitArguments(line).map { item in item.firstIndex(of: "=").map { String(item[..<$0]) } ?? item }
            }
            return names(s.runtime) + names(s.graphicsOptions).map { "env." + $0 }
        }
        func found(_ place: String, _ keys: [String]) -> [String] {
            keys.filter(memoryKeys.contains).map { "\(place): \($0)" }
        }
        return compat.entries.keys.sorted().flatMap { found("compatibility entry \($0)", keys(compat.entries[$0]!.settings)) }
            + cohort.flatMap { title -> [String] in
                let place = "cohort entry \(title["installDir"] as? String ?? "?")"
                return found(place, ((title["config"] as? [String: String]) ?? [:]).keys.sorted())
                    + (title[cohortMemoryFigure] == nil ? [] : ["\(place): \(cohortMemoryFigure)"])
            }
            + launchers.flatMap { found("launcher \($0.id)", (Array($0.runtime.keys) + $0.graphicsEnvironment.keys.map { "env." + $0 }).sorted()) }
            + found("every game", keys(everyGame))
    }

    func testNoEntryCohortTitleLauncherOrEveryGameCarriesAMemoryKey() throws {
        let compat = try CompatDefaults.load(directory: CompatDefaultsTests.shipped)
        let cohort = try Self.shippedCohort()
        XCTAssertFalse(cohort.isEmpty)
        XCTAssertEqual(Self.carriers(compat: compat, cohort: cohort, launchers: PublisherLauncher.all,
                                     everyGame: LaunchSettings.everyGame), [])
    }

    /// The check names a planted key wherever it is. The compatibility table is built here, since
    /// loading refuses an entry whose runtime keys a launch would not take.
    func testTheCheckFindsAPlantedKey() throws {
        let compat = CompatDefaults(entries: [
            "app-1": .init(settings: LaunchSettings(runtime: "inproc-sync=1 jumbo-mb=8960"), controls: nil, reason: "Why."),
            "app-2": .init(settings: LaunchSettings(runtime: "inproc-sync=1"), controls: nil, reason: "Why.")])
        var title = try XCTUnwrap(Self.shippedCohort().first)
        title["config"] = ["cage-hold": "1", "inproc-sync": "1"]
        title[Self.cohortMemoryFigure] = 4096
        let installDir = try XCTUnwrap(title["installDir"] as? String)
        let launcher = PublisherLauncher(id: "planted", name: "Planted", installKey: "Software\\Planted", installValue: "Folder",
                                         executable: "Launcher.exe", arguments: [], windowsServices: false,
                                         graphics: .vulkan, exhaustionGrace: 0, graphicsEnvironment: [:],
                                         runtime: ["env.FEX_SMCCHECKS": "none", "short-reserve-mb": "6144"], games: [],
                                         windowSettingsFile: nil, signIn: nil)
        let everyGame = LaunchSettings(runtime: "avail-phys-cef-mb=300 jumbo-keep-mb=512 vram-mb=2048")
        XCTAssertEqual(Self.carriers(compat: compat, cohort: [title], launchers: [launcher], everyGame: everyGame),
                       ["compatibility entry app-1: jumbo-mb", "cohort entry \(installDir): cage-hold",
                        "cohort entry \(installDir): memoryMB", "launcher planted: short-reserve-mb",
                        "every game: jumbo-keep-mb", "every game: vram-mb"])
    }

    /// The configuration check refuses each deleted key wherever a launch's keys come from: a cohort
    /// entry's config, a compatibility entry, a dev build's Runtime keys row, a driven launch's TITLE_CFG.
    func testTheConfigurationCheckRefusesEachDeletedKey() {
        for key in ["jumbo-mb", "jumbo-keep-mb", "cage-hold", "short-reserve-mb"] {
            XCTAssertThrowsError(try TitleConfig.validate(["inproc-sync": "1", key: "1"]), key) {
                XCTAssertEqual($0 as? LaunchPlanError, .refusedKey(key))
            }
            XCTAssertThrowsError(try LaunchPlan.make(installDir: "G", executable: "g.exe", arguments: [], config: [key: "32768"]), key)
            XCTAssertNil(LaunchSettings.runtimeKeys("inproc-sync=1 \(key)=32768"), key)
            XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(runtime: "\(key)=32768"), global: LaunchSettings()).runtime,
                           [:], key)
            XCTAssertNil(TitleConfig.parse("\(key)=32768"), key)
            XCTAssertEqual(LaunchSettings.unusedRuntimeKeysNote("inproc-sync=1 \(key)=32768"),
                           "\(key) is no longer a key (no per-game memory keys): not used", key)
            XCTAssertThrowsError(try CompatDefaults.parse(Data(#"""
                {"titles": {"app-1": {"settings": {"runtime": "\#(key)=1"}, "reason": "Why."}}}
                """#.utf8)), key) { XCTAssertEqual($0 as? CompatDefaultsError, .badSetting("app-1.runtime")) }
        }
        XCTAssertNoThrow(try TitleConfig.validate(["inproc-sync": "1", "avail-phys-cef-mb": "300"]))
    }
}
