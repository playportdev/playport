// SPDX-License-Identifier: GPL-3.0-or-later
/// The Gyro aim page's test area (GyroAim.dc.html): a dot that follows the
/// aim, fed with GyroAim's output while the page runs the sensors for it
/// (S1Probe's GyroFeed in preview, which sends nothing to the guest).
///
/// The dot is in a unit square, x right and y up, each −1...1, (0, 0) the
/// middle. Mouse output moves it as the view would turn: `mouseSpan` counts
/// (30° at sensitivity 1) from the middle to an edge, kept inside. Right-stick
/// output places it where the stick is deflected, so it comes back to the
/// middle when the device stops, as the game's view stops turning.

public struct GyroPreviewDot: Equatable, Sendable {
    /// Mouse counts from the middle to an edge: 30° at sensitivity 1 (GyroAim.mouseCountsPerDegree).
    public static let mouseSpan = 30 * GyroAim.mouseCountsPerDegree

    public private(set) var x = 0.0
    public private(set) var y = 0.0

    public init() {}

    public mutating func add(_ o: GyroAimOutput) {
        switch o {
        case .none:
            break
        case .mouse(let dx, let dy):
            // Windows' +y is down.
            x = max(-1, min(1, x + Double(dx) / Self.mouseSpan))
            y = max(-1, min(1, y - Double(dy) / Self.mouseSpan))
        case .rightStick(let sx, let sy):
            x = max(-1, min(1, sx))
            y = max(-1, min(1, sy))
        }
    }

    /// Back to the middle (a tap on the test area, the preview starting again).
    public mutating func centre() { x = 0; y = 0 }
}
