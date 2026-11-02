// SPDX-License-Identifier: GPL-3.0-or-later
// The launch screen (Launch.dc.html): one progress bar over the game's art,
// the step it is on in a word, and the steps (JIT, runtime, game, and the
// dependencies for a Play that installs some) listed only when one failed or
// JIT is taking long, with what fixes it. What the launch did is the app's
// LaunchCoordinator.Step; this is how the screen reads it (decision 0095).
//
// The bar moves with the steps and within each one eases toward its end over
// the step's usual time, so it never stands still and never reaches the end
// before the game draws: JIT about 3.5 s on the reference phone, the game
// about 6 s from its start to the first frame (Hollow Knight, AGENTS.md). The
// dependencies' span is split between the installs the Play runs, and one that
// runs long shows its seconds.

import Foundation

public enum LaunchStage: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Before JIT: the memory check, the executable, the Steam API files.
    case preparing
    case jit
    case runtime
    /// The title's dependency installers (its prerequisites, decision 0079), before the game.
    case prerequisites
    /// From the game's start to its first frame.
    case game
    /// The game drew: the screen goes.
    case drawing

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Which of a Play's dependency installs is running: the `index`-th (from 1) of the `count`
/// its prefix still needs (LaunchCoordinator counts them before the first starts).
public struct LaunchPart: Equatable, Sendable {
    public var index: Int
    public var count: Int

    public init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }
}

public enum LaunchProgress {
    /// JIT taking longer than this lists the steps with the fix (LocalDevVPN).
    public static let jitSlow: TimeInterval = 10
    /// A dependency install running longer than this shows its seconds under the bar.
    public static let dependencySlow: TimeInterval = 10
    /// The game's stage running longer than this shows its seconds under the bar.
    public static let gameSlow: TimeInterval = 30
    /// With no first frame and no guest window by then, the launch screen uncovers the title's
    /// screen this long after the game started: a game whose frames never pass the game layer still
    /// shows. A Play may hold it longer (BattleNetPlay.Launch.uncoverWithoutFrame).
    public static let uncoverWithoutFrame: TimeInterval = 30

    /// The bar's span per stage, and how long the stage usually takes.
    static func span(_ s: LaunchStage) -> (from: Double, to: Double, usual: TimeInterval) {
        switch s {
        case .preparing: (0.0, 0.08, 1)
        case .jit: (0.08, 0.35, 3.5)
        case .runtime: (0.35, 0.5, 1.5)
        case .prerequisites: (0.5, 0.6, 30)
        case .game: (0.6, 0.97, 6)
        case .drawing: (1, 1, 1)
        }
    }

    /// The bar, 0 to 1, `elapsed` seconds into `stage`, or into `part` of the dependencies:
    /// each install gets its share of their span and eases toward its end over the usual time.
    public static func fraction(_ stage: LaunchStage, elapsed: TimeInterval, part: LaunchPart? = nil) -> Double {
        var s = span(stage)
        if stage == .prerequisites, let p = part, p.count > 0 {
            let share = (s.to - s.from) / Double(p.count)
            let i = Double(min(max(p.index, 1), p.count) - 1)
            s = (s.from + share * i, s.from + share * (i + 1), s.usual)
        }
        let t = max(0, elapsed)
        return s.from + (s.to - s.from) * (1 - exp(-t / s.usual))
    }

    /// Whether the screen lists the steps: one failed, or JIT is slow.
    public static func showsSteps(_ stage: LaunchStage, elapsed: TimeInterval, failed: LaunchStage? = nil) -> Bool {
        failed != nil || (stage == .jit && elapsed >= jitSlow)
    }

    /// The step a failed launch stopped at, from its `title: done` result
    /// (after `nonce=… `): the JIT pool, the runtime (its self-check,
    /// wine_host_init, the session root), a dependency (one that would not end, or the
    /// wait on one: `prerequisite=` among the fields) or the game (its start, the wait on
    /// it). Nil for a result that is not a failed step: a refusal before
    /// JIT, an exit, a game still running after it ran out of JIT memory.
    public static func failedStage(_ line: String) -> LaunchStage? {
        guard line.hasPrefix("launch=failed ") else { return nil }
        let rest = line.dropFirst("launch=failed ".count)
        if rest.hasPrefix("runtime=JIT pool (") { return .jit }
        if rest.hasPrefix("runtime=") || rest.hasPrefix("selfcheck=") { return .runtime }
        if rest.split(separator: " ").contains(where: { $0.hasPrefix("prerequisite=") }) { return .prerequisites }
        if rest.hasPrefix("run_exe=") || rest.hasPrefix("wait=") { return .game }
        return nil
    }

    /// What the screen says under the bar, `elapsed` seconds into `stage` (or into `part` of the
    /// dependencies): which install of how many, and its seconds once it, or the game's start, runs long.
    public static func status(_ stage: LaunchStage, part: LaunchPart? = nil, elapsed: TimeInterval = 0) -> String {
        switch stage {
        case .preparing: "Getting ready…"
        case .jit: "Waiting for JIT…"
        case .runtime: "Starting Windows…"
        case .prerequisites:
            "Installing dependencies"
                + (part.map { $0.count > 1 ? " (\($0.index) of \($0.count))" : "" } ?? "") + "…"
                + (elapsed >= dependencySlow ? " \(Int(elapsed)) s" : "")
        case .game: "Starting the game…" + (elapsed >= gameSlow ? " \(Int(elapsed)) s" : "")
        case .drawing: "Starting the game…"
        }
    }

    /// What the screen across Playport's restart between a title's dependencies and the game
    /// says (decisions 0084, 0094, 0095): the old process's last screen and the new one's first.
    public static func continuing(title: String) -> String {
        "Dependencies installed. " + (title.isEmpty ? "Starting the game…" : "Starting \(title)…")
    }

    /// The listed steps' names.
    public static func stepName(_ stage: LaunchStage) -> String {
        switch stage {
        case .preparing: "Getting ready"
        case .jit: "JIT"
        case .runtime: "Runtime"
        case .prerequisites: "Dependencies"
        case .game, .drawing: "Game"
        }
    }

    /// The steps the screen lists and draws as dots: JIT, runtime and game, with the
    /// dependencies between the runtime and the game for a Play that installs some.
    public static func steps(dependencies: Bool) -> [LaunchStage] {
        dependencies ? [.jit, .runtime, .prerequisites, .game] : [.jit, .runtime, .game]
    }
}
