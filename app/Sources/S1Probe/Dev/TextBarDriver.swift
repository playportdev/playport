// SPDX-License-Identifier: GPL-3.0-or-later
// The UI driver's text bar actions (dev builds only; PLA-267, PLA-606): what a person
// does with the bar menu:text opened over the running game (UI/TextBarView.swift),
// through the bar's own model calls (GameTextBar), as its buttons and field make them.
//
//   textbar:close                the close button
//   textbar:secure | plain       the lock button: password mode on or off
//   textbar:tab | enter | backspace
//                                the bar's Tab and Enter buttons, the keyboard's delete
//   textbar:type:<text>          <text> typed into the field, as the keyboard types it;
//                                percent-encoded (%2C a comma, %25 a percent sign)
//   textbar:secret[+enter]       password mode, then a value that is in no action, no
//                                environment and no log: this action emits `ui-secret-wanted`
//                                with its number n, `pp ui` answers by pushing the value to
//                                Documents/ui-text-<nonce>-<n> (from --secret-file or
//                                --secret-stdin), and the driver reads that file, deletes it,
//                                then types the value into the field (and presses Enter, which
//                                goes once the value is in the server's queue: TextBarPacing).
//                                Every action is done once what it typed is in that queue; a
//                                game that drains none of it for 5 s fails the action
//
// The value lives in the field and the guest's window only. The log, run-events.jsonl
// and a restart's ui-continue.json see the literal action; a file left by a run that
// ended between the push and the read is removed at the app's start, unread.

import Foundation
import HostIOKit

@MainActor
enum TextBarDriver {
    static let secretPrefix = "ui-text-"
    /// How long the secret action waits for the workstation's file.
    private static let secretWait: TimeInterval = 60

    /// Every Documents/ui-text-* an earlier run left: removed, not read.
    static func clearAtStart() {
        let docs = WineHostRuntime.documents
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: docs.path) else { return }
        for n in names where n.hasPrefix(secretPrefix) {
            try? FileManager.default.removeItem(at: docs.appendingPathComponent(n))
        }
    }

    /// `textbar:<op>`, action number `index`; nil when done, else `refused: …` or `failed: …`.
    static func run(_ op: String, index: Int, log: (String) -> Void) async throws -> String? {
        let bar = GameTextBar.shared
        guard bar.isOpen else { return "refused: the text bar is not open (menu:open, then menu:text, opens it)" }
        try UIDriver.checkpoint()
        switch op {
        case "close": bar.close()
        case "secure", "plain": bar.setSecure(op == "secure")
        case "tab": bar.press(.tab)
        case "enter": bar.press(.enter)
        case "backspace": bar.press(.backspace)
        case "secret", "secret+enter":
            if let failure = try await secret(index: index) { return failure }
            if op == "secret+enter" { bar.press(.enter) }
        default:
            guard op.hasPrefix("type:"), let text = String(op.dropFirst(5)).removingPercentEncoding, !text.isEmpty else {
                return "refused: not textbar:close|secure|plain|tab|enter|backspace|type:<text>|secret[+enter]"
            }
            bar.type(text)
        }
        // Typed input reaches the server's queue before the action is done (and before the next
        // action's key): none of it is lost to a game that pumps no messages without a word.
        if !(await bar.delivered()) {
            return "failed: the game took no input for 5 s (no guest thread drains it: hung or busy)"
        }
        try await UIDriver.pause(.milliseconds(500))   // the bar drawn, the game's window painted, for a screenshot
        log("textbar \(op.hasPrefix("type:") ? "type" : op): " + (bar.isOpen ? "open, \(bar.bar.summary)" : "closed"))
        return nil
    }

    /// Password mode, then the workstation's value for this action typed into the field.
    private static func secret(index: Int) async throws -> String? {
        let url = WineHostRuntime.documents.appendingPathComponent("\(secretPrefix)\(TitleMode.nonce)-\(index)")
        GameTextBar.shared.setSecure(true)
        RunEvents.emit("ui-secret-wanted", ["index": index])
        let deadline = Date().addingTimeInterval(secretWait)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard Date() < deadline else { return "failed: no value arrived in \(Int(secretWait)) s (pp ui --secret-file or --secret-stdin)" }
            try await UIDriver.pause(.milliseconds(200))
        }
        let data = try? Data(contentsOf: url)
        // Gone before anything is typed: the field and the guest's window hold the only copy.
        try? FileManager.default.removeItem(at: url)
        guard let data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return "failed: the pushed value was empty or not UTF-8"
        }
        try UIDriver.checkpoint()
        GameTextBar.shared.type(value)
        return nil
    }
}
