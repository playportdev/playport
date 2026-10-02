// SPDX-License-Identifier: GPL-3.0-or-later
// The player's launch settings (Settings tab and a game's page): the guest's
// screen, a frame rate limit, the graphics backend and, for one game, extra
// command-line arguments, which steam_api it loads, FEX's x86 memory
// ordering over the game's profile and FEX's block size (FEXProfile).
// A game's own value wins over the global one, which wins over the defaults:
// 720 rows at 60 FPS on DXMT (Vulkan for detected DX12 games; `defaultScreen`, `defaultFrameLimit`,
// GraphicsBackend.default). A cohort title's screen (LaunchPlan.screen) no
// longer sets it (decision 0034). Native and no limit are a
// choice in Settings or on a game's page. A limit of 0 runs presents free, with
// no vsync lock (TitleScreen.swift).

import Foundation
import SteamClientKit

public struct LaunchSettings: Codable, Equatable, Sendable {
    /// A screen spec (LaunchPlan.validScreen); nil inherits.
    public var screen: String?
    /// Frames per second at most; 0 for no limit, nil inherits.
    public var frameLimit: Int?
    /// Which layer runs Direct3D; nil inherits.
    public var graphics: GraphicsBackend?
    /// Added to the game's command line, after any the tested configuration
    /// gives it (per game only), as the player typed them: split by
    /// LaunchSettings.splitArguments. `-DX12`, `-force-d3d12` and the like.
    public var arguments: String
    /// The Steam API emulator or the game's own steam_api (per game only); nil
    /// is the emulator (SteamAPISwap).
    public var steamAPI: SteamAPISwap.Mode?
    /// Sync the game's saves with Steam Cloud (per game only); nil is on.
    public var cloudSync: Bool?
    /// FEX's memory ordering, each switch over the game's profile (per game
    /// only; FEXProfile.launch).
    public var ordering: MemoryOrdering
    /// The most x86 instructions FEX translates as one block (FEX `MaxInst`,
    /// per game only); nil takes the game's profile, else FEX's own 5000.
    /// FEXProfile.blockSizes are the ones offered.
    public var maxInst: Int?
    /// madeira.cfg keys over the game's own (per game only; a dev build's), as typed:
    /// `key=value` items split at spaces (`vram-mb=1024 totalphys=6144 inproc-sync=1`).
    /// LaunchSettings.runtimeKeys parses them; TitleConfig writes them after the title's.
    public var runtime: String

    public init(screen: String? = nil, frameLimit: Int? = nil, graphics: GraphicsBackend? = nil,
                arguments: String = "", steamAPI: SteamAPISwap.Mode? = nil,
                cloudSync: Bool? = nil, ordering: MemoryOrdering = MemoryOrdering(), maxInst: Int? = nil,
                runtime: String = "") {
        self.screen = screen
        self.frameLimit = frameLimit
        self.graphics = graphics
        self.arguments = arguments
        self.steamAPI = steamAPI
        self.cloudSync = cloudSync
        self.ordering = ordering
        self.maxInst = maxInst
        self.runtime = runtime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screen = try c.decodeIfPresent(String.self, forKey: .screen)
        frameLimit = try c.decodeIfPresent(Int.self, forKey: .frameLimit)
        // A backend this build does not know (saved by a newer one) inherits
        // rather than losing the rest of the settings.
        graphics = try c.decodeIfPresent(String.self, forKey: .graphics).flatMap(GraphicsBackend.init(rawValue:))
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        steamAPI = try c.decodeIfPresent(String.self, forKey: .steamAPI).flatMap(SteamAPISwap.Mode.init(rawValue:))
        cloudSync = try c.decodeIfPresent(Bool.self, forKey: .cloudSync)
        ordering = try c.decodeIfPresent(MemoryOrdering.self, forKey: .ordering) ?? MemoryOrdering()
        maxInst = try c.decodeIfPresent(Int.self, forKey: .maxInst)
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime) ?? ""
    }

    public var isEmpty: Bool {
        screen == nil && frameLimit == nil && graphics == nil
            && arguments.trimmingCharacters(in: .whitespaces).isEmpty && steamAPI == nil && cloudSync == nil
            && ordering.isEmpty && maxInst == nil
            && runtime.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Arguments as a command line splits them: at spaces, except inside
    /// double quotes, which are removed.
    public static func splitArguments(_ line: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false, any = false
        for ch in line {
            if ch == "\"" { quoted.toggle(); any = true }
            else if ch == " " && !quoted { if any { out.append(cur) }; cur = ""; any = false }
            else { cur.append(ch); any = true }
        }
        if any { out.append(cur) }
        return out
    }

    /// Runtime keys as typed (`vram-mb=1024 inproc-sync=1`): `key=value` items at spaces,
    /// a later item for a key winning. nil when an item has no `=` or TitleConfig refuses it.
    public static func runtimeKeys(_ line: String) -> [String: String]? {
        var out: [String: String] = [:]
        for item in splitArguments(line) {
            guard let eq = item.firstIndex(of: "=") else { return nil }
            out[String(item[..<eq])] = String(item[item.index(after: eq)...])
        }
        return (try? TitleConfig.validate(out)) == nil ? nil : out
    }

    /// What one launch uses.
    public struct Effective: Equatable, Sendable {
        /// nil for the panel's native pixels.
        public var screen: String?
        /// 0 for no limit.
        public var frameLimit: Int
        public var graphics: GraphicsBackend
        public var arguments: [String]
        public var steamAPI: SteamAPISwap.Mode
        /// The game's own ordering switches; FEXProfile.launch puts them over its profile.
        public var ordering: MemoryOrdering
        /// The game's own block size, nil for its profile's (FEXProfile.launch).
        public var maxInst: Int?
        /// madeira.cfg keys over the title's own (config(over:)); empty for none.
        public var runtime: [String: String]

        public init(screen: String?, frameLimit: Int, graphics: GraphicsBackend = .default,
                    arguments: [String] = [], steamAPI: SteamAPISwap.Mode = .emulated,
                    ordering: MemoryOrdering = MemoryOrdering(), maxInst: Int? = nil,
                    runtime: [String: String] = [:]) {
            self.screen = screen
            self.frameLimit = frameLimit
            self.graphics = graphics
            self.arguments = arguments
            self.steamAPI = steamAPI
            self.ordering = ordering
            self.maxInst = maxInst
            self.runtime = runtime
        }

        /// The title's madeira.cfg keys (its cohort entry's) with these over them.
        public func config(over base: [String: String]) -> [String: String] {
            base.merging(runtime) { _, own in own }
        }
    }

    /// A screen and a limit nobody set: 720 rows at 60 FPS. On the reference phone
    /// Hollow Knight holds 60 there for ten minutes at 2.8 W for the whole phone,
    /// with no thermal pressure, where native and free-running fall to 76 FPS on the
    /// E cores (docs/evidence/2026-09-29-hk-gameplay-baseline.md).
    public static let defaultScreen = "720"
    public static let defaultFrameLimit = 60

    /// The game's value, else the global one, else the defaults (720 rows,
    /// 60 FPS, Vulkan for DX12 and DXMT otherwise). Explicit graphics choices
    /// still win. `arguments` are the title's base arguments, before the player's.
    /// Invalid values are skipped as if unset.
    public static func resolve(game: LaunchSettings?, global: LaunchSettings,
                               importsDirect3D12: Bool = false, arguments: [String] = []) -> Effective {
        let screen = [game?.screen, global.screen, defaultScreen].lazy.compactMap { $0 }
            .first(where: LaunchPlan.validScreen)
        let limit = [game?.frameLimit, global.frameLimit].lazy.compactMap { $0 }.first { $0 >= 0 } ?? defaultFrameLimit
        let dx12 = Direct3D12.requested(arguments: arguments + splitArguments(game?.arguments ?? ""),
                                       imported: importsDirect3D12)
        let graphics = game?.graphics ?? global.graphics ?? (dx12 ? .vulkan : .default)
        return Effective(screen: screen, frameLimit: limit, graphics: graphics,
                         arguments: splitArguments(game?.arguments ?? ""), steamAPI: game?.steamAPI ?? .emulated,
                         ordering: game?.ordering ?? MemoryOrdering(),
                         maxInst: game?.maxInst.flatMap { FEXProfile.validBlockSize($0) ? $0 : nil },
                         runtime: runtimeKeys(game?.runtime ?? "") ?? [:])
    }

    /// The screens the pickers offer, as screen specs; the phone keeps those it can show.
    public static let screenPresets = ["native", "1080", "900", "720", "540"]

    /// The limits the pickers offer for a panel refreshing at most `maxRate` times a
    /// second: the rates that divide it evenly, so each frame stays up equally long.
    public static func frameLimits(maxRate: Int) -> [Int] {
        [30, 40, 60].filter { $0 < maxRate && maxRate % $0 == 0 }
    }
}

/// The layer that turns a game's Direct3D into Metal (decision 0014).
public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    /// DXMT: Direct3D 10 and 11 straight to Metal. What every tested game runs on.
    case dxmt
    /// DXVK (Direct3D 8 to 11) and vkd3d-proton (Direct3D 12) on Vulkan, on
    /// KosmicKrisp, Mesa's Vulkan driver on Metal.
    case vulkan

    public static let `default`: GraphicsBackend = .dxmt

    /// The directory under the runtime whose <arch>-windows builtins go
    /// before the runtime's own for this backend (WINEDLLPATH); nil for none.
    public var runtimeOverlay: String? {
        switch self {
        case .dxmt: nil
        case .vulkan: "vulkan"
        }
    }

    /// Environment this backend's launches start with.
    ///
    /// None for either backend. Vulkan started with
    /// `DXVK_CONFIG=dxvk.numCompilerThreads = 2` while the FEX host band was
    /// too full for DXVK's own compiler pool (decision 0015); with the band's
    /// leak fixed, Hollow Knight starts all of DXVK's threads with most of the
    /// band free, so DXVK picks its own count (decision 0024).
    public var runtimeEnvironment: [String: String] {
        switch self {
        case .dxmt, .vulkan: [:]
        }
    }
}
