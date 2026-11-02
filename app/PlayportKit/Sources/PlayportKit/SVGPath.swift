// SPDX-License-Identifier: GPL-3.0-or-later
// SVG path data (`d`) as absolute moves, lines, cubic curves and closes, for a
// view to draw (UI/StoreMarkView.swift draws the store marks, StoreMark.swift).
// Every command of SVG 1.1 is read: relative ones are made absolute, H and V
// become lines, quadratic curves and arcs become cubics.

import Foundation

public enum SVGPath {
    public struct Point: Equatable, Sendable {
        public var x: Double, y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
        static func + (a: Point, b: Point) -> Point { Point(a.x + b.x, a.y + b.y) }
        static func - (a: Point, b: Point) -> Point { Point(a.x - b.x, a.y - b.y) }
        static func * (a: Point, k: Double) -> Point { Point(a.x * k, a.y * k) }
    }

    public enum Segment: Equatable, Sendable {
        case move(Point)
        case line(Point)
        case cubic(Point, Point, Point)
        case close
    }

    /// The segments of `d`, or nil when it is not well formed.
    public static func parse(_ d: String) -> [Segment]? {
        var s = Scanner(Array(d.utf8))
        var out: [Segment] = []
        var current = Point(0, 0), start = Point(0, 0)
        // The last control point, for S and T, and which kind of curve made it.
        var lastCubic: Point?, lastQuad: Point?
        var command: UInt8?
        while true {
            s.skipSeparators()
            guard !s.atEnd else { return out }
            if let c = s.command() {
                command = c
            } else if command == nil || command == UInt8(ascii: "z") || command == UInt8(ascii: "Z") {
                return nil  // numbers with no command before them
            }
            guard let c = command else { return nil }
            let relative = c >= UInt8(ascii: "a")
            let base = relative ? current : Point(0, 0)
            func point() -> Point? {
                guard let x = s.number(), let y = s.number() else { return nil }
                return base + Point(x, y)
            }
            var cubicControl: Point?, quadControl: Point?
            switch c | 0x20 {  // lowercased
            case UInt8(ascii: "m"):
                guard let p = point() else { return nil }
                out.append(.move(p))
                current = p; start = p
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")  // further pairs are lines
            case UInt8(ascii: "l"):
                guard let p = point() else { return nil }
                out.append(.line(p)); current = p
            case UInt8(ascii: "h"):
                guard let x = s.number() else { return nil }
                current = Point(relative ? current.x + x : x, current.y)
                out.append(.line(current))
            case UInt8(ascii: "v"):
                guard let y = s.number() else { return nil }
                current = Point(current.x, relative ? current.y + y : y)
                out.append(.line(current))
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return nil }
                out.append(.cubic(c1, c2, p)); current = p; cubicControl = c2
            case UInt8(ascii: "s"):
                let c1 = lastCubic.map { current * 2 - $0 } ?? current
                guard let c2 = point(), let p = point() else { return nil }
                out.append(.cubic(c1, c2, p)); current = p; cubicControl = c2
            case UInt8(ascii: "q"):
                guard let q = point(), let p = point() else { return nil }
                out.append(quadratic(current, q, p)); current = p; quadControl = q
            case UInt8(ascii: "t"):
                let q = lastQuad.map { current * 2 - $0 } ?? current
                guard let p = point() else { return nil }
                out.append(quadratic(current, q, p)); current = p; quadControl = q
            case UInt8(ascii: "a"):
                guard let rx = s.number(), let ry = s.number(), let rotation = s.number(),
                      let large = s.flag(), let sweep = s.flag(), let p = point() else { return nil }
                out += arc(from: current, to: p, rx: rx, ry: ry, degrees: rotation, large: large, sweep: sweep)
                current = p
            case UInt8(ascii: "z"):
                out.append(.close); current = start
            default:
                return nil
            }
            lastCubic = cubicControl
            lastQuad = quadControl
        }
    }

    private static func quadratic(_ p0: Point, _ q: Point, _ p: Point) -> Segment {
        .cubic(p0 + (q - p0) * (2.0 / 3), p + (q - p) * (2.0 / 3), p)
    }

    /// An elliptical arc as cubics of at most a quarter turn each (SVG 1.1, F.6.5 and F.6.6).
    static func arc(from p0: Point, to p: Point, rx: Double, ry: Double, degrees: Double, large: Bool, sweep: Bool) -> [Segment] {
        var rx = abs(rx), ry = abs(ry)
        if p0 == p { return [] }
        if rx == 0 || ry == 0 { return [.line(p)] }
        let phi = degrees * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p.x) / 2, dy = (p0.y - p.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var k = (max(0, num) / den).squareRoot()
        if large == sweep { k = -k }
        let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let pieces = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(pieces)
        let t = 4.0 / 3 * tan(step / 4)
        func onEllipse(_ a: Double) -> Point {
            Point(cx + rx * cos(a) * cosPhi - ry * sin(a) * sinPhi, cy + rx * cos(a) * sinPhi + ry * sin(a) * cosPhi)
        }
        func derivative(_ a: Double) -> Point {
            Point(-rx * sin(a) * cosPhi - ry * cos(a) * sinPhi, -rx * sin(a) * sinPhi + ry * cos(a) * cosPhi)
        }
        var out: [Segment] = []
        var a = theta1, from = p0
        for i in 0..<pieces {
            let b = a + step
            let to = i == pieces - 1 ? p : onEllipse(b)
            out.append(.cubic(from + derivative(a) * t, to - derivative(b) * t, to))
            a = b; from = to
        }
        return out
    }

    /// Numbers, flags and command letters, with SVG's separators: whitespace, a comma,
    /// or none where a sign or a second decimal point starts the next number.
    struct Scanner {
        let bytes: [UInt8]
        var i = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { i >= bytes.count }

        mutating func skipSeparators() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D, 0x2C].contains(bytes[i]) { i += 1 }
        }

        mutating func command() -> UInt8? {
            skipSeparators()
            guard i < bytes.count else { return nil }
            let c = bytes[i]
            guard (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A), c != UInt8(ascii: "e"), c != UInt8(ascii: "E") else { return nil }
            i += 1
            return c
        }

        /// An arc's flag: one `0` or `1`, which may run straight into what follows.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "0") || bytes[i] == UInt8(ascii: "1") else { return nil }
            defer { i += 1 }
            return bytes[i] == UInt8(ascii: "1")
        }

        mutating func number() -> Double? {
            skipSeparators()
            let begin = i
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") { i += 1 }
            var digits = false, dot = false
            while i < bytes.count {
                let c = bytes[i]
                if c >= 0x30 && c <= 0x39 { digits = true; i += 1 }
                else if c == UInt8(ascii: "."), !dot { dot = true; i += 1 }
                else { break }
            }
            guard digits else { i = begin; return nil }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                var j = i + 1
                if j < bytes.count, bytes[j] == UInt8(ascii: "-") || bytes[j] == UInt8(ascii: "+") { j += 1 }
                if j < bytes.count, bytes[j] >= 0x30 && bytes[j] <= 0x39 {
                    i = j
                    while i < bytes.count, bytes[i] >= 0x30 && bytes[i] <= 0x39 { i += 1 }
                }
            }
            return Double(String(decoding: bytes[begin..<i], as: UTF8.self))
        }
    }
}
