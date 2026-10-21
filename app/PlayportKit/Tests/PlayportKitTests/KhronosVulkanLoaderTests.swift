// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit

/// The Khronos Vulkan loader for a play that needs it (decision 0131): the per-game setting, the
/// compatibility table's entry for Red Dead Redemption 2, and the overlay list a launch names in
/// PLAYPORT_DLL_OVERLAY (wine_host.c, dll_overlay.h).
final class KhronosVulkanLoaderTests: XCTestCase {
    func testTheSettingIsWinesLoaderUnlessAGameOrItsCompatibilityDefaultTurnsItOn() throws {
        let global = LaunchSettings()
        XCTAssertFalse(LaunchSettings.resolve(game: nil, global: global).khronosVulkanLoader)
        XCTAssertTrue(LaunchSettings.resolve(game: LaunchSettings(khronosVulkanLoader: true), global: global).khronosVulkanLoader)
        // A person's Wine's (a dev build's row or set:) wins over the game's compatibility default; nil follows it.
        let compat = LaunchSettings(khronosVulkanLoader: true)
        XCTAssertEqual(LaunchSettings(khronosVulkanLoader: false).over(compat).khronosVulkanLoader, false)
        XCTAssertEqual(LaunchSettings().over(compat).khronosVulkanLoader, true)
        XCTAssertNil(LaunchSettings().over(nil).khronosVulkanLoader)
        XCTAssertFalse(LaunchSettings(khronosVulkanLoader: false).isEmpty)
        // Stored and read back; a record from before the setting reads as nil.
        let back = try JSONDecoder().decode(LaunchSettings.self,
                                            from: JSONEncoder().encode(LaunchSettings(khronosVulkanLoader: true)))
        XCTAssertEqual(back.khronosVulkanLoader, true)
        XCTAssertNil(try JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"screen":"720"}"#.utf8)).khronosVulkanLoader)
    }

    /// Every game's default since decision 0153 (LaunchSettings.everyGame), not the table's.
    func testEveryGameGetsItAndTheTableNamesItForNone() throws {
        let table = try CompatDefaults.load(directory: CompatDefaultsTests.shipped)
        XCTAssertNil(table.entry(for: "app-1174180")?.settings.khronosVulkanLoader)
        XCTAssertNil(table.entry(for: "epic-Buffalo")?.settings.khronosVulkanLoader)
        XCTAssertEqual(LaunchSettings.overEveryGame(nil).khronosVulkanLoader, true)
        XCTAssertEqual(LaunchSettings.overEveryGame(table.entry(for: "app-1174180")?.settings).khronosVulkanLoader, true)
    }

    func testTheOverlayListIsTheBackendsSetThenTheLoaders() {
        XCTAssertNil(GraphicsBackend.runtimeOverlays(graphics: .dxmt, khronosVulkanLoader: false))
        XCTAssertEqual(GraphicsBackend.runtimeOverlays(graphics: .vulkan, khronosVulkanLoader: false), "vulkan")
        XCTAssertEqual(GraphicsBackend.runtimeOverlays(graphics: .vulkan, khronosVulkanLoader: true), "vulkan,vulkan-loader")
        XCTAssertEqual(GraphicsBackend.runtimeOverlays(graphics: .dxmt, khronosVulkanLoader: true), "vulkan-loader")
        let rdr2 = LaunchSettings.resolve(game: LaunchSettings(graphics: .vulkan, khronosVulkanLoader: true), global: LaunchSettings())
        XCTAssertEqual(rdr2.runtimeOverlays, "vulkan,vulkan-loader")
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: LaunchSettings()).runtimeOverlays, "vulkan")   // decision 0153
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings.overEveryGame(nil), global: LaunchSettings()).runtimeOverlays,
                       "vulkan,vulkan-loader")
    }
}
