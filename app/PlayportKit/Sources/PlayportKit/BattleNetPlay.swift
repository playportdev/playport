// SPDX-License-Identifier: GPL-3.0-or-later
// Play for a Battle.net copy (PLA-514, decisions 0169 and 0170): the ban-risk notice before the
// first Play of each product, then the product's ARM64 client as a native ARM64 child of the
// x86-64 session, drawing with Direct3D 12 through ARM64 vkd3d-proton on Vulkan. World of
// Warcraft shows its own login; Playport passes it no sign-in and keeps no Battle.net
// credential or session. The app (LibraryModel.play) asks `decide`, does the step, and asks
// again with what it learned, until the step is `launch`.

import BattleNetClientKit
import Foundation

public enum BattleNetPlay {
    /// What Play knows when it decides. The update check (PLA-521) adds its result here, with a
    /// default that means not asked, so callers that do not check go on unchanged.
    public struct Facts: Equatable, Sendable {
        /// The installed copy, as adoption left it (its client's PE machine, the notice's acceptance).
        public var copy: InstalledTitle

        public init(copy: InstalledTitle) {
            self.copy = copy
        }
    }

    /// Play's next step. The gates run in this order: the notice, then (PLA-521) the update
    /// check, its space and its download, then the launch.
    public enum Step: Equatable, Sendable {
        /// The ban-risk notice (`notice(_:)`); Play starts only once the player accepts it, and the
        /// acceptance is kept with the copy (InstalledTitle.riskNoticeAccepted).
        case notice(BattleNetProduct)
        /// Play does not start; the reason is the player's.
        case refuse(String)
        case launch(Launch)
    }

    /// How the client starts. Its executable is the copy's (the receipt names the ARM64 client),
    /// which the session starts as a native ARM64 child (decision 0170): no FEX.
    public struct Launch: Equatable, Sendable {
        /// Vulkan whatever the settings say: vkd3d-proton is the ARM64 child's Direct3D 12, and
        /// DXMT has no Direct3D 12.
        public var graphics: GraphicsBackend
        /// After the receipt's arguments: WoW's own switch for its Direct3D 12 renderer, so it
        /// never falls back to Direct3D 11. No sign-in argument: WoW shows its login.
        public var arguments: [String]

        public init(graphics: GraphicsBackend, arguments: [String]) {
            self.graphics = graphics
            self.arguments = arguments
        }
    }

    /// The step for a Battle.net copy; nil for any other copy, and for a product not on the
    /// store's list.
    public static func decide(_ facts: Facts) -> Step? {
        let t = facts.copy
        guard t.store == .battlenet, let product = BattleNet.product(t.key) else { return nil }
        guard t.riskNoticeAccepted != nil else { return .notice(product) }
        guard t.executableMachine == arm64Machine else {
            return .refuse("\(product.name) starts only from its ARM64 client, and \(t.executable ?? "no client") is not it. "
                           + "Pick the ARM64 client on the game's page, or reinstall.")
        }
        return .launch(Launch(graphics: .vulkan, arguments: ["-d3d12"]))
    }

    /// The PE machine of an ARM64 Windows executable.
    static let arm64Machine: UInt16 = 0xAA64

    /// The notice the player accepts or declines, and the product page shows afterwards.
    public static func notice(_ product: BattleNetProduct) -> (title: String, text: String) {
        ("Before you play \(product.name)",
         "Blizzard does not support Playport. Blizzard may take action against your Battle.net account for playing "
         + "\(product.name) here, up to a suspension or a ban. Playport changes nothing in the game. "
         + "You sign in inside \(product.name) itself: Playport stores no Battle.net email, password or session.")
    }
}
