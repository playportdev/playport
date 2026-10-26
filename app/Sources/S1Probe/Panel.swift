// SPDX-License-Identifier: GPL-3.0-or-later
// The panel the app is on now, in native pixels. On a one-panel iPhone that is
// UIScreen.main; on a foldable (iPhone Duo, iPhone19,4: a 2670x1878 inner panel
// and a 2034x1398 cover panel) the app moves between panels as the phone folds,
// and its window can be smaller than either, so the size is the app's window
// scene's: its bounds at its screen's native scale. A title's guest screen
// (TitleScreen) and the pickers' sizes (LaunchSettingsText) are computed from it.

#if canImport(UIKit)
import UIKit

@MainActor
enum Panel {
    /// The foreground window scene, else any connected one.
    static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// The scene's size in native pixels, landscape or portrait as it is now;
    /// UIScreen.main's when there is no scene yet.
    static var pixels: CGSize {
        guard let scene else { return UIScreen.main.nativeBounds.size }
        let size = scene.coordinateSpace.bounds.size
        let scale = scene.screen.nativeScale
        guard size.width > 0, size.height > 0 else { return scene.screen.nativeBounds.size }
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// Whether `screen` is a large panel, a foldable's inner one (an iPhone Duo's is
    /// 951x669 points): its shorter side alone is wider than any iPhone panel's
    /// (at most 440 points). There the app turns with the phone, portrait too: iOS
    /// does not keep an app landscape on such a panel, it shows a landscape-only app
    /// in a letterboxed window instead (AppDelegate, UI/PanelFit.swift).
    static func isLarge(_ screen: UIScreen?) -> Bool {
        guard let screen else { return false }
        return min(screen.bounds.width, screen.bounds.height) >= 600
    }

    /// A foldable (an iPhone Duo): the model is one, or the app is on a large panel now.
    /// The cover panel alone is an ordinary iPhone's size, so the model decides while folded.
    static var isFoldable: Bool {
        foldableModels.contains(model)
            || UIApplication.shared.connectedScenes.contains { isLarge(($0 as? UIWindowScene)?.screen) }
    }
    private static let foldableModels: Set<String> = ["iPhone19,4"]

    /// The device's model identifier (`iPhone19,4`); the simulated device's in the simulator.
    static var model: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// The highest refresh rate of the panel the scene is on.
    static var maximumFramesPerSecond: Int {
        (scene?.screen ?? UIScreen.main).maximumFramesPerSecond
    }

    /// One line for the logs: the device model, the panel and the window.
    static var summary: String {
        let screen = (scene?.screen ?? UIScreen.main).nativeBounds.size
        let px = pixels
        return "\(model) panel \(Int(screen.width))x\(Int(screen.height)) px, window \(Int(px.width))x\(Int(px.height)) px"
    }
}
#endif
