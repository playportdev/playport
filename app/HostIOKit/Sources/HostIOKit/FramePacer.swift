// SPDX-License-Identifier: GPL-3.0-or-later
/// A frame rate limiter's timing: how long to hold each frame so frames start
/// at most `fps` times a second, on a fixed schedule that resyncs after a late frame.
public struct FramePacer: Sendable {
    public private(set) var interval: Double
    private var next: Double?

    /// 0 or less: no limit.
    public init(fps: Int) {
        interval = fps > 0 ? 1.0 / Double(fps) : 0
    }

    /// The seconds to wait before a frame that arrives at `now` (a monotonic time in seconds).
    public mutating func delay(now: Double) -> Double {
        guard interval > 0 else { return 0 }
        guard let due = next, due > now else {
            next = now + interval
            return 0
        }
        next = due + interval
        return due - now
    }
}
