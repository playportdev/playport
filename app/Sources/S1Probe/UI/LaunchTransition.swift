// SPDX-License-Identifier: GPL-3.0-or-later
// A game's launch, in motion ("dive into the art"). The game's hero art never changes:
// the launch screen draws it as the game's page does (UI/LaunchViews.swift LaunchBackdrop,
// GameHeroArt), so only the text and controls move. On Play the page's zoom, blur and fade
// away (0.6 s; it drops its own copy of the art and its background at once, over the
// launch screen's identical one) while the launch screen's name, bar, step and tip fade
// in, all there within a second. On the game's first frame those fly on towards the
// player, blurring away, the art fades, and the game fades in at its own size.
// Reduce Motion leaves fades only.

import SwiftUI

enum LaunchMotion {
    /// The game's page's text and controls leaving on Play.
    static let pageSeconds = 0.6
    static let pageOut = Animation.timingCurve(0.4, 0, 0.2, 1, duration: pageSeconds)
    /// The art fading on the first frame, as the launch screen's parts fly off.
    static let backdropOut = Animation.easeInOut(duration: 0.8)
    /// The launch screen's parts leaving on the first frame.
    static let sheetOut = Animation.timingCurve(0.5, 0, 0.3, 1, duration: 0.9)
    /// The game fading in under it, at its own size.
    static let gameIn = Animation.easeOut(duration: 0.9).delay(0.15)
    /// The launch screen's parts coming in, `delay` after Play.
    static func partIn(_ duration: Double, delay: Double) -> Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: duration).delay(delay)
    }
    /// Gone by zooming towards the player: larger, blurred, transparent.
    static func dive(scale: Double, blur: Double, reduceMotion: Bool) -> AnyTransition {
        let gone = reduceMotion ? DiveEffect(scale: 1, blur: 0, opacity: 0) : DiveEffect(scale: scale, blur: blur, opacity: 0)
        return .asymmetric(insertion: .identity, removal: .modifier(active: gone, identity: DiveEffect(scale: 1, blur: 0, opacity: 1)))
    }
}

struct DiveEffect: ViewModifier {
    let scale: Double
    let blur: Double
    let opacity: Double

    func body(content: Content) -> some View {
        content.scaleEffect(scale).blur(radius: blur).opacity(opacity)
    }
}

private struct LaunchingFromPageKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Play was pressed and the app's screens are diving away over the launch screen: they
    /// drop their background and the game's hero art at once, which the launch screen draws
    /// in the same place (LaunchBackdrop), so only their text and controls move.
    var launchingFromPage: Bool {
        get { self[LaunchingFromPageKey.self] }
        set { self[LaunchingFromPageKey.self] = newValue }
    }
}
