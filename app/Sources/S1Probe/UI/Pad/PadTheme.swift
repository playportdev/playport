// SPDX-License-Identifier: GPL-3.0-or-later
// The gamepad UI's look (docs/design/2026-09-28-gamepad-ui/): one dark
// palette, the amber focus ring, and the button glyphs the footer and the top
// bar show.

import HostIOKit
import SwiftUI
import UIKit

enum PP {
    static let background = Color(hex: 0x0B0E13)
    static let surface = Color(hex: 0x151A21)
    static let raised = Color(hex: 0x1D242E)
    static let line = Color(hex: 0x2A3340)
    static let text = Color(hex: 0xEEF1F5)
    static let soft = Color(hex: 0xC9D1DC)
    static let muted = Color(hex: 0x9AA5B4)
    static let accent = Color(hex: 0xF5B544)
    static let onAccent = Color(hex: 0x1A1204)
    static let progress = Color(hex: 0x6CA8FF)
    static let ok = Color(hex: 0x6FCF7F)
    /// Art tiles without store art, in the design's colours, picked by name.
    static let tiles: [Color] = [0x24324A, 0x5B3A8C, 0x3E6A3A, 0x6E2B2B, 0x2F5A66, 0x6A5326].map { Color(hex: $0) }

    static func tile(for name: String) -> Color {
        tiles[Int(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }) % tiles.count]
    }

    /// Headings: the design's semi-condensed face.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// A controller button as the footer and the top bar draw it: a light pill with its name.
struct PadGlyph: View {
    let button: NavButton
    var inverted = false

    var body: some View {
        Text(Self.name(button))
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(inverted ? PP.accent : PP.background)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(inverted ? PP.onAccent : PP.text, in: Capsule())
    }

    static func name(_ b: NavButton) -> String {
        switch b {
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .lb: "LB"
        case .rb: "RB"
        case .menu: "≡"
        case .view: "⧉"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        }
    }
}

/// One footer entry: what `button` does on this screen. Tapping it does the same.
struct PadHint: Identifiable {
    let button: NavButton
    let label: String
    let action: () -> Void
    var id: NavButton { button }
}

/// The footer every screen has: its buttons, right-aligned, each tappable.
/// `leading`: at the left with no rule above it, beside a panel at the right
/// (GameOptions.dc.html), as a picker's own footer is.
struct PadFooter: View {
    let hints: [PadHint]
    var leading = false

    var body: some View {
        HStack(spacing: 10) {
            if !leading { Spacer(minLength: 0) }
            ForEach(hints) { h in
                Button(action: h.action) {
                    HStack(spacing: 6) {
                        PadGlyph(button: h.button)
                        Text(h.label).font(.system(size: 13)).foregroundStyle(PP.soft)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hint-\(h.button.rawValue)")
            }
            if leading { Spacer(minLength: 0) }
        }
        .frame(height: 36)
        .overlay(alignment: .top) {
            // The rule runs to the screen's edges, past the landscape safe area.
            if !leading { Rectangle().fill(PP.raised).frame(height: 1).ignoresSafeArea(edges: .horizontal) }
        }
    }
}

/// The window's safe area, for views over the game surface: the surface
/// ignores the safe area, and so does what is laid over it, so SwiftUI
/// reports no insets there. In landscape the Dynamic Island takes the
/// leading or trailing edge, whichever way the phone is turned; these are
/// read from the window, and again whenever the phone turns.
@MainActor
final class WindowInsets: ObservableObject {
    static let shared = WindowInsets()
    @Published private(set) var insets = EdgeInsets()
    private var observer: NSObjectProtocol?

    private init() {
        read()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification,
                                                          object: nil, queue: .main) { _ in
            // The window's insets follow the rotation a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { WindowInsets.shared.read() } }
        }
    }

    /// Reads the key window's insets now; the line for the log.
    @discardableResult
    func read() -> String {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        let i = window?.safeAreaInsets ?? .zero
        let e = EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right)
        if e != insets { insets = e }
        return "safe area top=\(Int(i.top)) left=\(Int(i.left)) bottom=\(Int(i.bottom)) right=\(Int(i.right))"
            + (window == nil ? " (no key window)" : "")
    }

    /// A horizontal margin of at least `margin` inside the safe area on each side.
    var leading: CGFloat { insets.leading }
    var trailing: CGFloat { insets.trailing }
    func side(_ margin: CGFloat, _ inset: CGFloat) -> CGFloat { max(margin, inset + 8) }
}
