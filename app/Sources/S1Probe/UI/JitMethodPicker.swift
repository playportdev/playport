// SPDX-License-Identifier: GPL-3.0-or-later
// The JIT method picker (PlayportKit JitMethod, decision 0051): from Settings ›
// Setup check's JIT method row and X on the setup checklist's first step. The
// choice is stored under JitMethod.key and read by the next Play
// (JitProvider.method); inside LiveContainer the built-in helper is not offered.

import PlayportKit
import SwiftUI

@MainActor
enum JitMethodPicker {
    static func show() {
        let inLC = JitProvider.inLiveContainer
        let current = JitProvider.method
        var note = "Every method needs Developer Mode. StikDebug and another app need the universal.js script for Playport."
        if inLC {
            note = "Playport runs inside LiveContainer, which cannot start Playport's own JIT helper. "
                + "Launch Playport with JIT from LiveContainer (its JIT enabler set to StikDebug, with universal.js), "
                + "or choose StikDebug and turn on LiveContainer's Use LiveContainer's Bundle ID."
        }
        PadModal.shared.picker(
            title: "JIT method", context: "Where a game's JIT comes from", note: note,
            options: JitMethod.choices(inLiveContainer: inLC).map { PadOption(id: $0.rawValue, label: $0.label, detail: $0.detail) },
            selected: current.rawValue) { id in
            guard let m = JitMethod(rawValue: id) else { return }
            UserDefaults.standard.set(m.rawValue, forKey: JitMethod.key)
            WineHostRuntime.appendLog("jit: method set to \(m.rawValue)" + (inLC ? " (in LiveContainer)" : ""))
        }
    }
}
