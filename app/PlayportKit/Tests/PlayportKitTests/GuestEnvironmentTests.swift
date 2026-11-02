// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit
import SteamClientKit

/// A play's per-title guest variables (an Xbox copy's bridge port and key, decision 0180)
/// reach the game's own environment only, and their values never reach the log.
final class GuestEnvironmentTests: XCTestCase {
    private let key = String(repeating: "k3", count: 32)
    private var guest: [String: Secret<String>] {
        ["XODUS_BRIDGE_PORT": Secret("50123"), "XODUS_BRIDGE_KEY": Secret(key)]
    }
    private let launch = ["DXVK_HUD": "0", "SteamAppId": "367520", "FEX_HOSTFEATURES": "enableavx"]

    func testTheGameGetsTheGuestVariablesOverTheLaunchsAndPrerequisitesKeepTheLaunchsAlone() {
        let prerequisites = launch
        let game = GuestEnvironment.title(launch, guest: guest)
        XCTAssertEqual(game, ["DXVK_HUD": "0", "SteamAppId": "367520", "FEX_HOSTFEATURES": "enableavx",
                              "XODUS_BRIDGE_PORT": "50123", "XODUS_BRIDGE_KEY": key])
        XCTAssertNil(prerequisites["XODUS_BRIDGE_KEY"])
        XCTAssertNil(prerequisites["XODUS_BRIDGE_PORT"])
        // A play's own variable wins over a launch variable of the same name.
        XCTAssertEqual(GuestEnvironment.title(["XODUS_BRIDGE_PORT": "1"], guest: guest)["XODUS_BRIDGE_PORT"], "50123")
        XCTAssertEqual(GuestEnvironment.title(launch, guest: [:]), launch, "no guest variables: the launch's as they are")
    }

    func testTheLogNamesTheGuestVariablesAndNeverTheirValues() {
        let line = GuestEnvironment.logLine(guest)
        XCTAssertEqual(line, "environment: the play's own XODUS_BRIDGE_KEY, XODUS_BRIDGE_PORT (values not logged)")
        XCTAssertFalse(line?.contains(key) ?? true)
        XCTAssertFalse(line?.contains("50123") ?? true)
        XCTAssertNil(GuestEnvironment.logLine([:]))
    }
}
