// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A game's `steam_api.dll` / `steam_api64.dll` swapped for the Steam API
/// emulator (gbe_fork's steam_api, `Runtime/steamapi/<arch>-windows/` in the
/// app bundle; docs/plans/finished.md#steam-for-games, phase 1), and back.
///
/// Each game DLL is kept beside the emulator as `<name>.orig`, moved there by
/// one rename, and a `steam_settings/` folder written by Playport (it holds
/// `playport.txt`) goes beside it with what the emulator reports: the app ID,
/// the persona name, the SteamID64, the language and the owned DLC, and the
/// interface versions of the game's own DLL (`interfacesFile`). None of it
/// is a credential (decision 0004). The one exception is the game's encrypted
/// app ticket, a line in configs.user.ini only while the game runs
/// (`writeTicket`, `removeTickets`; decision 0017). Every step is a rename or an atomic write,
/// so a kill part-way leaves a state the next `apply` or `restore` finishes;
/// both are idempotent, and the launch applies the game's mode every time.
///
/// Verify and repair see through the swap, and through SteamStub's removal,
/// which keeps a game's executable the same way: a manifest path whose `.orig`
/// exists is checked, and repaired, as the `.orig` (`manifestFile`), and the
/// swap's own files are not reported as unlisted (`isSwapFile`).
public enum SteamAPISwap {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// The emulator answers the game's Steam API calls.
        case emulated
        /// The game's own steam_api, which needs a running Steam client.
        case original
        /// The game's own steam_api, served by Playport's steamclient64.dll in the prefix for the
        /// launched app only (decision 0115); SteamStub is still taken off, as for `emulated`.
        case client

        /// SteamStub comes off the game's executables (it stays off with Playport's client).
        public var removesSteamStub: Bool { self != .original }
    }

    /// A game DLL the swap covers, by its path under the install.
    public struct Site: Sendable, Equatable {
        public var path: String
        /// The emulator's architecture directory: `x86_64` or `i386`.
        public var arch: String
        /// The game's own DLL is kept as `<path>.orig` and the emulator is in its place.
        public var swapped: Bool
    }

    public enum State: String, Sendable, Equatable {
        /// The game has no steam_api DLL.
        case none
        case original
        case emulated
        /// Some DLLs swapped, some not (a kill part-way, or a game update).
        case mixed
    }

    /// What the emulator is told.
    public struct Settings: Sendable, Equatable {
        public var appID: UInt32
        public var personaName: String?
        public var steamID: UInt64?
        /// A Steam API language code; the depots installed are English (DepotSelection).
        public var language: String
        public var dlc: [SteamGameProfile.DLC]
        /// More steam_settings files by name: the game's achievements and stats schema (EmulatorStats).
        public var files: [String: Data] = [:]

        public init(appID: UInt32, personaName: String? = nil, steamID: UInt64? = nil, language: String = "english",
                    dlc: [SteamGameProfile.DLC] = [], files: [String: Data] = [:]) {
            self.appID = appID
            self.personaName = personaName
            self.steamID = steamID
            self.language = language
            self.dlc = dlc
            self.files = files
        }

        public init(_ p: SteamGameProfile) {
            self.init(appID: p.appID, personaName: p.personaName, steamID: p.steamID, language: p.language, dlc: p.dlc)
        }
    }

    /// Lower-case DLL name -> emulator architecture and PE machine.
    static let dlls: [String: (arch: String, machine: UInt16)] = [
        "steam_api.dll": ("i386", 0x14c),
        "steam_api64.dll": ("x86_64", 0x8664),
    ]
    public static let originalSuffix = ".orig"
    public static let settingsDirectory = "steam_settings"
    /// Inside a steam_settings folder: Playport wrote it, so restore removes it.
    static let marker = "playport.txt"

    // MARK: finding

    /// Every steam_api DLL under `root`, a game's own or already swapped.
    public static func sites(in root: URL) -> [Site] {
        let files = TitleInstaller.regularFiles(under: root)
        let present = Set(files)
        return files.compactMap { file in
            // A kept original whose DLL is gone (a kill between the rename and the copy) is a swapped site.
            let lone = isKeptOriginal(file) && !present.contains(String(file.dropLast(originalSuffix.count)))
            let path = lone ? String(file.dropLast(originalSuffix.count)) : file
            let parts = path.split(separator: "/")
            guard let name = parts.last?.lowercased(), let d = dlls[name],
                  !parts.dropLast().contains(where: { $0.lowercased() == settingsDirectory }) else { return nil }
            let swapped = lone || present.contains(path + originalSuffix)
            return Site(path: path, arch: d.arch, swapped: swapped)
        }.sorted { $0.path < $1.path }
    }

    /// The mode a launch gets for `mode` (PLA-432): Playport's Steam client is a 64-bit
    /// steamclient64.dll, which a 32-bit steam_api.dll cannot load (it asks for steamclient.dll and
    /// the game says Steam is not running), so a game whose steam_api DLLs are all 32-bit gets the
    /// emulator instead. Every other mode, and a game with no steam_api DLL, keeps its own.
    public static func launchMode(_ mode: Mode, in root: URL) -> Mode {
        guard mode == .client else { return mode }
        let s = sites(in: root)
        return !s.isEmpty && !s.contains(where: { $0.arch == "x86_64" }) ? .emulated : mode
    }

    public static func state(in root: URL) -> State {
        let s = sites(in: root)
        if s.isEmpty { return .none }
        if s.allSatisfy(\.swapped) { return .emulated }
        return s.contains(where: \.swapped) ? .mixed : .original
    }

    // MARK: apply and restore

    /// Puts the emulator in place of every steam_api DLL under `root` (each
    /// game DLL kept as `.orig`) and writes its settings beside it. `emulator`
    /// holds `<arch>-windows/<name>`. A DLL whose machine is not its name's
    /// (a 64-bit steam_api.dll) is left alone. Returns the sites swapped.
    @discardableResult
    public static func apply(in root: URL, emulator: URL, settings: Settings) throws -> [Site] {
        var done: [Site] = []
        for var site in sites(in: root) {
            let name = (site.path as NSString).lastPathComponent
            let dll = try InstallFS.resolveInside(root, site.path, createParents: false)
            let orig = URL(fileURLWithPath: dll.path + originalSuffix)
            if !site.swapped {
                guard peMachine(dll) == dlls[name.lowercased()]?.machine else { continue }
                guard rename(dll.path, orig.path) == 0 else {
                    throw SteamError.transport("cannot keep \(site.path) as \(name)\(originalSuffix) (errno \(errno))")
                }
                site.swapped = true
            }
            let source = emulator.appendingPathComponent("\(site.arch)-windows/\(name.lowercased())")
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw SteamError.notFound("the Steam API emulator for \(site.arch) is not in the app")
            }
            if InstallFS.sha256(dll) != InstallFS.sha256(source) {
                try InstallFS.writeAtomically(dll, Data(contentsOf: source))
            }
            try writeSettings(beside: dll.deletingLastPathComponent(), settings, gameDLL: orig)
            done.append(site)
        }
        return done
    }

    /// Puts every game DLL back (`.orig` renamed over the emulator) and removes
    /// the settings Playport wrote. Returns how many DLLs were restored.
    @discardableResult
    public static func restore(in root: URL) throws -> Int {
        var n = 0
        for site in sites(in: root) where site.swapped {
            let dll = try InstallFS.resolveInside(root, site.path, createParents: false)
            guard rename(dll.path + originalSuffix, dll.path) == 0 else {
                throw SteamError.transport("cannot restore \(site.path) (errno \(errno))")
            }
            n += 1
        }
        for dir in settingsFolders(in: root) { try FileManager.default.removeItem(at: dir) }
        return n
    }

    /// The mode's state: the emulator in place and its settings current, or the game's own DLLs.
    @discardableResult
    public static func ensure(_ mode: Mode, in root: URL, emulator: URL, settings: Settings) throws -> State {
        switch mode {
        case .emulated: try apply(in: root, emulator: emulator, settings: settings)
        case .original, .client: try restore(in: root)
        }
        return state(in: root)
    }

    // MARK: verify and repair

    /// The file that holds a manifest path's content: its `.orig` when the swap
    /// moved the game's DLL there.
    public static func manifestFile(_ root: URL, _ path: String) -> String {
        guard let name = path.split(separator: "/").last?.lowercased(), dlls[name] != nil || name.hasSuffix(".exe"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(path + originalSuffix).path) else { return path }
        return path + originalSuffix
    }

    /// A file the swap made, which no manifest lists: a kept `.orig`, or a file
    /// in a steam_settings folder Playport wrote.
    public static func isSwapFile(_ root: URL, _ path: String) -> Bool {
        if isKeptOriginal(path) { return true }
        // An executable SteamStub removal kept, beside the unwrapped copy.
        if path.lowercased().hasSuffix(".exe" + originalSuffix),
           FileManager.default.fileExists(atPath: root.appendingPathComponent(String(path.dropLast(originalSuffix.count))).path) {
            return true
        }
        let parts = path.split(separator: "/")
        guard let i = parts.dropLast().lastIndex(where: { $0.lowercased() == settingsDirectory }) else { return false }
        let dir = parts[...i].joined(separator: "/")
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("\(dir)/\(marker)").path)
    }

    static func isKeptOriginal(_ path: String) -> Bool {
        let lower = path.lowercased()
        guard lower.hasSuffix(originalSuffix) else { return false }
        let name = String(lower.dropLast(originalSuffix.count)).split(separator: "/").last.map(String.init) ?? ""
        return dlls[name] != nil
    }

    // MARK: the emulator's settings

    /// The files of a steam_settings folder (gbe_fork's formats), by name.
    public static func settingsFiles(_ s: Settings) -> [String: String] {
        var user = "[user::general]\n"
        if let n = s.personaName.map(iniValue), !n.isEmpty { user += "account_name=\(n)\n" }
        if let id = s.steamID { user += "account_steamid=\(id)\n" }
        user += "language=\(iniValue(s.language))\n"
        var app = "[app::dlcs]\nunlock_all=0\n"
        for d in s.dlc.sorted(by: { $0.appID < $1.appID }) { app += "\(d.appID)=\(iniValue(d.name))\n" }
        // No LAN: the emulator would broadcast and listen for peers, which asks
        // iOS for local network access in the middle of a game.
        let main = "[main::connectivity]\ndisable_networking=1\n"
        return [
            "steam_appid.txt": "\(s.appID)\n",
            "configs.user.ini": user,
            "configs.app.ini": app,
            "configs.main.ini": main,
            marker: "Written by Playport for the Steam API emulator; Playport removes this folder when it restores the game's own steam_api.\n",
        ]
    }

    static func writeSettings(beside dir: URL, _ s: Settings, gameDLL: URL) throws {
        let folder = dir.appendingPathComponent(settingsDirectory, isDirectory: true)
        try InstallFS.makeDirectory(folder)
        var files = settingsFiles(s).mapValues { Data($0.utf8) }
        files.merge(s.files) { a, _ in a }
        // One given in the settings, or one already in the folder, is left as it is.
        if files[interfacesFile] == nil,
           !FileManager.default.fileExists(atPath: folder.appendingPathComponent(interfacesFile).path),
           let game = try? Data(contentsOf: gameDLL), let text = interfacesText(game) {
            files[interfacesFile] = Data(text.utf8)
        }
        for (name, data) in files {
            let url = folder.appendingPathComponent(name)
            if (try? Data(contentsOf: url)) != data { try InstallFS.writeAtomically(url, data) }
        }
    }

    // MARK: the game's interface versions

    /// gbe_fork's list of the interface versions the game's own steam_api
    /// hands out from its exported accessors (`SteamUser()`, `SteamClient()`
    /// and the rest, which games built with an older SDK call). Without
    /// it the emulator's accessors return its newest interfaces, and a game
    /// calls their methods with the arguments of its own SDK: Kingdom Come's
    /// GetAuthSessionTicket through SteamUser023's slot, whose fourth argument
    /// it never passes (PLA-350).
    public static let interfacesFile = "steam_interfaces.txt"

    /// gbe_fork's tools/generate_interfaces at the gbe pin, in its order: a
    /// name and whether it is followed by digits (`\d+`).
    static let interfacePatterns: [(name: String, digits: Bool)] = [
        ("STEAMAPPS_INTERFACE_VERSION", true), ("SteamApps", true), ("STEAMAPPLIST_INTERFACE_VERSION", true),
        ("STEAMAPPTICKET_INTERFACE_VERSION", true), ("SteamClient", true),
        ("STEAMCONTROLLER_INTERFACE_VERSION", false), ("SteamController", true),
        ("SteamFriends", true),
        ("SteamGameServerStats", true), ("SteamGameCoordinator", true), ("SteamGameServer", true),
        ("STEAMHTMLSURFACE_INTERFACE_VERSION_", true), ("STEAMHTTP_INTERFACE_VERSION", true),
        ("SteamInput", true), ("STEAMINVENTORY_INTERFACE_V", true),
        ("SteamMatchMakingServers", true), ("SteamMatchMaking", true), ("SteamMatchGameSearch", true),
        ("SteamParties", true),
        ("STEAMMUSIC_INTERFACE_VERSION", true), ("STEAMMUSICREMOTE_INTERFACE_VERSION", true),
        ("SteamNetworkingMessages", true), ("SteamNetworkingSockets", true), ("SteamNetworkingUtils", true),
        ("SteamNetworking", true),
        ("STEAMPARENTALSETTINGS_INTERFACE_VERSION", true), ("STEAMREMOTEPLAY_INTERFACE_VERSION", true),
        ("STEAMREMOTESTORAGE_INTERFACE_VERSION", true), ("STEAMSCREENSHOTS_INTERFACE_VERSION", true),
        ("STEAMTIMELINE_INTERFACE_V", true), ("STEAMUGC_INTERFACE_VERSION", true),
        ("SteamUser", true), ("STEAMUSERSTATS_INTERFACE_VERSION", true),
        ("SteamUtils", true),
        ("STEAMVIDEO_INTERFACE_V", true),
        ("STEAMUNIFIEDMESSAGES_INTERFACE_VERSION", true),
        ("SteamMasterServerUpdater", true),
    ]

    /// The interface versions in a game's steam_api DLL, as generate_interfaces
    /// writes them: each pattern's matches in file order, a line each. A DLL
    /// that also names SteamClient017 keeps only that SteamClient (newer SDKs
    /// export only SteamClient(), which returns it). Nil when it names none.
    public static func interfacesText(_ dll: Data) -> String? {
        let bytes = [UInt8](dll)
        var lines: [String] = []
        for p in interfacePatterns {
            var found = matches(of: Array(p.name.utf8), digits: p.digits, in: bytes)
            if p.name == "SteamClient", found.count > 1, found.contains("SteamClient017") {
                found = found.filter { $0 == "SteamClient017" }
            }
            lines += found
        }
        return lines.isEmpty ? nil : lines.map { $0 + "\n" }.joined()
    }

    /// Every `name` (followed by one or more ASCII digits, when `digits`) in `bytes`, in order.
    static func matches(of name: [UInt8], digits: Bool, in bytes: [UInt8]) -> [String] {
        var found: [String] = []
        var i = 0
        while i + name.count <= bytes.count {
            guard bytes[i] == name[0], bytes[i..<i + name.count].elementsEqual(name) else { i += 1; continue }
            var end = i + name.count
            if digits {
                while end < bytes.count, (0x30...0x39).contains(bytes[end]) { end += 1 }
                guard end > i + name.count else { i += 1; continue }
            }
            found.append(String(decoding: bytes[i..<end], as: UTF8.self))
            i = end
        }
        return found
    }

    // MARK: the encrypted app ticket (decision 0017)

    /// gbe_fork's key for the ticket, in configs.user.ini's `[user::general]`
    /// (settings_parser.cpp parse_encrypted_app_ticket at the gbe pin): the
    /// base64 of the bytes GetEncryptedAppTicket returns.
    public static let ticketKey = "ticket"
    static let userConfig = "configs.user.ini"
    static let userSection = "[user::general]"

    /// Adds the `ticket=<base64>` line to every configs.user.ini in a
    /// steam_settings folder Playport wrote under `root`, after `apply` wrote
    /// them and before the runtime starts; any older ticket line goes. Returns
    /// how many files hold it.
    @discardableResult
    public static func writeTicket(_ ticket: Secret<[UInt8]>, in root: URL) throws -> Int {
        let line = "\(ticketKey)=\(Data(ticket.value).base64EncodedString())"
        var n = 0
        for folder in settingsFolders(in: root) {
            let url = folder.appendingPathComponent(userConfig)
            var lines = withoutTicket(String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self))
            if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == userSection }) {
                lines.insert(line, at: i + 1)
            } else {
                lines = [userSection, line] + lines
            }
            try InstallFS.writeAtomically(url, Data((lines.joined(separator: "\n") + "\n").utf8))
            n += 1
        }
        return n
    }

    /// Takes the ticket line out of every configs.user.ini in a steam_settings
    /// folder Playport wrote under `root`, and any temporary file a kill
    /// part-way through a write left beside one. At the game's exit, at the
    /// next launch and app start, and at sign-out. Returns how many files held
    /// a ticket.
    @discardableResult
    public static func removeTickets(in root: URL) throws -> Int {
        var n = 0
        for folder in settingsFolders(in: root) {
            let tmp = folder.appendingPathComponent(".\(userConfig).tmp")
            if FileManager.default.fileExists(atPath: tmp.path) {
                try FileManager.default.removeItem(at: tmp)
                n += 1
            }
            let url = folder.appendingPathComponent(userConfig)
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let kept = withoutTicket(text)
            guard kept.count != text.split(separator: "\n", omittingEmptySubsequences: true).count else { continue }
            try InstallFS.writeAtomically(url, Data((kept.joined(separator: "\n") + "\n").utf8))
            n += 1
        }
        return n
    }

    /// The lines of an ini file without its ticket lines (and without blank lines).
    static func withoutTicket(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { l in
            let key = l.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            return key != ticketKey
        }
    }

    static func settingsFolders(in root: URL) -> [URL] {
        let markers = TitleInstaller.regularFiles(under: root).filter { p in
            let parts = p.split(separator: "/")
            return parts.count >= 2 && parts.last == Substring(marker) && parts[parts.count - 2].lowercased() == settingsDirectory
        }
        return markers.map { root.appendingPathComponent($0).deletingLastPathComponent() }
    }

    /// One line, no section syntax: an ini value gbe_fork reads back as written.
    static func iniValue(_ s: String) -> String {
        String(s.map { $0.isNewline ? " " : $0 }).trimmingCharacters(in: .whitespaces)
    }

    /// The COFF machine of a PE file, nil when it is not one (also a title's
    /// executable on adoption: InstalledTitle.executableMachine).
    public static func peMachine(_ url: URL) -> UInt16? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let dos = try? h.read(upToCount: 0x40), dos.count == 0x40, dos.prefix(2) == Data("MZ".utf8) else { return nil }
        let off = dos[0x3c..<0x40].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        guard (try? h.seek(toOffset: off)) != nil, let pe = try? h.read(upToCount: 6), pe.count == 6,
              pe.prefix(4) == Data([0x50, 0x45, 0, 0]) else { return nil }
        return UInt16(pe[pe.startIndex + 4]) | UInt16(pe[pe.startIndex + 5]) << 8
    }
}

/// What a game's Steam API emulator is told about the player, fetched while
/// the account's session is up and kept for the launch (the session is closed
/// before the runtime starts, decision 0004). None of it is a credential: the
/// persona name (never the account name), the SteamID64, the language and the
/// DLC the account owns.
public struct SteamGameProfile: Codable, Sendable, Equatable {
    public struct DLC: Codable, Sendable, Equatable {
        public var appID: UInt32
        public var name: String
        public init(appID: UInt32, name: String) {
            self.appID = appID
            self.name = name
        }
    }

    public var appID: UInt32
    public var personaName: String?
    public var steamID: UInt64
    public var language: String
    public var dlc: [DLC]
    public var fetchedAt: Date

    public init(appID: UInt32, personaName: String?, steamID: UInt64, language: String = "english", dlc: [DLC], fetchedAt: Date) {
        self.appID = appID
        self.personaName = personaName
        self.steamID = steamID
        self.language = language
        self.dlc = dlc
        self.fetchedAt = fetchedAt
    }

    /// The DLC of `app` (PICS `extended/listofdlc`) that `owned` includes.
    public static func ownedDLC(app: KeyValue, owned: Set<UInt32>) -> [UInt32] {
        let list = app.path("extended", "listofdlc")?.value ?? ""
        return list.split(separator: ",").compactMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { owned.contains($0) }.sorted()
    }
}
