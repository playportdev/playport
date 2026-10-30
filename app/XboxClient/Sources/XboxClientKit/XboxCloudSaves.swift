// SPDX-License-Identifier: GPL-3.0-only
// The index the runtime keeps per save container is nexus-xgameruntime
// ab2fac35b500b87fefe51add26a0672a71d11576's src/System/XGameSave.cpp (save_state,
// load_state, enumerate_local, cloud_sync) and GameSave/Files.h (files_roots); read here
// by the Playport authors, 2026-10-30. The save conflict question is Playport's own
// bridge message (patches/xgameruntime/0002), no Xodus or Nexus one: Nexus never asks.
import Foundation

/// One side of a save conflict: when it was saved and on which device, each nil
/// when the runtime does not know it (the cloud's device: the listing seldom names one).
public struct XboxSaveVersion: Sendable, Equatable {
    public let time: Date?
    public let device: String?
    public init(time: Date?, device: String?) { self.time = time; self.device = device }
}

/// The runtime's question at a connected play's start: a save container changed on
/// this phone and in the account's cloud since they last matched (glossary: save
/// conflict). `local` is this phone's side; its device is this phone.
public struct XboxSaveConflict: Sendable, Equatable {
    public let scid: String?
    public let container: String
    public let displayName: String
    public let local: XboxSaveVersion
    public let cloud: XboxSaveVersion

    public init(scid: String?, container: String, displayName: String, local: XboxSaveVersion, cloud: XboxSaveVersion) {
        self.scid = scid; self.container = container; self.displayName = displayName; self.local = local; self.cloud = cloud
    }

    /// A SaveConflictRequest's body; nil for anything else or one without a container.
    init?(body: [UInt8]) {
        guard let xml = try? XboxXML.parse(body), xml.local == "SaveConflictRequest",
              let container = xml.value("Container"), !container.isEmpty else { return nil }
        func text(_ name: String) -> String? { xml.value(name).flatMap { $0.isEmpty ? nil : $0 } }
        self.init(scid: text("Scid"), container: container, displayName: text("DisplayName") ?? container,
                  local: XboxSaveVersion(time: Self.time(text("LocalTime")), device: nil),
                  cloud: XboxSaveVersion(time: Self.time(text("CloudTime")), device: text("CloudDevice")))
    }

    /// The runtime's and Title Storage's UTC `yyyy-MM-ddTHH:mm:ss[.fffffff]Z`, to the second.
    static func time(_ text: String?) -> Date? {
        guard let text, text.hasSuffix("Z"), text.count >= 20 else { return nil }
        let seconds = String(text.prefix(19)), rest = text.dropFirst(19).dropLast()
        guard rest.isEmpty || (rest.first == "." && rest.dropFirst().allSatisfy(\.isNumber)) else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: seconds + "Z")
    }
}

/// The player's answer: keep this phone's saves (they replace the cloud's), keep the
/// cloud's (this phone's are set aside as the runtime's recovery copy), or neither
/// for now (this play uses the phone's saves and the next connected play asks again).
public enum XboxSaveChoice: String, Sendable, Equatable {
    case local, cloud, none
}

/// Who answers a play's save conflict: the app's prompt over the game.
public protocol XboxSaveConflictAsker: Sendable {
    func choose(_ conflict: XboxSaveConflict, productID: String) async -> XboxSaveChoice
}

extension XboxSaves {
    /// Whether the copy whose MicrosoftGame.config names `scid` has saves the account's
    /// cloud does not have yet: a container the runtime has changed since its last sync
    /// (`dirty 1`) or never uploaded (`remote -`), for any account on this phone. Kept
    /// that way by a play with the cloud unreachable, a conflict left undecided or an
    /// upload that failed; the next connected play syncs them. False with no saves at
    /// all, and for a copy with no cloud-save identity (`scid` nil: no install record or
    /// no SCID), which has nothing the cloud could lack; nil when an index cannot be read.
    /// Synchronous, for the lapse rule (PLA-505).
    public static func unsynced(scid: String?, localAppData: URL) -> Bool? {
        guard let scid else { return false }
        let fm = FileManager.default
        // XodusGameSaveFiles is the game's own view of file saves; their index is in the cache.
        let roots = folders(scid: scid, localAppData: localAppData).filter {
            $0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent != "XodusGameSaveFiles"
        }
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
            // Leading-dot trees are the runtime's downloads in flight and recovery copies.
            for name in names where !name.hasPrefix(".") {
                let index = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("index")
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: index.path, isDirectory: &isDirectory) else { continue }
                guard !isDirectory.boolValue, let data = fm.contents(atPath: index.path) else { return nil }
                if pending(index: String(decoding: data, as: UTF8.self)) { return true }
            }
        }
        return false
    }

    /// The runtime's own test for a container to upload (sync_local_callback).
    static func pending(index: String) -> Bool {
        var dirty = false, remote = ""
        for line in index.split(separator: "\n") {
            if line.hasPrefix("dirty ") { dirty = Int(line.dropFirst(6)).map { $0 != 0 } ?? true }
            if line.hasPrefix("remote ") { remote = String(line.dropFirst(7)) }
        }
        return dirty || remote.isEmpty || remote == "-"
    }
}
