// SPDX-License-Identifier: GPL-3.0-or-later
// The opening animation's overlay (UI/AppOpening.swift has its timing and what it waits
// for). The porthole is the app's icon (app/Icon/AppIcon.svg), drawn in its own
// coordinates (the 1024-unit square, the porthole's 704 units across), over the
// "radial glow": the background with a lighter centre and a warm halo behind the icon.

import SwiftUI

struct OpeningView: View {
    @ObservedObject private var opening = AppOpening.shared

    var body: some View {
        TimelineView(.animation(paused: opening.phase == .done)) { tl in
            let t = tl.date.timeIntervalSince(opening.clock)
            let l = opening.leftAt.map { tl.date.timeIntervalSince($0) }
            let shown = 1 - (l.map { OpeningTime.progress($0, 0, 0.4) } ?? 0)
            let drawing = OpeningDrawing(t: t, l: l, cards: opening.cards, reduceMotion: opening.reduceMotion)
            ZStack {
                PP.background
                EllipticalGradient(stops: [.init(color: Color(hex: 0x18202A), location: 0),
                                           .init(color: PP.background, location: 0.85)])
                    .opacity(OpeningTime.progress(t, 0, 0.5))
                Canvas { ctx, size in drawing.draw(&ctx, size) }
            }
            .opacity(l == nil ? 1 : shown)
        }
        .ignoresSafeArea()
        .onGeometryChange(for: CGPoint.self) { p in
            let f = p.frame(in: .global)
            return CGPoint(x: f.midX, y: f.midY)
        } action: { opening.center = $0 }
        .allowsHitTesting(opening.phase == .intro || opening.phase == .holding)
        .accessibilityElement()
        .accessibilityLabel("Playport is starting")
    }
}

/// One frame: the placeholders, the halo, the porthole and its orbit, at `t` seconds of
/// the animation's clock and `l` seconds since the cards started to fly out.
private struct OpeningDrawing {
    let t: Double
    let l: Double?
    let cards: [Int: AppOpening.Card]
    let reduceMotion: Bool

    private typealias T = OpeningTime
    private static let hold = AppOpening.introSeconds
    private static let accent = Color(hex: 0xF5B544)
    private static let tint = Color(hex: 0xFFD08A)
    private static let lip = Color(hex: 0xB7822A)
    private static let glass = Color(hex: 0x1D242E)
    private static let deepSea = Color(hex: 0x24324A)
    private static let nearSea = Color(hex: 0x151A21)
    private static let line = Color(hex: 0x2A3340)
    private static let iconCentre = CGPoint(x: 512, y: 512)
    /// The play button's box centre, for its pop.
    private static let playCentre = CGPoint(x: 531, y: 512)

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        if t < Self.hold { placeholders(ctx, centre) }
        halo(ctx, centre)
        // The porthole: 0.385 of the short side across; it shrinks and fades as the cards come out.
        let across = min(size.width, size.height) * 0.385
        var icon = ctx
        if let l {
            let e = T.progress(l, 0.15, 0.5, .easeIn)
            icon.opacity = 1 - e
            icon.translateBy(x: centre.x, y: centre.y)
            icon.scaleBy(x: 1 - 0.7 * e, y: 1 - 0.7 * e)
        } else {
            icon.translateBy(x: centre.x, y: centre.y)
        }
        icon.scaleBy(x: across / 704, y: across / 704)
        icon.translateBy(x: -512, y: -512)
        porthole(icon)
    }

    // MARK: the placeholders: where Home's cards will be, pulled into the porthole

    private func placeholders(_ ctx: GraphicsContext, _ centre: CGPoint) {
        guard !reduceMotion else { return }
        for (i, card) in cards.sorted(by: { $0.key < $1.key }) {
            let f = card.frame
            let dx = centre.x - f.midX, dy = centre.y - f.midY
            let pullAt = 0.45 + hypot(dx, dy) * 0.0007
            var opacity: Double, scale: Double, move = 0.0, turn = 0.0
            if t < pullAt {
                let p = T.progress(t, Double(i) * 0.04, 0.28)
                opacity = p
                scale = 0.85 + 0.15 * p
            } else {
                let p = T.progress(t, pullAt, 0.48, .pull)
                opacity = 1 - p
                scale = 1 - 0.94 * p
                move = p
                turn = (dx > 0 ? -70 : 70) * p
            }
            guard opacity > 0.001 else { continue }
            var c = ctx
            c.opacity = opacity
            c.translateBy(x: f.midX + dx * move, y: f.midY + dy * move)
            c.rotate(by: .degrees(turn))
            c.scaleBy(x: scale, y: scale)
            let r = CGRect(x: -f.width / 2, y: -f.height / 2, width: f.width, height: f.height)
            let shape = Path(roundedRect: r, cornerRadius: card.corner, style: .continuous)
            c.fill(shape, with: .linearGradient(Gradient(colors: [Color(hex: 0x1A2029), Color(hex: 0x141920)]),
                                                startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)))
            c.stroke(shape, with: .color(Color(hex: 0x232B36)), lineWidth: 1)
        }
    }

    // MARK: the halo: blooms with the porthole, breathes while it waits

    private func halo(_ ctx: GraphicsContext, _ centre: CGPoint) {
        let p = T.progress(t, 0.9, 0.9)
        var opacity = p, scale = 0.6 + 0.4 * p
        if t > Self.hold {
            let u = ((t - Self.hold) / 1.6).truncatingRemainder(dividingBy: 2)
            let e = OpeningCurve.easeInOut(u < 1 ? u : 2 - u)
            opacity *= 1 - 0.45 * e
            scale *= 1 - 0.08 * e
        }
        if let l { opacity *= 1 - T.progress(l, 0, 0.4) }
        guard opacity > 0.001 else { return }
        var c = ctx
        c.opacity = opacity
        let r = 230 * scale
        c.fill(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)),
               with: .radialGradient(Gradient(stops: [.init(color: Self.accent.opacity(0.20), location: 0),
                                                      .init(color: Self.accent.opacity(0.06), location: 0.32),
                                                      .init(color: Self.accent.opacity(0), location: 0.64)]),
                                     center: centre, startRadius: 0, endRadius: r * 1.414))
    }

    // MARK: the porthole, in the icon's units

    private func porthole(_ ctx: GraphicsContext) {
        let o = Self.iconCentre
        // The ring, its lip and bolts: they grow in with a little overshoot, the bolts pop in turn.
        let rp = T.progress(t, 0.82, 0.48)
        let ringOpacity = T.keys(rp, [(0, 0), (0.65, 1), (1, 1)])
        if ringOpacity > 0.001 {
            var ring = ctx
            ring.opacity = ringOpacity
            Self.scale(&ring, about: o, by: T.keys(rp, [(0, 0.4), (0.65, 1.07), (1, 1)]))
            ring.stroke(Self.circle(o, 320), with: .color(Self.accent), lineWidth: 64)
            ring.stroke(Self.circle(o, 275), with: .color(Self.lip), lineWidth: 26)
            for i in 0..<8 {
                let s = T.keys(T.progress(t, 0.95 + Double(i) * 0.035, 0.26, .easeOut), [(0, 0), (0.6, 1.5), (1, 1)])
                guard s > 0.001 else { continue }
                let a = Double(i) * .pi / 4 - .pi / 2
                ring.fill(Self.circle(CGPoint(x: o.x + 320 * cos(a), y: o.y + 320 * sin(a)), 18 * s), with: .color(Self.tint))
            }
        }
        // The glass.
        let g = T.progress(t, 1.0, 0.4)
        if g > 0.001 { ctx.fill(Self.circle(o, 262 * g), with: .color(Self.glass)) }
        // Behind it, the sea rises and drifts, and the play button pops.
        var window = ctx
        window.clip(to: Self.circle(o, 262))
        let sp = T.progress(t, 1.15, 0.55)
        if sp > 0.001 {
            let rise = 260 * (1 - sp)
            var far = window
            far.translateBy(x: -(t / 6).truncatingRemainder(dividingBy: 1) * 544, y: rise)
            far.fill(Self.farWave, with: .color(Self.deepSea))
            var near = window
            near.translateBy(x: (t / 9).truncatingRemainder(dividingBy: 1) * 544, y: rise)
            near.fill(Self.nearWave, with: .color(Self.nearSea))
        }
        let ps = T.keys(T.progress(t, 1.3, 0.42), [(0, 0), (0.65, 1.15), (1, 1)])
        if ps > 0.001 {
            var play = window
            Self.scale(&play, about: Self.playCentre, by: ps)
            play.fill(Self.play, with: .color(PP.text))
        }
        // The glare on the glass.
        let gl = T.progress(t, 1.55, 0.3, .easeOut)
        if gl > 0.001 {
            ctx.stroke(Self.glare.trimmedPath(from: 0, to: gl), with: .color(Self.line),
                       style: StrokeStyle(lineWidth: 24, lineCap: .round))
        }
        // While it waits: an arc orbits the porthole.
        if t > Self.hold {
            var orbit = ctx
            orbit.opacity = T.progress(t, Self.hold, 0.4)
            orbit.stroke(Self.circle(o, 392), with: .color(Self.line), lineWidth: 8)
            let start = ((t - Self.hold) / 1.4).truncatingRemainder(dividingBy: 1) * 2 * .pi
            var arc = Path()
            arc.addArc(center: o, radius: 392, startAngle: .radians(start), endAngle: .radians(start + 0.12 * 2 * .pi), clockwise: false)
            orbit.stroke(arc, with: .color(Self.accent), style: StrokeStyle(lineWidth: 10, lineCap: .round))
        }
    }

    private static func circle(_ c: CGPoint, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    private static func scale(_ ctx: inout GraphicsContext, about p: CGPoint, by s: Double) {
        ctx.translateBy(x: p.x, y: p.y)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -p.x, y: -p.y)
    }

    /// The icon's sea line: a wave of period 544 units, wide enough to drift a period either way.
    private static func wave(_ y: Double, amp: Double = 36) -> Path {
        var p = Path()
        var x = -1200.0
        p.move(to: CGPoint(x: x, y: y))
        p.addCurve(to: CGPoint(x: x + 272, y: y), control1: CGPoint(x: x + 90, y: y - amp), control2: CGPoint(x: x + 182, y: y - amp))
        x += 272
        var sign = 1.0
        while x < 2300 {
            // A smooth join: the first control point mirrors the previous segment's second.
            p.addCurve(to: CGPoint(x: x + 272, y: y), control1: CGPoint(x: x + 90, y: y + sign * amp),
                       control2: CGPoint(x: x + 182, y: y + sign * amp))
            x += 272
            sign = -sign
        }
        p.addLine(to: CGPoint(x: x, y: 820))
        p.addLine(to: CGPoint(x: -1200, y: 820))
        p.closeSubpath()
        return p
    }

    private static let farWave = wave(640)
    private static let nearWave = wave(690)

    /// AppIcon.svg's play button, optically centred (translated 34 units left).
    private static let play: Path = {
        var p = Path()
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x - 34, y: y) }
        p.move(to: pt(455, 382))
        p.addCurve(to: pt(501, 356), control1: pt(455, 358), control2: pt(480, 344))
        p.addLine(to: pt(660, 486))
        p.addCurve(to: pt(660, 538), control1: pt(680, 498), control2: pt(680, 526))
        p.addLine(to: pt(501, 668))
        p.addCurve(to: pt(455, 642), control1: pt(480, 680), control2: pt(455, 666))
        p.closeSubpath()
        return p
    }()

    /// AppIcon.svg's glare, `M332 424 A 196 196 0 0 1 468 296`: its circle's centre found
    /// from the two ends and the radius (the short arc, clockwise on screen).
    private static let glare: Path = {
        let a = CGPoint(x: 332, y: 424), b = CGPoint(x: 468, y: 296), r = 196.0
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let chord = hypot(b.x - a.x, b.y - a.y)
        let h = (r * r - chord * chord / 4).squareRoot()
        let c = CGPoint(x: mid.x + h * (b.y - a.y) / chord * -1, y: mid.y + h * (b.x - a.x) / chord)
        var p = Path()
        p.addArc(center: c, radius: r, startAngle: .radians(atan2(a.y - c.y, a.x - c.x)),
                 endAngle: .radians(atan2(b.y - c.y, b.x - c.x)), clockwise: false)
        return p
    }()
}
