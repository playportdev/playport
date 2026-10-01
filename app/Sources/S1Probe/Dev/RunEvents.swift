// SPDX-License-Identifier: GPL-3.0-or-later
// Structured progress of a driven launch (dev builds only), for the device
// driver (`pp ui`, tools/ui.py). Every S1_MODE=ui launch appends one JSON object per line to Documents/run-events.jsonl, tagged with
// the launch's TITLE_NONCE:
//
//   {"nonce":"…","t":1790318689.123,"event":"mark","what":"first frame","s":13.08}
//   {"nonce":"…","t":…,"event":"ui-action","action":"verify:app-367520","result":"ok"}
//   {"nonce":"…","t":…,"event":"ui-done","outcome":"ok actions=2"}
//   {"nonce":"…","t":…,"event":"title-done","outcome":"exit=0x00000000 after_s=42"}
//
// The file is a few hundred bytes a launch, so a driver can read it every few
// seconds instead of pulling s1-host.log; it is cut when it passes 256 KiB.
// A Home Screen launch has no nonce and writes nothing.

import Foundation

enum RunEvents {
    static let url = WineHostRuntime.documents.appendingPathComponent("run-events.jsonl")
    private static let nonce = ProcessInfo.processInfo.environment["TITLE_NONCE"]
    // A lock, not a DispatchQueue.sync closure: at -Onone that closure's escape
    // check embeds the source file's absolute path in the binary (verify-ipa.py, paths).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var checkedSize = false

    static func emit(_ event: String, _ fields: [String: Any] = [:]) {
        guard let nonce else { return }
        var o = fields
        o["nonce"] = nonce
        o["event"] = event
        o["t"] = (Date().timeIntervalSince1970 * 1000).rounded() / 1000
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        if !checkedSize {
            checkedSize = true
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 256 * 1024 {
                try? fm.removeItem(at: url)
            }
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data + Data("\n".utf8))
    }
}
