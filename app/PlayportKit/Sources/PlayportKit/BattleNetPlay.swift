// SPDX-License-Identifier: GPL-3.0-or-later
// Play for a Battle.net copy (PLA-514, decisions 0175 and 0177): the ban-risk notice before the
// first Play of each product, then the update check (PLA-521), which also brings the x64 client to
// an install from before 0177, then the product's x64 client through FEX on the x86-64 path,
// drawing with Direct3D 12 through vkd3d-proton (x64/arm64ec) on Vulkan. World of Warcraft shows
// its own login; Playport passes it no sign-in and keeps no Battle.net credential or session. The
// app (LibraryModel.play) asks `decide`, does the step, and asks again with what it learned, until
// the step is `launch`.

import BattleNetClientKit
import Foundation

public enum BattleNetPlay {
    /// What Play knows when it decides.
    public struct Facts: Equatable, Sendable {
        /// The installed copy, as adoption left it (its client's PE machine, the notice's acceptance).
        public var copy: InstalledTitle
        /// What the update check found; nil while it has not been asked.
        public var update: Update?
        /// The phone's free space, for an update's space check; nil when unknown.
        public var freeBytes: UInt64?

        public init(copy: InstalledTitle, update: Update? = nil, freeBytes: UInt64? = nil) {
            self.copy = copy
            self.update = update
            self.freeBytes = freeBytes
        }
    }

    /// The update check's answer: the region's version endpoint against the install's build and
    /// the install's client (BattleNetUpdateCheck).
    public enum Update: Equatable, Sendable {
        /// The install is on the region's current build, with the x64 client.
        case current
        /// A newer build, or the x64 client an install from before decision 0177 lacks (`version`
        /// is then the installed one), and the bytes its update writes (BattleNetClientKit's update plan).
        case available(version: String, bytes: UInt64)
        /// The check failed (no connection, Blizzard's servers): why, worded for the player.
        case unreachable(String)
        /// The update ran through Downloads.
        case updated
    }

    /// Play's next step. The gates run in this order: the notice, the update check with its space
    /// and its download (an install without the x64 client gets it this way), the client, then the
    /// launch.
    public enum Step: Equatable, Sendable {
        /// The ban-risk notice (`notice(_:)`); Play starts only once the player accepts it, and the
        /// acceptance is kept with the copy (InstalledTitle.riskNoticeAccepted).
        case notice(BattleNetProduct)
        /// Ask the version endpoint whether the region has a newer build than the install.
        case checkUpdate(BattleNetProduct)
        /// Update to `version` through Downloads, with its progress; Play goes on once it is done.
        case update(BattleNetProduct, version: String)
        /// Play does not start; the reason is the player's.
        case refuse(String)
        case launch(Launch)
    }

    /// How the client starts. Its executable is the copy's (the receipt names the x64 client),
    /// which the session runs through FEX like any x86-64 game (decision 0177).
    public struct Launch: Equatable, Sendable {
        /// Vulkan whatever the settings say: vkd3d-proton is the client's Direct3D 12, and DXMT
        /// has no Direct3D 12.
        public var graphics: GraphicsBackend
        /// After the receipt's arguments: WoW's own switch for its Direct3D 12 renderer (its
        /// `-d3d11` was seen to force Direct3D 11; this one is not seen on its own). What keeps
        /// WoW on Direct3D 12 is its `Config.wtf`'s `GxApi`, which Play pins to `D3D12` before every
        /// launch (BattleNetClientKit's WoWConfig): WoW saves Direct3D 11 there after one failed
        /// Direct3D 12 start. No sign-in argument: WoW shows its login.
        public var arguments: [String]
        /// What the player is told as the game starts: a failed update check, after which the
        /// installed version plays and the game itself decides whether it may.
        public var report: String?
        /// How long the launch screen waits for the first frame (or a guest window) before it
        /// uncovers the title's black screen; LaunchProgress.uncoverWithoutFrame (30 s) for other
        /// Plays. The x64 client through FEX shows its first window about 250 s after its start on
        /// the reference phone (runs 20261101T195434 and 200342), so the screen stays up to then.
        public var uncoverWithoutFrame: TimeInterval

        public init(graphics: GraphicsBackend, arguments: [String], report: String? = nil,
                    uncoverWithoutFrame: TimeInterval = BattleNetPlay.uncoverWithoutFrame) {
            self.graphics = graphics
            self.arguments = arguments
            self.report = report
            self.uncoverWithoutFrame = uncoverWithoutFrame
        }
    }

    /// A Battle.net Play's hold of the launch screen (Launch.uncoverWithoutFrame): well past the
    /// x64 client's first window on the phone; a guest window (an error box) uncovers it sooner.
    public static let uncoverWithoutFrame: TimeInterval = 600

    /// The step for a Battle.net copy; nil for any other copy, and for a product not on the
    /// store's list.
    public static func decide(_ facts: Facts) -> Step? {
        let t = facts.copy
        guard t.store == .battlenet, let product = BattleNet.product(t.key) else { return nil }
        guard t.riskNoticeAccepted != nil else { return .notice(product) }
        var report: String?
        switch facts.update {
        case nil:
            return .checkUpdate(product)
        case let .available(version, bytes):
            if let free = facts.freeBytes, let why = BattleNet.refusal(needed: BattleNet.spaceNeeded(update: bytes), free: free) {
                return .refuse("\(product.name) \(version) is out, and its update does not fit. \(why)")
            }
            return .update(product, version: version)
        case let .unreachable(why):
            guard t.executableMachine == x64Machine else {
                return .refuse("\(product.name) starts only from its x64 client, which must be downloaded first, and Blizzard's "
                               + "servers couldn't be reached: \(why)")
            }
            report = "Couldn't check for an update: \(why) \(product.name) starts the installed version."
        case .current, .updated:
            guard t.executableMachine == x64Machine else {
                return .refuse("\(product.name) starts only from its x64 client, and \(t.executable ?? "no client") is not it. "
                               + "Check for update on the game's page downloads it.")
            }
        }
        return .launch(Launch(graphics: .vulkan, arguments: ["-d3d12"], report: report))
    }

    /// The PE machine of an x86-64 Windows executable.
    static let x64Machine: UInt16 = 0x8664

    /// The notice the player accepts or declines, and the product page shows afterwards. Its sentence on
    /// the game's files and code says what decision 0177 does: Blizzard's x64 client runs through FEX,
    /// unchanged on disk and in memory.
    public static func notice(_ product: BattleNetProduct) -> (title: String, text: String) {
        ("Before you play \(product.name)",
         "Blizzard does not support Playport. Blizzard may take action against your Battle.net account for playing "
         + "\(product.name) here, up to a suspension or a ban. Playport changes none of the game's files and none of its "
         + "code in memory: it runs Blizzard's x64 Windows client through an x86-64 translator (FEX), as Windows on ARM "
         + "PCs do. You sign in inside \(product.name) itself: Playport stores no Battle.net email, password or session.")
    }
}
