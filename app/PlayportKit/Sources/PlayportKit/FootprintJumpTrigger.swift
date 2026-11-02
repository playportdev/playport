// SPDX-License-Identifier: GPL-3.0-or-later
// When a dev build's footprint-jump sampler (S1Probe Dev/FootprintJumpSampler.swift, PLA-476)
// takes a memory sample near the limit: an extended TASK_VM_INFO line, a donor-pool stats line
// and a forced `[proc-mem]` walk. Run l9's last `[proc-mem]` came 9.9 s before its load step
// because the unforced walk waits ten times its own cost; this rule forces samples as the
// footprint climbs and inside a step.
//
// The sampler ticks every 250 ms. Below the limit less `armBelowLimitMB` nothing fires. The
// first tick at or above it fires (`armed`), and its footprint is the level the next counts
// from. Then a tick fires when:
// - `level`: the footprint is `levelStepMB` or more above the last firing's, and the last
//   firing is `spacingS` or more ago;
// - `jump`: it rose `jumpMB` or more since the previous tick, even inside the spacing (the
//   load step that ended l9 came 2.3-4.9 s after any level firing).
// While the previous firing's walk is still running (`busy`, a forced walk takes about 750 ms
// under load) only a jump fires, and without a walk: the sampler logs its TASK_VM_INFO line
// alone (run l10's step came in one tick and the kill cut the walk it started).

public struct FootprintJumpTrigger: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case armed, level, jump
    }

    /// A tick's firing: why, and whether the sampler also runs the donor-pool line and the walk.
    public struct Firing: Equatable, Sendable {
        public let reason: Reason
        public let walks: Bool

        public init(_ reason: Reason, walks: Bool) {
            self.reason = reason
            self.walks = walks
        }
    }

    /// The sampler's tick.
    public static let tickMS = 250
    /// It arms at the limit less this.
    public static let armBelowLimitMB = 2_000
    /// A firing's rise over the last firing's footprint.
    public static let levelStepMB = 300
    /// A firing's rise over the previous tick.
    public static let jumpMB = 300
    /// The least time between a level firing and the firing before it.
    public static let spacingS: Double = 5

    /// The footprint at the last firing.
    public private(set) var lastFiredMB: Int?
    public private(set) var lastFiredAt: Double?
    private var previousMB: Int?

    public init() {}

    /// One tick at `elapsed` seconds: the app's footprint and limit now, and whether the last
    /// firing's walk is still running. The firing when this tick fires.
    public mutating func tick(at elapsed: Double, footprintMB: Int, limitMB: Int?, busy: Bool) -> Firing? {
        let previous = previousMB
        previousMB = footprintMB
        guard let limitMB, footprintMB >= limitMB - Self.armBelowLimitMB else { return nil }
        let reason: Reason
        if let lastMB = lastFiredMB, let lastAt = lastFiredAt {
            if let previous, footprintMB - previous >= Self.jumpMB {
                reason = .jump
            } else if !busy, footprintMB - lastMB >= Self.levelStepMB, elapsed - lastAt >= Self.spacingS {
                reason = .level
            } else {
                return nil
            }
        } else if !busy {
            reason = .armed
        } else {
            return nil
        }
        lastFiredMB = footprintMB
        lastFiredAt = elapsed
        return Firing(reason, walks: !busy)
    }
}
