// SPDX-License-Identifier: GPL-3.0-or-later
// The product UI on a panel narrower than it was drawn for. The gamepad UI
// (docs/design/2026-09-28-gamepad-ui/) is laid out for a landscape iPhone with
// about 750 points between its safe-area edges (a 6.3" Pro: 874 points less
// 62 at each side). An iPhone Duo's cover panel (Panel.swift) has 678 points
// with its camera's 84 at one side: four checklist cards, the library grid and
// the footer's hints no longer fit, and the pages run off the trailing edge.
//
// PanelFit lays its content out on a canvas `width` points wide between the
// safe-area edges, the panel's own height scaled to match, and draws it scaled
// down to the panel: everything keeps its proportions and stays on screen. The
// window's safe area is handed to the content in canvas points, so what ignores
// it (backgrounds, the footer in the home indicator's inset) still reaches the
// panel's edges. A panel at least that wide (the inner panel, any other
// iPhone) gets the content at its own size. Either way a side without an inset
// of its own gets one of `side` points, off the panel's rounded corners.

import SwiftUI

struct PanelFit<Content: View>: View {
    /// The usable width the UI was laid out for, in points.
    static var width: CGFloat { 640 }

    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let system = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + system.leading + system.trailing,
                              height: geo.size.height + system.top + system.bottom)
            // A side with no inset of its own (the cover panel's, away from its camera)
            // still keeps the page off the panel's rounded edge.
            let insets = EdgeInsets(top: system.top, leading: max(system.leading, Self.side),
                                    bottom: system.bottom, trailing: max(system.trailing, Self.side))
            // Landscape, or portrait on a foldable's inner panel (AppDelegate); a phone is
            // portrait only under a store's sign-in sheet, which covers the shell.
            let fits = full.width > full.height || min(full.width, full.height) >= 600
            let scale = fits ? Self.scale(usable: full.width - insets.leading - insets.trailing) : 1
            content
                .safeAreaPadding(EdgeInsets(top: insets.top / scale, leading: insets.leading / scale,
                                            bottom: insets.bottom / scale, trailing: insets.trailing / scale))
                .frame(width: full.width / scale, height: full.height / scale)
                .environment(\.panelSide, Self.side / scale)
                .scaleEffect(scale)
                .frame(width: full.width, height: full.height)
                .ignoresSafeArea()
                .onAppear { Self.log(full: full, insets: system, scale: scale) }
                // Another panel or a turn, not the frames of an animation (the home
                // indicator's inset going away under a game's launch screen, say).
                .onChange(of: PanelShape(full)) { _, _ in
                    Self.log(full: full, insets: system, scale: scale)
                    AppDelegate.panelChanged()
                }
        }
    }

    /// The least inset at each side, in points.
    static var side: CGFloat { 20 }

    /// 1 when `usable` points are enough, else the factor that fits `width` into them.
    static func scale(usable: CGFloat) -> CGFloat {
        guard usable > 0 else { return 1 }
        return min(1, usable / width)
    }

    private static func log(full: CGSize, insets: EdgeInsets, scale: CGFloat) {
        WineHostRuntime.appendLog("ui: panel \(Int(full.width))x\(Int(full.height)) pt, safe area "
            + "\(Int(insets.leading))/\(Int(insets.trailing)) at the sides, \(Int(insets.bottom)) below; "
            + "drawn at \(Int((scale * 100).rounded()))% (laid out for \(Int(width)) pt)")
    }
}

/// PanelFit's least inset at each side, in the content's points; 0 outside it.
/// A plain key, not @Entry: the app's build loads no SwiftUI macro plugin (AGENTS.md).
private struct PanelSideKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/// A panel's shape to 50 points and which way it is turned: what changes when the app
/// moves to another panel or turns, and stays put while an inset animates.
private struct PanelShape: Equatable {
    let width: Int
    let landscape: Bool

    init(_ size: CGSize) {
        width = Int((size.width / 50).rounded())
        landscape = size.width > size.height
    }
}

extension EnvironmentValues {
    var panelSide: CGFloat {
        get { self[PanelSideKey.self] }
        set { self[PanelSideKey.self] = newValue }
    }
}

extension View {
    /// The least side inset for a page inside a NavigationStack: the stack is UIKit's,
    /// which hands its pages the window's own safe area and not PanelFit's, so a side
    /// with no inset of its own (an iPhone Duo's panels, away from the camera) would
    /// put the page's edge on the panel's edge.
    func panelSides() -> some View { modifier(PanelSides()) }
}

private struct PanelSides: ViewModifier {
    @Environment(\.panelSide) private var side

    func body(content: Content) -> some View {
        GeometryReader { geo in
            content
                .safeAreaPadding(.leading, max(0, side - geo.safeAreaInsets.leading))
                .safeAreaPadding(.trailing, max(0, side - geo.safeAreaInsets.trailing))
        }
    }
}
