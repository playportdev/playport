// SPDX-License-Identifier: GPL-3.0-or-later
// A game's launch, in motion ("dive into the art"): Play pushes the camera into the
// game's page: its text and controls zoom, blur and fade while the launch screen's name,
// bar, step and tip come up. The hero art does not move: the page and the launch screen
// draw it in the same band (UI/LaunchViews.swift HeroBanner), the page's copy goes at
// once, and the launch screen's dims from the page's look to its own. On the game's first
// frame the launch screen keeps flying towards the player, blurring away, and the game
// settles in from just behind it. Reduce Motion leaves fades only.

import SwiftUI

enum LaunchMotion {
    /// The game's page leaving on Play.
    static let pageOut = Animation.timingCurve(0.5, 0, 0.3, 1, duration: 0.65)
    /// The launch screen leaving on the first frame.
    static let sheetOut = Animation.timingCurve(0.5, 0, 0.3, 1, duration: 0.7)
    /// The game settling in under it.
    static let gameIn = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.75).delay(0.12)
    /// The launch screen's parts coming in, `delay` after Play.
    static func partIn(_ duration: Double, delay: Double) -> Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: duration).delay(delay)
    }
    /// How small the game starts, behind the launch screen.
    static let gameFrom = 0.9

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
