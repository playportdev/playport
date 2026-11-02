// SPDX-License-Identifier: GPL-3.0-or-later
/// The game's frame rate and frame time, from the times its frames reached the screen
/// (the performance overlay). Times are monotonic seconds, the same clock for every call.
public struct PresentRate: Sendable {
    /// The window frames per second are counted over.
    public static let window = 1.0
    /// The window the frame time is averaged over; a frame time with fewer than two
    /// frames in it is the latest frame's.
    public static let recent = 0.25
    /// More than a 120 Hz screen shows in a window.
    private static let capacity = 256

    private var times = [Double](repeating: 0, count: capacity)
    private var count = 0
    private var next = 0

    public init() {}

    public mutating func presented(at t: Double) {
        times[next] = t
        next = (next + 1) % Self.capacity
        count = min(count + 1, Self.capacity)
    }

    public struct Reading: Equatable, Sendable {
        /// Frames shown in the last second.
        public let fps: Int
        /// Milliseconds a frame stays on screen now; nil before two frames. With no frame shown
        /// in the last quarter second, the time since the latest one: a stalled game reads as stalled.
        public let frameMS: Double?
    }

    public func reading(now: Double) -> Reading {
        // Newest first.
        let newest = (0..<count).lazy.map { self.times[(self.next - 1 - $0 + Self.capacity) % Self.capacity] }
        guard let last = newest.first else { return Reading(fps: 0, frameMS: nil) }
        let fps = newest.prefix { now - $0 < Self.window }.count
        if now - last > Self.recent { return Reading(fps: fps, frameMS: (now - last) * 1000) }
        let recent = Array(newest.prefix { now - $0 < Self.recent })
        if recent.count >= 2 { return Reading(fps: fps, frameMS: (recent[0] - recent[recent.count - 1]) / Double(recent.count - 1) * 1000) }
        guard count >= 2 else { return Reading(fps: fps, frameMS: nil) }
        let before = times[(next - 2 + Self.capacity) % Self.capacity]
        return Reading(fps: fps, frameMS: (last - before) * 1000)
    }
}
