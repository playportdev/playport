// SPDX-License-Identifier: GPL-3.0-or-later
// An installed Xbox copy's DLC and add-ons (PLA-502), dev app only (decision 0179).
// XboxClientKit's XboxAddOnFinder finds them (the public catalogue, the game's config
// and the account's licensed non-game products the library keeps); XboxInstaller
// installs one through the copy's own path into the game's folder (`DLC\<ProductId>`).
// The game page's Add-ons button lists them to install or remove. A Play passes the
// runtime its add-ons (`NEXUS_RELATED_PRODUCT_IDS`, `XODUS_CONTENT_ROOTS`), the
// package's language (`XODUS_PACKAGE_LOCALE`) and lets the bridge mint their licence
// token; Microsoft's signed token decides what the game unlocks.

import Combine
import ContentKit
import Foundation
import PlayportKit
import XboxClientKit

@MainActor
final class XboxGameAddOns: ObservableObject {
    static let shared = XboxGameAddOns()
    /// Each game's add-ons as last found, by the game's Product ID; kept so a Play has them offline.
    @Published private(set) var found: [String: [XboxAddOn]] = [:]
    @Published private(set) var finding: Set<String> = []
    /// The add-on installing or being removed now, and its share done (0…1).
    @Published private(set) var busy: (id: String, done: Double)?
    /// The last failure, by add-on (or game, for finding), until it is tried again.
    @Published private(set) var errors: [String: String] = [:]
    nonisolated static let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Playport/xbox/addons.json")
    private var watch: AnyCancellable?

    private init() {
        if let data = try? Data(contentsOf: Self.cache) { found = (try? JSONDecoder().decode([String: [XboxAddOn]].self, from: data)) ?? [:] }
        // What the account licenses goes with its sign-out, as the library's list does.
        watch = XboxAccount.shared.$state.removeDuplicates().sink { [weak self] state in
            guard state == .signedOut, let self else { return }
            found = [:]; errors = [:]
            try? FileManager.default.removeItem(at: Self.cache)
        }
    }

    private var installer: XboxInstaller { XboxInstalls.shared.installer }
    private func folder(_ base: String) -> URL? {
        installer.loadRecord(base).map { LibraryModel.paths.games.appendingPathComponent($0.installDir, isDirectory: true) }
    }

    func installed(_ base: String) -> [XboxInstalledAddOn] { installer.addOnRecords(base: base) }

    /// Finds the game's add-ons again; nil, or why not.
    @discardableResult
    func refresh(_ base: String) async -> String? {
        guard XboxAccount.shared.state == .signedIn else { return "Sign in to Xbox to find this game's add-ons." }
        guard !finding.contains(base) else { return nil }
        finding.insert(base)
        defer { finding.remove(base) }
        let games = XboxGames.shared
        if games.snapshot?.access == nil { await games.refresh() }
        guard let snapshot = games.snapshot else { return games.error ?? "The Xbox library can't be loaded. Try again." }
        // The account's licensed products that are no game (a game is no add-on).
        let licensed = (snapshot.access ?? [:]).filter { id, _ in
            id != base && (snapshot.products[id].map { $0.delivery == .notAGame } ?? true)
        }
        let config = folder(base).flatMap { try? XboxPackageConfig.load(folder: $0) }
        let finder = XboxAddOnFinder(log: XboxInstalls.log, market: XboxMarket.current)
        do {
            let list = try await finder.addOns(of: base, config: config, licensed: licensed)
            guard XboxAccount.shared.state == .signedIn else { return nil }
            found[base] = list; errors[base] = nil
            try? FileManager.default.createDirectory(at: Self.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(found).write(to: Self.cache, options: .atomic)
            return nil
        } catch {
            let why = XboxInstalls.message(error)
            errors[base] = why
            return why
        }
    }

    /// Installs `addOn` into the game `base`'s folder; nil, or why not.
    @discardableResult
    func install(_ addOn: XboxAddOn, base: String) async -> String? {
        guard busy == nil else { return "Another add-on is installing." }
        guard XboxAccount.shared.state == .signedIn else { return "Sign in to Xbox to install add-ons." }
        guard addOn.status == .available, let package = addOn.package else { return "This add-on has nothing to install." }
        busy = (addOn.id, 0); errors[addOn.id] = nil
        defer { busy = nil }
        var options = InstallEngine.Options()
        options.progressInterval = 0.5
        let installer = self.installer, id = addOn.id
        do {
            let r = try await installer.installAddOn(id, contentID: package.contentID, base: base, options: options) { p in
                let done = p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : 0
                Task { @MainActor in if XboxGameAddOns.shared.busy?.id == id { XboxGameAddOns.shared.busy = (id, done) } }
            }
            XboxInstalls.log.info("xbox", "xbox-\(base): add-on \(id) \(r.installed.version) installed, \(r.installed.files.count) files")
            return nil
        } catch {
            let why = XboxInstalls.message(error)
            errors[id] = why
            XboxInstalls.log.info("xbox", "xbox-\(base): add-on \(id) not installed: \(why)")
            return why
        }
    }

    /// Removes the installed add-on `id` of the game `base`; nil, or why not.
    @discardableResult
    func remove(_ id: String, base: String) async -> String? {
        guard busy == nil else { return "Another add-on is installing." }
        busy = (id, 0)
        defer { busy = nil }
        let installer = self.installer
        do {
            try await Task.detached(priority: .userInitiated) { try installer.removeAddOn(id, base: base) }.value
            errors[id] = nil
            return nil
        } catch {
            let why = XboxInstalls.message(error)
            errors[id] = why
            return why
        }
    }

    /// What a Play of the game in `folder` passes on: the add-ons the bridge may mint a
    /// licence token for, and the runtime's variables.
    nonisolated static func play(base: String, folder: URL, found: [XboxAddOn], installer: XboxInstaller)
        -> (related: [String], environment: [String: Secret<String>]) {
        let installed = installer.addOnRecords(base: base).map(\.installed.productID)
        let related = installed + found.map(\.id).filter { !installed.contains($0) }
        let languages = (try? XboxPackageConfig.load(folder: folder))?.languages ?? []
        let locale = XboxAddOnEnvironment.locale(preferred: Locale.preferredLanguages, declared: languages)
        let env = XboxAddOnEnvironment.values(base: base, related: related, contentRoots: installer.addOnRoots(base: base), locale: locale)
        XboxInstalls.log.info("xbox", "xbox-\(base): add-ons for the play: \(installed.count) installed, \(related.count) named to the runtime"
                              + (env["XODUS_CONTENT_ROOTS"] == nil ? "" : ", content root set")
                              + (env["XODUS_PACKAGE_LOCALE"].map { ", locale \($0.value)" } ?? ""))
        return (related, env)
    }

    // MARK: the game page

    /// The page's button: Add-ons, or what is happening to one.
    func title(_ base: String) -> String {
        if let busy, found[base]?.contains(where: { $0.id == busy.id }) ?? installed(base).contains(where: { $0.installed.productID == busy.id }) {
            return busy.done > 0 ? "Add-ons · \(Int(busy.done * 100))%" : "Add-ons · working"
        }
        if finding.contains(base) { return "Add-ons · finding" }
        let count = installed(base).count
        return count > 0 ? "Add-ons · \(count)" : "Add-ons"
    }

    /// The page's picker: each add-on with what can be done (Install, Remove), found again first when never found.
    func open(_ t: InstalledTitle) {
        let base = t.key.id
        Task {
            if found[base] == nil { await refresh(base) }
            show(t)
        }
    }

    private func show(_ t: InstalledTitle) {
        let base = t.key.id
        let installed = Dictionary(uniqueKeysWithValues: installed(base).map { ($0.installed.productID, $0.installed) })
        var options: [PadOption] = []
        for a in found[base] ?? [] {
            let why = errors[a.id].map { " · " + $0 }
            if installed[a.id] != nil {
                options.append(PadOption(id: "remove:" + a.id, label: a.title, detail: "Installed · Remove" + (why ?? ""), section: "Installed"))
                continue
            }
            let detail: String
            switch a.status {
            case .available: detail = "Install · " + ByteCount.format(a.package?.downloadSize ?? 0)
            case .licenceOnly: detail = "Nothing to install: the game checks its licence"
            case .bundle: detail = "A pack: its add-ons are listed on their own"
            case .unsupported: detail = "No Windows package Playport can install"
            case .unlicensed: detail = "Not licensed to this account"
            }
            options.append(PadOption(id: (a.status == .available ? "install:" : "info:") + a.id, label: a.title,
                                     detail: detail + (why ?? ""), section: a.status == .available ? "To install" : "Other add-ons"))
        }
        for (id, rec) in installed where found[base]?.contains(where: { $0.id == id }) != true {
            options.append(PadOption(id: "remove:" + id, label: id, detail: "Installed · Remove (version \(rec.version))", section: "Installed"))
        }
        options.append(PadOption(id: "refresh", label: "Find add-ons again", detail: nil, section: " "))
        let note = errors[base] ?? (found[base]?.isEmpty == false || !installed.isEmpty ? nil : "Xbox lists no add-ons of this game for this account.")
        PadModal.shared.picker(title: "\(t.name): add-ons", note: note, options: options, selected: nil) { [weak self] choice in
            guard let self else { return }
            let parts = choice.split(separator: ":", maxSplits: 1).map(String.init)
            Task {
                switch parts.first {
                case "install": if let a = self.found[base]?.first(where: { $0.id == parts.last }) { await self.install(a, base: base) }
                case "remove": await self.remove(parts[1], base: base)
                case "refresh": await self.refresh(base)
                default: return
                }
                self.show(t)
            }
        }
    }

    // MARK: pp ui

    /// `xbox:addons:<game>`, `xbox:addon-install:<game>/<add-on>`, `xbox:addon-remove:<game>/<add-on>`
    /// (Dev/UIDriver.swift): nil once done, else why not. Logs Product IDs, statuses, sizes and file counts only.
    func drive(_ action: String, log: (String) -> Void) async -> String? {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "unknown Xbox add-on action" }
        let ids = parts[1].split(separator: "/").map(String.init)
        let base = ids[0]
        guard installer.loadRecord(base) != nil else { return "xbox-\(base) is not installed" }
        switch (parts[0], ids.count) {
        case ("addons", 1):
            if let why = await refresh(base) { return why }
            let list = found[base] ?? [], have = Set(installed(base).map(\.installed.productID))
            log("xbox: xbox-\(base) add-ons \(list.count): " + list.map { a in
                "\(a.id) \(a.status.rawValue)" + (a.package.map { " \($0.format) \($0.downloadSize) bytes" } ?? "") + (have.contains(a.id) ? " installed" : "")
            }.joined(separator: "; "))
            return nil
        case ("addon-install", 2):
            if found[base] == nil, let why = await refresh(base) { return why }
            guard let a = found[base]?.first(where: { $0.id == ids[1] }) else { return "\(ids[1]) is not an add-on of xbox-\(base) for this account" }
            guard a.status == .available else { return "\(ids[1]) is \(a.status.rawValue): nothing to install" }
            let started = Date()
            log("xbox: add-on \(a.id): installing, download \(a.package?.downloadSize ?? 0) bytes")
            if let why = await install(a, base: base) { return "refused: \(why)" }
            let installer = self.installer
            guard let report = try? await Task.detached(priority: .userInitiated, operation: { try installer.verifyAddOn(a.id, base: base) }).value,
                  let rec = installed(base).first(where: { $0.installed.productID == a.id })?.installed else { return "installed, but not verified" }
            log(String(format: "xbox: add-on \(a.id) in xbox-\(base)'s \(rec.installDir) version=\(rec.version) files=\(report.files - report.bad.count)/\(report.files) verified, "
                        + "content roots=\(installer.addOnRoots(base: base).count) after %.0f s", Date().timeIntervalSince(started)))
            return report.bad.isEmpty ? nil : "\(report.bad.count) files do not verify"
        case ("addon-remove", 2):
            guard installed(base).contains(where: { $0.installed.productID == ids[1] }) else { return "\(ids[1]) is not installed" }
            if let why = await remove(ids[1], base: base) { return why }
            log("xbox: add-on \(ids[1]) removed from xbox-\(base); \(installed(base).count) left")
            return nil
        default: return "unknown Xbox add-on action"
        }
    }
}
