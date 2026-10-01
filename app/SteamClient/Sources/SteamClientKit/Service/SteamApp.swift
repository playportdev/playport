// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One Steam app's title metadata, read from its PICS record: what the Steam
/// games tab, the title detail and a later install need. None of it is secret;
/// it is cached on disk as JSON.
public struct SteamAppInfo: Sendable, Codable, Equatable {
    public struct LaunchEntry: Sendable, Codable, Equatable {
        public var executable: String
        public var arguments: String?
        public var description: String?
        /// `config/oslist`, lowercased; empty means any OS.
        public var osList: [String]
        public var osArch: String?
        /// `type` ("default", "none", "option1", ...); nil when absent.
        public var type: String?
    }

    /// Store-asset paths as PICS gives them (`<sha1>/library_capsule.jpg`),
    /// relative to the app's directory on Steam's public asset CDN.
    public struct Art: Sendable, Codable, Equatable {
        public var capsule: String?
        public var capsule2x: String?
        public var hero: String?
        public var header: String?
    }

    public var appID: UInt32
    public var name: String
    /// `common/type` as Steam spells it ("Game", "Tool", "DLC", ...).
    public var type: String
    public var developer: String?
    public var publisher: String?
    /// `common/oslist`, lowercased; empty means Steam lists none.
    public var osList: [String]
    /// `common/osarch`: "64", "32" or nil.
    public var osArch: String?
    public var installDir: String?
    public var launch: [LaunchEntry]
    public var depots: AppDepots
    public var art: Art
    /// `common/controller_support`, lowercased ("full", "partial"); nil when
    /// Steam lists none, or the record was cached before this was read.
    public var controllerSupport: String? = nil

    public var isGame: Bool { type.caseInsensitiveCompare("game") == .orderedSame }
    public var publicBuildID: UInt32? { depots.publicBuildID }

    /// Depots a Windows install would use: Windows or any-OS content that is
    /// not a DLC, not borrowed from another app, not 32-bit only, and neither
    /// another language's nor a low-violence variant (DepotSelection's rules).
    public var windowsContentDepots: [DepotInfo] { Self.content(depots.depots) }

    static func content(_ all: [DepotInfo]) -> [DepotInfo] {
        let o = DepotSelection.Options()
        return all.filter { $0.isWindows && $0.depotFromApp == nil && $0.dlcAppID == nil && $0.osArch != "32"
            && !$0.lowViolence && ($0.language == nil || $0.language == o.language) }
    }

    /// Sum of the public manifests' sizes over `windowsContentDepots`; nil
    /// when PICS gives no size for any of them.
    public var installSize: UInt64? { installSize(branch: Branch.publicName) }

    /// The same sum over `branch`'s manifests.
    public func installSize(branch: String) -> UInt64? {
        guard let d = try? depots.onBranch(branch) else { return nil }
        let sizes = Self.content(d.depots).compactMap(\.publicManifestSize)
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    /// The Windows launch entry: an entry for Windows (or any OS) with no
    /// `type` wins over typed ones, which are alternate or tool launches.
    public var windowsLaunch: LaunchEntry? {
        let win = launch.filter { ($0.osList.isEmpty || $0.osList.contains("windows")) && $0.executable.lowercased().hasSuffix(".exe") }
        return win.first { $0.type == nil || $0.type == "default" } ?? win.first
    }

    public static func parse(appID: UInt32, _ app: KeyValue) throws -> SteamAppInfo {
        let common = app["common"]
        let config = app["config"]
        func list(_ s: String?) -> [String] {
            (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        }
        func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
        let launch = (config?["launch"]?.children ?? []).compactMap { e -> LaunchEntry? in
            guard let exe = nonEmpty(e["executable"]?.value) else { return nil }
            return LaunchEntry(executable: exe, arguments: nonEmpty(e["arguments"]?.value), description: e["description"]?.value,
                               osList: list(e.path("config", "oslist")?.value), osArch: nonEmpty(e.path("config", "osarch")?.value),
                               type: nonEmpty(e["type"]?.value))
        }
        let associations = common?["associations"]?.children ?? []
        func association(_ kind: String) -> String? {
            associations.first { $0["type"]?.value == kind }?["name"]?.value
        }
        let full = common?["library_assets_full"]
        func english(_ node: KeyValue?) -> String? {
            nonEmpty(node?["english"]?.value ?? node?.children.first?.value)
        }
        let art = Art(capsule: english(full?.path("library_capsule", "image")),
                      capsule2x: english(full?.path("library_capsule", "image2x")),
                      hero: english(full?.path("library_hero", "image")),
                      header: english(common?["header_image"]))
        return SteamAppInfo(
            appID: appID, name: common?["name"]?.value ?? "App \(appID)", type: common?["type"]?.value ?? "?",
            developer: association("developer") ?? app.path("extended", "developer")?.value,
            publisher: association("publisher") ?? app.path("extended", "publisher")?.value,
            osList: list(common?["oslist"]?.value), osArch: nonEmpty(common?["osarch"]?.value),
            installDir: nonEmpty(config?["installdir"]?.value), launch: launch,
            depots: try Library.parseDepots(appID: appID, app), art: art,
            controllerSupport: nonEmpty(common?["controller_support"]?.value)?.lowercased())
    }
}

/// One owned game in the Library. Every owned game is listed: whether it
/// runs is found at install or Play, from the installer's and the launch's
/// own errors (decision 0034 dropped the compatibility labels).
public struct SteamGame: Sendable, Codable, Equatable, Identifiable {
    public var info: SteamAppInfo
    public var id: UInt32 { info.appID }

    public init(info: SteamAppInfo) {
        self.info = info
    }

    /// Owned apps that are games, sorted by name.
    public static func games(from apps: [SteamAppInfo]) -> [SteamGame] {
        apps.filter(\.isGame)
            .map(SteamGame.init(info:))
            .sorted { $0.info.name.localizedCaseInsensitiveCompare($1.info.name) == .orderedAscending }
    }
}

/// Hashed by app ID only, which equal games share.
extension SteamGame: Hashable {
    public func hash(into h: inout Hasher) { h.combine(info.appID) }
}
