// SPDX-License-Identifier: GPL-3.0-or-later
// An Xbox copy's licence lapse (PLA-505), dev app only (decision 0179): PlayportKit's
// LicenceLapses kept in the state root. Microsoft's verdict on an installed copy's licence
// comes from each Play (XboxPlay.prepare) and each Library refresh (XboxGames.refresh).
// Only its definitive refusal of the copy counts (XboxLicenceResult.copyLicensed): no
// answer, an outage, the stored licence standing in, or the device's ten-device limit
// neither starts nor cancels a lapse. A lapsed copy's page says so and Play is off; its
// removal falls due 7 days after the first refusal, runs at app start or at a Library
// refresh after that, and waits while the copy's saves aren't known to be in the cloud.
// The player may uninstall it earlier. Removal keeps the saves.

import Combine
import ContentKit
import Foundation
import PlayportKit
import XboxClientKit

@MainActor
final class XboxLapses: ObservableObject {
    static let shared = XboxLapses()
    @Published private(set) var ledger: LicenceLapses
    /// Whether a copy's saves are in the cloud: the runtime's save index, by the copy's SCID
    /// (Dev/XboxCloudSaves.swift); unknown or unsynced, the due removal waits.
    var saves: UnsyncedSaves = XboxCloudSaves.lapseSaves
    nonisolated static let file = LibraryModel.paths.layout.stateRoot.appendingPathComponent("lapses.json")
    private var watch: AnyCancellable?
    private var log: ContentKit.Logger { XboxInstalls.log }

    private init() { ledger = LicenceLapses.load(Self.file) }

    func state(_ key: StoreGameKey, at now: Date = Date()) -> LicenceLapses.State {
        key.store == .xbox ? ledger.state(key, at: now, saves: saves) : .licensed
    }

    /// The installed Xbox copies, by key.
    private var installed: [InstalledTitle] { LibraryModel.shared.catalog.titles.filter { $0.store == .xbox } }

    /// A licence check's result for the copy `key`.
    func record(_ key: StoreGameKey, _ result: XboxLicenceResult, at now: Date = Date()) {
        let verdict: LicenceVerdict = switch result.copyLicensed {
        case true?: .granted
        case false?: .refused
        case nil: .noVerdict
        }
        update { changed in
            changed = ledger.record(verdict, for: key, at: now)
            if changed { log.info("xbox", "\(key): " + (verdict == .refused ? "licence refused; lapse until \(Self.stamp(ledger.lapse(key)?.removeAt))" : "licence granted again; lapse cancelled")) }
        }
    }

    /// Microsoft's verdict on the installed copy `t` now; nil when it can't be asked (signed out, no record).
    @discardableResult
    func check(_ t: InstalledTitle) async -> XboxLicenceResult? {
        let account = XboxAccount.shared
        guard t.store == .xbox, account.state == .signedIn,
              let rec = XboxInstalls.shared.installer.loadRecord(t.key.id) else { return nil }
        do {
            let result = try await account.session.licence(contentID: rec.contentID, market: XboxMarket.current)
            record(t.key, result)
            return result
        } catch {
            log.info("xbox", "\(t.key): licence not checked (\(XboxInstalls.message(error)))")
            return nil
        }
    }

    /// App start: once the Library has scanned, the due removals; then the ledger follows the
    /// catalogue (an uninstalled copy's lapse goes, so a later install starts clean).
    func atStart() {
        guard watch == nil else { return }
        let library = LibraryModel.shared
        watch = library.$catalog.combineLatest(library.$scannedOnce).sink { [weak self] catalog, scanned in
            guard scanned else { return }
            self?.keep(Set(catalog.titles.filter { $0.store == .xbox }.map(\.key)))
        }
        Task {
            while !library.scannedOnce { try? await Task.sleep(for: .milliseconds(100)) }
            removeDue()
        }
    }

    /// A Library refresh: each installed copy's licence, then the due removals.
    func refreshed() async {
        for t in installed { await check(t) }
        removeDue()
    }

    /// Uninstalls (keeping saves) each copy whose removal is due; logs each one held.
    func removeDue(at now: Date = Date()) {
        let library = LibraryModel.shared
        for t in installed {
            switch state(t.key, at: now) {
            case .due:
                guard library.preparing[t.id] == nil, !library.removing.contains(t.id) else { continue }
                log.info("xbox", "\(t.key): licence lapsed since \(Self.stamp(ledger.lapse(t.key)?.refusedAt)); removing it, saves kept")
                library.uninstall(t.id, keepSaves: true)
            case .held(let at):
                log.info("xbox", "\(t.key): removal due \(Self.stamp(at)) held: its saves are not known to be in the cloud")
            case .licensed, .lapsed: break
            }
        }
    }

    /// The page's Uninstall now: the player removes a lapsed copy before its date (saves kept).
    func askRemove(_ t: InstalledTitle) {
        PadModal.shared.picker(title: "Uninstall \(t.name)?", context: t.name,
                               note: "Its licence has lapsed. Its saves on this phone stay for when you install it again.",
                               options: [PadOption(id: "keep", label: "Keep it"), PadOption(id: "uninstall", label: "Uninstall, keep saves")],
                               selected: nil) { [log] choice in
            guard choice == "uninstall" else { return }
            log.info("xbox", "\(t.key): uninstalled by the player during its lapse, saves kept")
            LibraryModel.shared.uninstall(t.id, keepSaves: true)
        }
    }

    /// The page's notice for the copy, nil when it is licensed.
    func notice(_ key: StoreGameKey) -> String? {
        let refused = "Microsoft no longer grants this copy's licence (a PC Game Pass membership ended, or the game left it), so it can't be played."
        switch state(key) {
        case .licensed: return nil
        case .lapsed(let at):
            return refused + " Playport uninstalls it on \(Self.shown(at)), keeping its saves, unless the licence returns: Check licence asks Microsoft again."
        case .held(let at):
            return refused + " Its removal was due on \(Self.shown(at)) and waits until its saves are in the cloud."
        case .due:
            return refused + " Playport is uninstalling it; its saves stay."
        }
    }

    private func keep(_ installed: Set<StoreGameKey>) {
        update { changed in changed = ledger.keep(only: installed) }
    }

    private func update(_ change: (inout Bool) -> Void) {
        var changed = false
        change(&changed)
        guard changed else { return }
        do { try ledger.save(Self.file) } catch { log.info("xbox", "lapses not saved (\(error))") }
    }

    static func stamp(_ date: Date?) -> String { date.map { ISO8601DateFormatter().string(from: $0) } ?? "?" }
    static func shown(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
}
