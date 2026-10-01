// SPDX-License-Identifier: GPL-3.0-or-later
/// What the host received from GameController and what it forwarded, as lines
/// for s1-host.log. With these lines a run shows where each mouse and pad
/// chain stops: handler never called, called but nothing whole to
/// push, pushed but not drained (Winios's `[winios] drain` lines), or written
/// to the pad block but not read.
public struct InputTrace: Equatable, Sendable {
    /// mouseMovedHandler calls, and the deltas they carried (Windows orientation).
    public var mouseMoves = 0
    public var mouseDX = 0.0, mouseDY = 0.0
    /// winios_pointer MOVE pushes, and the whole pixels they carried.
    public var mousePushes = 0
    public var pushedDX = 0, pushedDY = 0
    /// Mouse button changes and wheel events forwarded.
    public var mouseButtons = 0, wheel = 0
    /// UIKit touch callbacks on the game surface: finger touches (forwarded)
    /// and pointer ones (a mouse or trackpad seen by UIKit; dropped, since the
    /// mouse is meant to come through GCMouse).
    public var touches = 0, pointerTouches = 0
    /// UIHoverGestureRecognizer callbacks on the game surface (counted only).
    public var hover = 0
    /// valueChangedHandler calls per slot, and the values last written to the block.
    public var padCalls: [Int: Int] = [:]
    public var pads: [Int: PadValues] = [:]

    public init() {}

    public mutating func mouseMoved(dx: Double, dy: Double, pushed: (Int32, Int32)?) {
        mouseMoves += 1
        mouseDX += dx
        mouseDY += dy
        if let p = pushed {
            mousePushes += 1
            pushedDX += Int(p.0)
            pushedDY += Int(p.1)
        }
    }

    /// Records a pad write. Returns a line to log now when a button or a
    /// trigger's pressed state changed (sticks move too often; they are in
    /// the summary), nil otherwise.
    public mutating func pad(slot: Int, _ v: PadValues) -> String? {
        padCalls[slot, default: 0] += 1
        let old = pads[slot]
        pads[slot] = v
        guard old == nil || old!.buttons != v.buttons || (old!.leftTrigger == 0) != (v.leftTrigger == 0)
                || (old!.rightTrigger == 0) != (v.rightTrigger == 0) else { return nil }
        return "hostio: " + Self.describe(slot: slot, v)
    }

    /// One line for what changed since `last`, or nil when nothing did.
    public func summary(since last: InputTrace) -> String? {
        var parts: [String] = []
        if mouseMoves != last.mouseMoves || mouseButtons != last.mouseButtons || wheel != last.wheel {
            parts.append("mouse moves=\(mouseMoves - last.mouseMoves) d=(\(Self.fixed(mouseDX - last.mouseDX)),\(Self.fixed(mouseDY - last.mouseDY)))"
                + " pushes=\(mousePushes - last.mousePushes) px=(\(pushedDX - last.pushedDX),\(pushedDY - last.pushedDY))"
                + " buttons=\(mouseButtons - last.mouseButtons) wheel=\(wheel - last.wheel)")
        }
        if touches != last.touches || pointerTouches != last.pointerTouches || hover != last.hover {
            parts.append("touches finger=\(touches - last.touches) pointer=\(pointerTouches - last.pointerTouches) hover=\(hover - last.hover)")
        }
        for slot in padCalls.keys.sorted() where padCalls[slot] != last.padCalls[slot] {
            parts.append("\(Self.describe(slot: slot, pads[slot] ?? PadValues())) calls=\((padCalls[slot] ?? 0) - (last.padCalls[slot] ?? 0))")
        }
        return parts.isEmpty ? nil : "hostio: input " + parts.joined(separator: "; ")
    }

    public static func describe(slot: Int, _ v: PadValues) -> String {
        let hex = String(v.buttons, radix: 16)
        return "pad\(slot) buttons=0x\(String(repeating: "0", count: max(0, 4 - hex.count)) + hex)"
            + " lt=\(v.leftTrigger) rt=\(v.rightTrigger) l=(\(v.lx),\(v.ly)) r=(\(v.rx),\(v.ry))"
    }

    static func fixed(_ d: Double) -> String {
        let r = (d * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(r)
    }
}
