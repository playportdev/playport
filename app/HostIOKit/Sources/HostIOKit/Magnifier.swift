// SPDX-License-Identifier: GPL-3.0-or-later
/// Point & click's magnifier (TouchPointer.dc.html): while a finger points with
/// tap to click (`TouchControls.magnifier`), a round loupe above it shows the
/// game's picture around the point `zoom` times as large, so a fingertip can
/// aim at something smaller than itself. Geometry only: the app copies `source`
/// out of the frame on screen and draws it in `loupe`, with a mark at `mark`.
///
/// - The loupe's centre is `lift` points above the finger. With no room above
///   (near the top) it is beside the finger instead, to the right, or to the
///   left near the right edge; it is always kept inside the view.
/// - The point is the finger's, kept inside the picture: a finger over a black
///   bar points at the picture's edge, as the pointer surface places it.
/// - `source` is the square of the picture's pixels around the point, kept
///   inside the picture: at an edge the mark moves off the loupe's middle to
///   where the point is.
public struct Magnifier: Equatable, Sendable {
    public static let diameter = 92.0
    public static let zoom = 2.0
    public static let lift = 72.0

    /// A rectangle of the picture's pixels, +y down.
    public struct Pixels: Equatable, Sendable {
        public var x: Int, y: Int, width: Int, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
    }

    /// Where the loupe is drawn, in the view's points.
    public var loupe: TouchRect
    /// The picture's pixels it shows, scaled to fill it.
    public var source: Pixels
    /// Where the point is in the loupe, 0...1 each way from its top left.
    public var mark: TouchPoint

    /// A finger at p; the picture fills `picture` in the view (the swap chain
    /// aspect-fitted) and is `texture` pixels; the view is `bounds`. Nil with no picture.
    public init?(at p: TouchPoint, picture: TouchRect, texture: (width: Int, height: Int), bounds: TouchRect) {
        guard picture.width > 0, picture.height > 0, texture.width > 0, texture.height > 0 else { return nil }
        let sx = Double(texture.width) / picture.width, sy = Double(texture.height) / picture.height
        let fx = (min(max(p.x, picture.x), picture.x + picture.width) - picture.x) * sx
        let fy = (min(max(p.y, picture.y), picture.y + picture.height) - picture.y) * sy
        let side = max(1, min(Int((Self.diameter / Self.zoom * sx).rounded()), texture.width, texture.height))
        let x = min(max(Int((fx - Double(side) / 2).rounded()), 0), texture.width - side)
        let y = min(max(Int((fy - Double(side) / 2).rounded()), 0), texture.height - side)
        source = Pixels(x: x, y: y, width: side, height: side)
        mark = TouchPoint(x: (fx - Double(x)) / Double(side), y: (fy - Double(y)) / Double(side))

        let r = Self.diameter / 2
        var c = TouchPoint(x: p.x, y: p.y - Self.lift)
        if c.y - r < bounds.y {
            c = TouchPoint(x: p.x + Self.lift + r > bounds.x + bounds.width ? p.x - Self.lift : p.x + Self.lift, y: p.y)
        }
        let lx = min(max(c.x - r, bounds.x), bounds.x + bounds.width - Self.diameter)
        let ly = min(max(c.y - r, bounds.y), bounds.y + bounds.height - Self.diameter)
        loupe = TouchRect(x: lx, y: ly, width: Self.diameter, height: Self.diameter)
    }
}
