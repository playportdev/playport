// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Developer › Black screen, dev builds only. The test phone stays
// unlocked between driven runs, because a launch waits for the passcode on a
// locked phone. Without this page it would show the lit Home Screen for hours.
// The page is pure black over everything: no status bar, no home indicator,
// and the lowest brightness. A tap or any button wakes it and restores the
// brightness. The workstation opens it with `pp ui --action open:black`. In
// unattended mode (`pp phone unattended on`) every release of the device lock
// opens it when the app is not running (tools/phonelib.py rest).
//
// The brightness to put back is kept in UserDefaults. An app ended while the
// page was up (the next run's kill) gets it back at its next launch
// (restoreAtStart).

import SwiftUI
import UIKit

@MainActor
final class BlackScreen: ObservableObject {
    static let shared = BlackScreen()
    static let savedKey = "dev.blackScreen.brightness"

    @Published private(set) var shown = false

    private static func log(_ line: String) { WineHostRuntime.appendLog("black screen: " + line) }

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    func show() {
        guard !shown else { return }
        shown = true
        if let screen = Self.screen {
            if UserDefaults.standard.object(forKey: Self.savedKey) == nil {
                UserDefaults.standard.set(Double(screen.brightness), forKey: Self.savedKey)
            }
            screen.brightness = 0
        }
        Self.log("shown")
    }

    /// A tap, a button, or the scene leaving the foreground: the app again, at its brightness.
    func wake() {
        guard shown else { return }
        shown = false
        Self.restoreBrightness()
        Self.log("woken")
    }

    /// At launch: a brightness that an app ended under the page left low is put back.
    static func restoreAtStart() {
        if restoreBrightness() { log("brightness restored at start") }
    }

    @discardableResult
    private static func restoreBrightness() -> Bool {
        guard let saved = UserDefaults.standard.object(forKey: savedKey) as? Double else { return false }
        UserDefaults.standard.removeObject(forKey: savedKey)
        screen?.brightness = CGFloat(saved)
        return true
    }
}

struct BlackScreenView: View {
    @ObservedObject private var black = BlackScreen.shared

    var body: some View {
        if black.shown {
            Color.black
                .ignoresSafeArea()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .contentShape(Rectangle())
                .onTapGesture { black.wake() }
        }
    }
}
