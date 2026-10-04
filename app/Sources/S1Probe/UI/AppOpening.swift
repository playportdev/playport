// SPDX-License-Identifier: GPL-3.0-or-later
// The opening animation (UI/OpeningView.swift draws it): at every start of the app it
// covers the first listing of the stores' games and Home's pictures, so Home appears
// whole rather than with empty tiles. Its intro lasts 1.8 s: placeholders where Home's
// cards will be fall into the porthole as the app's icon forms. It then holds on the
// icon, an arc orbiting it, until each store has listed its games and the art Home draws
// has loaded, or 4 s after the start, whichever comes first; then Home's cards fly out of
// the porthole into place. The animation names no store.
//
// - After a game Playport restarts itself (AppRestart): the new process skips the intro
//   and starts on the finished icon. Reduce Motion does the same, and its cards fade in.
// - Nothing reaches the shell while it covers: pad presses are dropped (AppShell.press),
//   and the overlay takes touches until Home's cards start to move.
// - Each run logs `opening:` with the time it took and whether the cap ended it.

import SwiftUI
import UIKit

@MainActor
final class AppOpening: ObservableObject {
    static let shared = AppOpening()

    enum Phase { case intro, holding, leaving, done }

    @Published private(set) var phase: Phase = .intro
    /// The animation's clock: the intro's start (1.8 s before the start when it is skipped).
    private(set) var clock = Date()
    /// When the cards started to fly out.
    @Published private(set) var leftAt: Date?
    /// Home's cards (the hero, its two cards, the Recent row), by order: where the intro's
    /// placeholders stand and where the cards fly out to. Global coordinates.
    @Published private(set) var cards: [Int: Card] = [:]
    /// The screen's centre in global coordinates (the porthole's), from the overlay.
    @Published var center: CGPoint = .zero
    private(set) var skipsIntro = false
    private(set) var reduceMotion = false
    private var started = false

    struct Card: Equatable {
        var frame: CGRect
        var corner: CGFloat
    }

    nonisolated static let introSeconds = 1.8
    /// From the start: the longest the animation waits for the stores.
    nonisolated static let capSeconds = 4.0
    /// The cards' flight, the farthest included.
    nonisolated static let leaveSeconds = 1.3

    /// Covering the shell: everything until the cards have landed.
    var covering: Bool { phase != .done }

    func report(_ order: Int, _ card: Card) {
        guard phase != .done, cards[order] != card else { return }
        cards[order] = card
    }

    /// Starts the animation (once per process) and ends it when `ready` returns or at the cap.
    func run(until ready: @escaping @MainActor () async -> Void) {
        guard !started else { return }
        started = true
        reduceMotion = UIAccessibility.isReduceMotionEnabled
        skipsIntro = AppRestart.isRestart || reduceMotion
        let start = Date()
        clock = skipsIntro ? start.addingTimeInterval(-Self.introSeconds) : start
        phase = skipsIntro ? .holding : .intro
        let readiness = Task { @MainActor in await ready() }
        Task { @MainActor in
            if !skipsIntro {
                try? await Task.sleep(for: .seconds(Self.introSeconds))
                phase = .holding
            }
            let left = Self.capSeconds - Date().timeIntervalSince(start)
            let isReady = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await readiness.value; return true }
                group.addTask { try? await Task.sleep(for: .seconds(max(0, left))); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            let took = String(format: "%.2f", Date().timeIntervalSince(start))
            WineHostRuntime.appendLog("opening: \(isReady ? "ready" : "cap reached, still loading") after \(took) s"
                                      + (skipsIntro ? (reduceMotion ? " (Reduce Motion)" : " (after a game: no intro)") : ""))
            leftAt = Date()
            phase = .leaving
            try? await Task.sleep(for: .seconds(Self.leaveSeconds))
            phase = .done
            cards = [:]
        }
    }
}

// MARK: timing

/// A cubic Bézier timing curve, as CSS's `cubic-bezier()`.
struct OpeningCurve: Sendable {
    let x1, y1, x2, y2: Double

    static let standard = OpeningCurve(x1: 0.2, y1: 0.8, x2: 0.2, y2: 1)
    static let easeOut = OpeningCurve(x1: 0, y1: 0, x2: 0.58, y2: 1)
    static let easeIn = OpeningCurve(x1: 0.42, y1: 0, x2: 1, y2: 1)
    static let easeInOut = OpeningCurve(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
    /// Placeholders pulled into the porthole.
    static let pull = OpeningCurve(x1: 0.55, y1: 0, x2: 0.8, y2: 0.2)
    /// Cards flying out of it.
    static let fly = OpeningCurve(x1: 0.15, y1: 0.85, x2: 0.25, y2: 1)

    func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<24 {
            t = (lo + hi) / 2
            if Self.bezier(t, x1, x2) < x { lo = t } else { hi = t }
        }
        return Self.bezier(t, y1, y2)
    }

    private static func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }
}

enum OpeningTime {
    /// A step's eased progress at `t`: 0 before `delay`, 1 after `delay + duration`.
    static func progress(_ t: Double, _ delay: Double, _ duration: Double, _ curve: OpeningCurve = .standard) -> Double {
        curve((t - delay) / duration)
    }

    /// The value at progress `p` between keyframes `(offset, value)`, linearly.
    static func keys(_ p: Double, _ stops: [(Double, Double)]) -> Double {
        guard let first = stops.first else { return 0 }
        if p <= first.0 { return first.1 }
        for (a, b) in zip(stops, stops.dropFirst()) where p <= b.0 {
            return a.1 + (b.1 - a.1) * (p - a.0) / (b.0 - a.0)
        }
        return stops.last!.1
    }
}

// MARK: Home's side

/// One of Home's cards: reports its frame for the intro's placeholders, is hidden while the
/// animation covers, and flies out of the porthole into place as it ends.
private struct OpeningCardModifier: ViewModifier {
    @ObservedObject private var opening = AppOpening.shared
    let order: Int
    let corner: CGFloat
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: opening.phase != .leaving)) { tl in
            let v = values(at: tl.date)
            content
                .scaleEffect(v.scale)
                .offset(v.offset)
                .opacity(v.opacity)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
            frame = f
            opening.report(order, .init(frame: f, corner: corner))
        }
    }

    private func values(at date: Date) -> (scale: CGFloat, offset: CGSize, opacity: Double) {
        switch opening.phase {
        case .done: return (1, .zero, 1)
        case .intro, .holding: return (1, .zero, 0)
        case .leaving:
            let l = date.timeIntervalSince(opening.leftAt ?? date)
            if opening.reduceMotion { return (1, .zero, OpeningTime.progress(l, 0, 0.4)) }
            let dx = opening.center.x - frame.midX, dy = opening.center.y - frame.midY
            let p = OpeningTime.progress(l, 0.15 + hypot(dx, dy) * 0.0007, 0.73, .fly)
            return (0.06 + 0.94 * p, CGSize(width: dx * (1 - p), height: dy * (1 - p)), p)
        }
    }
}

/// The shell around Home's cards (the top bar, the footer, headings): hidden while the
/// animation covers, faded in as the cards land.
private struct OpeningChromeModifier: ViewModifier {
    @ObservedObject private var opening = AppOpening.shared

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: opening.phase != .leaving)) { tl in
            content.opacity(opacity(at: tl.date))
        }
    }

    private func opacity(at date: Date) -> Double {
        switch opening.phase {
        case .done: 1
        case .intro, .holding: 0
        case .leaving: OpeningTime.progress(date.timeIntervalSince(opening.leftAt ?? date), 0.6, 0.5)
        }
    }
}

extension View {
    /// One of Home's cards, in the order they fall into the porthole.
    func openingCard(_ order: Int, cornerRadius: CGFloat) -> some View {
        modifier(OpeningCardModifier(order: order, corner: cornerRadius))
    }

    /// Chrome that fades in once the opening animation's cards have flown out.
    func openingChrome() -> some View { modifier(OpeningChromeModifier()) }
}
