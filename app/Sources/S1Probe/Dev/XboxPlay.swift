// SPDX-License-Identifier: GPL-3.0-or-later
// Play of an installed Xbox copy (PLA-499), dev app only (decisions 0166, 0167): the
// licence, fetched at every Play (Microsoft asks for it, refreshOnStartup) or the stored
// one while licensing can't be reached; the copy's kept-encrypted files decrypted in place
// in its own folder (PlayportKit InPlaceSwap, the originals set aside); the keyed loopback
// bridge for the runtime's tickets; the prefix keys the GDK runtime reads
// (GamingRuntimeKeys). The launch carries the bridge's port and key as the game's own
// environment (LaunchCoordinator.Request.guestEnvironment) and, when it ends, stops the
// bridge and puts the originals back; LibraryModel's start finishes that after a crash.
// A refusal says whether the sign-in or the licence stopped the game.

import ContentKit
import Foundation
import PlayportKit
import XboxClientKit

@MainActor
enum XboxPlay {
    /// What the launch carries for the play.
    struct Prepared {
        var guestEnvironment: [String: Secret<String>]
        var prerequisites: [Prerequisite]
        /// Stops the bridge and puts the originals back: once, however the launch ends.
        var atEnd: @Sendable () -> Void
    }

    enum Failure: Error, CustomStringConvertible {
        case refused(XboxPlayRefusal)
        /// Not the sign-in or the licence: the install record, the files, the bridge.
        case failed(String)
        var description: String {
            switch self {
            case .refused(let r): "\(r.title): \(r.description)"
            case .failed(let why): why
            }
        }
    }

    /// The last Play's refusal, for `pp ui` (Dev/UIDriver.swift); nil after one that started.
    static var lastRefusal: String?

    /// The game's own WinHTTP offers HTTP/2 for the runtime only when asked (patches/wine-gdk).
    static let winhttpHTTP2 = ["WINE_WINHTTP_HTTP2": Secret("1")]

    /// Licence, plaintext in place, bridge and prefix keys for a Play of the copy `t`.
    static func prepare(_ t: InstalledTitle, continuing: Bool) async -> Result<Prepared, Failure> {
        lastRefusal = nil
        let account = XboxAccount.shared, log = XboxInstalls.log, id = t.key.id
        guard account.state == .signedIn else { return .failure(.refused(.signedOut)) }
        let installer = XboxInstalls.shared.installer
        guard let rec = installer.loadRecord(id) else {
            return .failure(.failed("Playport has no install record for this Xbox copy. Remove it and install it again."))
        }
        let folder = LibraryModel.paths.games.appendingPathComponent(rec.installDir, isDirectory: true)
        let manifest: XboxGameManifest
        do { manifest = try XboxGameManifest.load(folder: folder) } catch {
            return .failure(.failed("The game's MicrosoftGame.config is missing from its folder; Verify the game."))
        }

        // 1. The licence: Microsoft's verdict, or the stored one while it can't be reached. A
        //    verdict also starts or cancels the copy's lapse (Dev/XboxLapse.swift).
        let licence: XboxLicence
        do {
            let market = Locale.current.region?.identifier ?? "US"
            let result = try await account.session.licence(contentID: rec.contentID, market: market)
            XboxLapses.shared.record(t.key, result)
            switch XboxPlayRefusal.check(result) {
            case .success(let l): licence = l
            case .failure(let refusal): return .failure(.refused(refusal))
            }
        } catch {
            return .failure(.failed(XboxInstalls.message(error)))
        }
        log.info("xbox", "\(t.key): licence \(licence.source == .cache ? "stored (licensing unreachable)" : "granted")")

        // 2. The kept-encrypted files in plaintext under their own names for this play.
        let swap = LibraryModel.inPlaceSwap, play = t.id
        if !rec.encrypted.isEmpty {
            let files: XboxPlayFiles
            do { files = try XboxPlayFiles(installed: rec, keys: licence.keys) } catch let refusal as XboxPlayRefusal {
                return .failure(.refused(refusal))
            } catch {
                return .failure(.failed(XboxInstalls.message(error)))
            }
            let started = Date()
            let swapped: Error? = await Task.detached(priority: .userInitiated) {
                do {
                    try swap.swap(play: play, folder: rec.installDir, files: files.paths, plaintext: files.plaintext)
                    return nil
                } catch { return error }
            }.value
            if let swapped {
                log.info("xbox", "\(t.key): kept-encrypted files not decrypted: \(swapped)")
                return .failure(.failed("The game's files could not be prepared to start (\(swapped)). Verify the game."))
            }
            log.info("xbox", "\(t.key): \(files.paths.count) kept-encrypted file(s) decrypted in place"
                     + String(format: " in %.2f s", Date().timeIntervalSince(started)))
        }

        // 3. The bridge: the runtime's tickets for this copy, and the player's choice at a save
        //    conflict (Dev/XboxCloudSaves.swift), from now to the launch's end.
        let service = XboxBridgeService(copy: XboxBridgeCopy(productID: id, manifest: manifest), account: account.session,
                                        updates: XboxUpdateChecker(installer: installer), saves: XboxSavePromptAsker(), log: log)
        let listener = XboxBridgeListener(service: service, log: log)
        do { try await listener.start() } catch {
            listener.stop()
            try? swap.restore(play: play)
            return .failure(.failed("Playport couldn't open the game's Xbox sign-in channel (\(error)). Try again."))
        }

        // 4. The keys the GDK runtime and the game's thunks read in the prefix.
        do { try PrefixRegistryFile(prefix: WineHostRuntime.shared.prefixURL).add(GamingRuntimeKeys.values) } catch {
            log.info("xbox", "\(t.key): Gaming Services and Store keys not written (\(error))")
        }

        // 5. The prerequisites the package declares and carries (VC14's installer); none when continuing.
        var prerequisites: [Prerequisite] = []
        if !continuing {
            for p in manifest.prerequisites(files: rec.files) {
                if let pre = try? Prerequisite.make(ids: p.ids, name: p.name, installDir: rec.installDir, path: p.path,
                                                    arguments: p.arguments) { prerequisites.append(pre) }
            }
        }

        let ended = Once()
        // XODUS_SAVE_SYNC=auto (the runtime's default, as Nexus sets it) also writes the runtime's
        // `xodus-savesync:` lines to the game log: downloaded, uploaded, cloud on or off.
        let environment = listener.guestEnvironment.merging(winhttpHTTP2) { own, _ in own }
            .merging(["XODUS_SAVE_SYNC": Secret("auto")]) { own, _ in own }
        return .success(Prepared(guestEnvironment: environment, prerequisites: prerequisites) {
            guard ended.first() else { return }
            XboxSaveConflictPrompt.gameEnded()
            listener.stop()
            do {
                try swap.restore(play: play)
                log.info("xbox", "\(play): originals back, plaintext deleted")
            } catch {
                log.info("xbox", "\(play): originals not all back (\(error)); the next app start finishes it")
            }
        })
    }

    /// A refused Play's message: the sign-in (Sign in) or the licence (Try again).
    static func ask(_ t: InstalledTitle, _ failure: Failure) {
        lastRefusal = failure.description
        LibraryModel.log("play \(t.name) (\(t.id)): refused: \(failure)")
        let title: String, note: String
        var options: [PadOption] = []
        switch failure {
        case .refused(let r):
            title = r.title
            note = r.description
            if r.kind == .signIn { options.append(PadOption(id: "signin", label: "Sign in")) }
            else { options.append(PadOption(id: "retry", label: "Try again")) }
        case .failed(let why):
            title = "The game could not start"
            note = why
            options.append(PadOption(id: "retry", label: "Try again"))
        }
        options.append(PadOption(id: "cancel", label: "Cancel"))
        PadModal.shared.picker(title: title, context: t.name, note: note, options: options, selected: nil) { choice in
            switch choice {
            case "retry": Task { try? await LibraryModel.shared.play(t.id) }
            case "signin": XboxAccount.shared.beginSignIn()
            default: break
            }
        }
    }
}

/// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
