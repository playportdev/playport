// SPDX-License-Identifier: GPL-3.0-or-later
// Where the focus ring goes when the player presses a direction
// (UI/Pad/PadFocus.swift): the nearest item that way, measured on screen, so
// a grid, a list and a row of tiles under a wide card all move the way they look.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // CGRect's geometry on Apple platforms; Foundation has it on Linux
#endif

public enum FocusDirection: String, CaseIterable, Sendable {
    case up, down, left, right
}

public enum FocusMove {
    /// The item the focus moves to from `from` in direction `d`; nil when
    /// nothing lies that way. An item counts when its centre is past `from`'s
    /// centre and its near edge is not behind `from`'s near edge. The nearest
    /// gap along the direction wins; an item beside the lane `from` spans
    /// pays twice its offset across it, and among items in the lane the one
    /// that shares most of the lane wins, then the one whose leading edge
    /// (left, or top) is closest to `from`'s, so down from a wide card lands
    /// on the first tile wholly under it.
    public static func next(from: CGRect, _ d: FocusDirection, among items: [String: CGRect]) -> String? {
        var best: (id: String, score: CGFloat)?
        for (id, r) in items.sorted(by: { $0.key < $1.key }) where r != from {
            let gap: CGFloat, across: CGFloat, overlap: CGFloat
            switch d {
            case .right:
                guard r.midX > from.midX, r.minX >= from.minX else { continue }
                gap = max(0, r.minX - from.maxX)
            case .left:
                guard r.midX < from.midX, r.maxX <= from.maxX else { continue }
                gap = max(0, from.minX - r.maxX)
            case .down:
                guard r.midY > from.midY, r.minY >= from.minY else { continue }
                gap = max(0, r.minY - from.maxY)
            case .up:
                guard r.midY < from.midY, r.maxY <= from.maxY else { continue }
                gap = max(0, from.minY - r.maxY)
            }
            switch d {
            case .left, .right:
                overlap = min(r.maxY, from.maxY) - max(r.minY, from.minY)
                across = overlap > 0
                    ? min(r.height, from.height) - overlap + abs(r.minY - from.minY) / 100
                    : 2 * abs(r.midY - from.midY)
            case .up, .down:
                overlap = min(r.maxX, from.maxX) - max(r.minX, from.minX)
                across = overlap > 0
                    ? min(r.width, from.width) - overlap + abs(r.minX - from.minX) / 100
                    : 2 * abs(r.midX - from.midX)
            }
            let score = gap + across
            if best == nil || score < best!.score { best = (id, score) }
        }
        return best?.id
    }

    /// Where the focus starts on a screen: the item nearest the top left,
    /// row by row.
    public static func first(among items: [String: CGRect]) -> String? {
        items.min { a, b in
            (a.value.minY, a.value.minX, a.key) < (b.value.minY, b.value.minX, b.key)
        }?.key
    }
}
