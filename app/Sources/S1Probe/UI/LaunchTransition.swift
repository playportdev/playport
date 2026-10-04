// SPDX-License-Identifier: GPL-3.0-or-later
// A game's launch, in motion ("dive into the art"): Play pushes the camera into the
// game's page, which zooms, blurs and fades as the launch screen's backdrop, name, bar,
// step and tip come up (RootView, UI/LaunchViews.swift LaunchScreen); on the game's first
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
