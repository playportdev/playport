// SPDX-License-Identifier: GPL-3.0-or-later
// The launch settings Settings and a game's Game options edit (PlayportKit
// LaunchSettings): one global set and one per game, by catalogue id, kept in
// UserDefaults so they outlast an uninstall. LibraryModel.play resolves them
// for each launch; they take effect from the game's next launch.

import Foundation
import HostIOKit
import PlayportKit
import SwiftUI
import UIKit

@MainActor
final class LaunchSettingsStore: ObservableObject {
    static let shared = LaunchSettingsStore()

    private static let globalKey = "launchSettings.global"
    private static let gamesKey = "launchSettings.games"

    @Published var global: LaunchSettings { didSet { save(global, Self.globalKey) } }
    @Published private var games: [String: LaunchSettings] { didSet { save(games, Self.gamesKey) } }

    private init() {
        global = Self.load(LaunchSettings.self, Self.globalKey) ?? LaunchSettings()
        games = Self.load([String: LaunchSettings].self, Self.gamesKey) ?? [:]
    }

    func settings(for id: String) -> LaunchSettings { games[id] ?? LaunchSettings() }

    /// A binding to one game's settings; a game left with nothing set is dropped.
    func binding(for id: String) -> Binding<LaunchSettings> {
        Binding(get: { self.settings(for: id) },
                set: { self.games[id] = $0.isEmpty ? nil : $0 })
    }

    func effective(for title: InstalledTitle, inheritingGraphics: Bool = false) -> LaunchSettings.Effective {
        var game = games[title.id]
        if inheritingGraphics { game?.graphics = nil }
        let arguments = (try? title.launchPlan(cohort: LibraryModel.cohort))?.args ?? []
        return LaunchSettings.resolve(game: game, global: global,
                                      importsDirect3D12: title.detectsDirect3D12, i386: title.isI386,
                                      arguments: arguments)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

/// How the pickers name a screen spec and a limit on this phone.
enum LaunchSettingsText {
    /// The presets this panel can show, largest first.
    static var screens: [String] { LaunchSettings.screenPresets.filter { size($0) != nil } }

    static var frameLimits: [Int] { LaunchSettings.frameLimits(maxRate: UIScreen.main.maximumFramesPerSecond) }

    /// `pixels` adds the size the guest gets on this phone.
    static func screen(_ spec: String?, pixels: Bool = true) -> String {
        guard let spec else { return "Native" }
        let px = pixels ? size(spec).map { " (\($0.0)×\($0.1))" } ?? "" : ""
        switch spec.lowercased() {
        case "native": return "Native" + px
        case let s where Int(s) != nil: return "\(s)p" + px
        default: return spec + px
        }
    }

    static func frameLimit(_ fps: Int) -> String { fps > 0 ? "\(fps) fps" : "Off" }

    /// The size the guest gets on this phone for a screen spec (`1600×900`).
    static func pixels(_ spec: String) -> String? { size(spec).map { "\($0.0)×\($0.1)" } }

    /// A picker's note: when a change applies.
    static let nextStart = "Takes effect the next time the game starts."

    /// A backend's line in a picker.
    static func graphicsDetail(_ g: GraphicsBackend) -> String {
        switch g {
        case .dxmt: "Direct3D 10 and 11 on Metal"
        case .vulkan: "Direct3D 8 to 12, experimental"
        }
    }

    static func graphics(_ g: GraphicsBackend) -> String {
        switch g {
        case .dxmt: "DXMT"
        case .vulkan: "Vulkan"
        }
    }

    /// A backend as a picker row: its name, and why it cannot be picked.
    @ViewBuilder
    static func graphicsRow(_ g: GraphicsBackend) -> some View {
        if Manifest.has(g) {
            Text(graphics(g))
        } else {
            Text(graphics(g) + " (not in this build)").foregroundStyle(.secondary)
        }
    }

    static func graphicsDetection(_ title: InstalledTitle) -> String {
        if title.isI386 { return "A 32-bit game: DXMT cannot run it, so the default is Vulkan." }
        guard let detection = title.direct3D, !detection.apis.isEmpty else {
            return "The game's Direct3D version could not be detected."
        }
        return "Found references to \(detection.summary). This does not identify a dual-renderer game's active API."
    }

    static let graphicsFooter = "DXMT runs Direct3D 10 and 11 on Metal. The default is Vulkan for 32-bit games and detected Direct3D 12 games, DXMT otherwise. "
        + "Vulkan runs Direct3D 8 to 11 through DXVK and Direct3D 12 through vkd3d-proton, on Mesa's "
        + "KosmicKrisp driver; it is experimental."

    static func ordering(_ s: MemoryOrdering.Setting) -> String {
        switch s {
        case .tso: "Loads and stores"
        case .halfBarrier: "Unaligned atomics"
        case .vector: "Vector loads and stores"
        case .memcpySet: "Block copies and fills"
        }
    }

    static let orderingFooter = "How closely the x86 emulator keeps the order in which x86 cores make memory "
        + "writes visible to other threads. Default is the game's profile, from Proton's settings for it. Ordering more "
        + "costs frame time; ordering less can make a multithreaded game compute wrong results or hang. Vector covers "
        + "SSE and AVX, block copies and fills cover rep movs and rep stos, and unaligned atomics are kept atomic "
        + "with half barriers. Block size is the most x86 instructions the emulator translates at once: smaller "
        + "blocks compile in shorter bursts, larger ones run with fewer jumps between blocks. Changes apply from "
        + "the game's next launch."

    static let x87Footer = "The precision at which the x86 emulator runs a game's x87 floating point. 80-bit is "
        + "exact but done in software, many instructions for each one; 64-bit uses the CPU's own and is far cheaper, "
        + "and can differ from Windows where a game relies on the extra digits. Default is the game's profile. "
        + "Changes apply from the game's next launch."

    private static func size(_ spec: String) -> (Int, Int)? {
        let px = UIScreen.main.nativeBounds.size
        return Display.guestSize(panelLong: Int(px.width), panelShort: Int(px.height), spec: spec)
    }
}
