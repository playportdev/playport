// SPDX-License-Identifier: GPL-3.0-or-later
/// Pointer input: touches on the presented image, and a mouse's raw motion.
public enum Pointer {
    /// MOUSEEVENTF_* flags (winuser.h); Winios forwards them unchanged.
    public static let move: UInt32 = 0x0001
    public static let leftDown: UInt32 = 0x0002
    public static let leftUp: UInt32 = 0x0004
    public static let rightDown: UInt32 = 0x0008
    public static let rightUp: UInt32 = 0x0010
    public static let middleDown: UInt32 = 0x0020
    public static let middleUp: UInt32 = 0x0040
    public static let wheel: UInt32 = 0x0800

    /// A touch at (x, y) in a view of width × height that shows the swap
    /// chain stretched to fill it (CAMetalLayer's default contentsGravity):
    /// the same fraction of the client area, as 0...65535. nil outside the view.
    public static func clientFraction(x: Double, y: Double, width: Double, height: Double) -> (Int32, Int32)? {
        guard width > 0, height > 0, x >= 0, y >= 0, x < width, y < height else { return nil }
        return (Int32(min(65535, (x / width * 65536).rounded(.down))), Int32(min(65535, (y / height * 65536).rounded(.down))))
    }
}

/// Mouse motion arrives as fractional deltas (GCMouse); Wine takes whole
/// pixels. Whole parts go out, the rest is carried, so slow motion is not lost.
public struct RelativeMotion {
    private var rx = 0.0, ry = 0.0
    public init() {}

    /// dx, dy in Windows orientation (+y down). Returns nil when nothing whole is due.
    public mutating func add(dx: Double, dy: Double) -> (Int32, Int32)? {
        rx += dx
        ry += dy
        let ix = rx.rounded(.towardZero), iy = ry.rounded(.towardZero)
        rx -= ix
        ry -= iy
        return ix == 0 && iy == 0 ? nil : (Int32(ix), Int32(iy))
    }

    public mutating func reset() { rx = 0; ry = 0 }
}
