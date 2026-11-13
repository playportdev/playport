// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit

/// One memory layout for every game (decision 0183): no compatibility entry, cohort entry, launcher
/// or every game's default carries a memory key, a key that reserves, places, commits or sizes guest
/// memory for one game.
final class MemoryKeyTests: XCTestCase {
    /// The memory keys gone so far; each ticket that deletes one adds it here.
    static let memoryKeys = TitleConfig.deletedKeys

    /// Where a memory key is carried, one `place: key` line each: a compatibility entry's runtime keys
    /// or graphics options, a cohort entry's config, a launcher's runtime keys or environment, and
    /// every game's default. An environment variable counts as its `env.` key.
    static func carriers(compat: CompatDefaults, cohort: Cohort, launchers: [PublisherLauncher],
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
            + cohort.titles.flatMap { found("cohort entry \($0.installDir)", ($0.config ?? [:]).keys.sorted()) }
            + launchers.flatMap { found("launcher \($0.id)", (Array($0.runtime.keys) + $0.graphicsEnvironment.keys.map { "env." + $0 }).sorted()) }
            + found("every game", keys(everyGame))
    }

    func testNoEntryCohortTitleLauncherOrEveryGameCarriesAMemoryKey() throws {
        let compat = try CompatDefaults.load(directory: CompatDefaultsTests.shipped)
        let cohort = try Cohort.load(directory: CompatDefaultsTests.shipped)
        XCTAssertEqual(Self.carriers(compat: compat, cohort: cohort, launchers: PublisherLauncher.all,
                                     everyGame: LaunchSettings.everyGame), [])
    }

    /// The check names a planted key wherever it is.
    func testTheCheckFindsAPlantedKey() throws {
        let compat = try CompatDefaults.parse(Data(#"""
            {"titles": {"app-1": {"settings": {"runtime": "inproc-sync=1 jumbo-mb=8960"}, "reason": "Why."},
                        "app-2": {"settings": {"runtime": "inproc-sync=1"}, "reason": "Why."}}}
            """#.utf8))
        var title = try XCTUnwrap(Cohort.load(directory: CompatDefaultsTests.shipped).titles.first)
        title.config = ["cage-hold": "1", "inproc-sync": "1"]
        let launcher = PublisherLauncher(id: "planted", name: "Planted", installKey: "Software\\Planted", installValue: "Folder",
                                         executable: "Launcher.exe", arguments: [], windowsServices: false, jitPoolMB: nil,
                                         graphics: .vulkan, exhaustionGrace: 0, graphicsEnvironment: [:],
                                         runtime: ["env.FEX_SMCCHECKS": "none", "short-reserve-mb": "6144"], games: [],
                                         windowSettingsFile: nil, signIn: nil)
        let everyGame = LaunchSettings(runtime: "avail-phys-cef-mb=300 jumbo-keep-mb=512")
        XCTAssertEqual(Self.carriers(compat: compat, cohort: Cohort(titles: [title]), launchers: [launcher], everyGame: everyGame),
                       ["compatibility entry app-1: jumbo-mb", "cohort entry \(title.installDir): cage-hold",
                        "launcher planted: short-reserve-mb", "every game: jumbo-keep-mb"])
    }

    /// The configuration check refuses each deleted key wherever a launch's keys come from: a cohort
    /// entry's config, a dev build's Runtime keys row, a driven launch's TITLE_CFG.
    func testTheConfigurationCheckRefusesEachDeletedKey() {
        for key in ["jumbo-mb", "jumbo-keep-mb", "cage-hold", "short-reserve-mb"] {
            XCTAssertThrowsError(try TitleConfig.validate(["inproc-sync": "1", key: "1"]), key) {
                XCTAssertEqual($0 as? LaunchPlanError, .deletedKey(key))
            }
            XCTAssertThrowsError(try LaunchPlan.make(installDir: "G", executable: "g.exe", arguments: [], config: [key: "32768"]), key)
            XCTAssertNil(LaunchSettings.runtimeKeys("inproc-sync=1 \(key)=32768"), key)
            XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(runtime: "\(key)=32768"), global: LaunchSettings()).runtime,
                           [:], key)
            XCTAssertNil(TitleConfig.parse("\(key)=32768"), key)
        }
        XCTAssertNoThrow(try TitleConfig.validate(["inproc-sync": "1", "avail-phys-cef-mb": "300"]))
    }
}
