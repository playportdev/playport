// SPDX-License-Identifier: GPL-3.0-or-later
// The launch screen (Launch.dc.html): one progress bar over the game's art,
// the step it is on in a word, and the steps (JIT, runtime, game) listed only
// when one failed or JIT is taking long, with what fixes it. What the launch
// did is the app's LaunchCoordinator.Step; this is how the screen reads it.
//
// The bar moves with the steps and within each one eases toward its end over
// the step's usual time, so it never stands still and never reaches the end
// before the game draws: JIT about 3.5 s on the reference phone, the game
// about 6 s from its start to the first frame (Hollow Knight, AGENTS.md).

import Foundation

public enum LaunchStage: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Before JIT: the memory check, the executable, the Steam API files.
    case preparing
    case jit
    case runtime
    /// From the game's start to its first frame.
    case game
    /// The game drew: the screen goes.
    case drawing

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum LaunchProgress {
    /// JIT taking longer than this lists the steps with the fix (LocalDevVPN).
    public static let jitSlow: TimeInterval = 10

    /// The bar's span per stage, and how long the stage usually takes.
    static func span(_ s: LaunchStage) -> (from: Double, to: Double, usual: TimeInterval) {
        switch s {
        case .preparing: (0.0, 0.08, 1)
        case .jit: (0.08, 0.35, 3.5)
        case .runtime: (0.35, 0.5, 1.5)
        case .game: (0.5, 0.97, 6)
        case .drawing: (1, 1, 1)
        }
    }

    /// The bar, 0 to 1, `elapsed` seconds into `stage`.
    public static func fraction(_ stage: LaunchStage, elapsed: TimeInterval) -> Double {
        let s = span(stage)
        let t = max(0, elapsed)
        return s.from + (s.to - s.from) * (1 - exp(-t / s.usual))
    }

    /// Whether the screen lists the steps: one failed, or JIT is slow.
    public static func showsSteps(_ stage: LaunchStage, elapsed: TimeInterval, failed: LaunchStage? = nil) -> Bool {
        failed != nil || (stage == .jit && elapsed >= jitSlow)
    }

    /// The step a failed launch stopped at, from its `title: done` result
    /// (after `nonce=… `): the JIT pool, the runtime (its self-check,
    /// wine_host_init, the session root) or the game (its start, the wait
    /// on it). Nil for a result that is not a failed step: a refusal before
    /// JIT, an exit, a game still running after it ran out of JIT memory.
    public static func failedStage(_ line: String) -> LaunchStage? {
        guard line.hasPrefix("launch=failed ") else { return nil }
        let rest = line.dropFirst("launch=failed ".count)
        if rest.hasPrefix("runtime=JIT pool (") { return .jit }
        if rest.hasPrefix("runtime=") || rest.hasPrefix("selfcheck=") { return .runtime }
        if rest.hasPrefix("run_exe=") || rest.hasPrefix("wait=") { return .game }
        return nil
    }

    /// What the screen says under the bar.
    public static func status(_ stage: LaunchStage) -> String {
        switch stage {
        case .preparing: "Getting ready…"
        case .jit: "Waiting for JIT…"
        case .runtime: "Starting Windows…"
        case .game, .drawing: "Starting the game…"
        }
    }

    /// The listed steps' names.
    public static func stepName(_ stage: LaunchStage) -> String {
        switch stage {
        case .preparing: "Getting ready"
        case .jit: "JIT"
        case .runtime: "Runtime"
        case .game, .drawing: "Game"
        }
    }

    /// The three steps the screen lists and draws as dots.
    public static let steps: [LaunchStage] = [.jit, .runtime, .game]
}
