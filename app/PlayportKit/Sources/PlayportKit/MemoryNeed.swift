// SPDX-License-Identifier: GPL-3.0-or-later
// What a title needs from the app's memory limit, and what a Play does when
// the limit is below it. iOS ends a process that passes its limit (jetsam),
// with no message; the JIT pool and the game share that one limit. The
// Increased Memory Limit entitlement raises it (8 GB on the reference phone once
// Game Mode is on);
// a signer that drops it leaves about 3.3 GB (docs/DISTRIBUTION.md, "Signing
// tools and the memory limit"). The app reads the limit (MemoryLimit.swift)
// and checks each Play against the title's need before any JIT is spent:
//
//   tested title   titles.json `memoryMB`, the footprint it reached on the
//                  reference phone. Below it the Play is refused; below it
//                  plus a quarter the Play goes on with a warning.
//   any other      no measured need: below the runtime's own floor the Play
//                  is refused; below `untestedMB` it goes on with a warning.

import Foundation

public struct MemoryNeed: Equatable, Sendable {
    /// The runtime with a small program: an 896 MiB pool (dirty from blessing; JitPool),
    /// FEX, Wine and the host took 1,235 MB at peak (docs/evidence/2026-09-24-bootstrap.md);
    /// no game fits in less than this. The pool is 512 MiB since decision 0036, so this
    /// now has about 384 MB to spare.
    public static let runtimeFloorMB = 2048
    /// Below this, an untested title is warned about: a 3D game's heap and textures
    /// on top of the runtime (Hollow Knight, a 2D game, reaches about 3 GB).
    public static let untestedMB = 4096

    /// Below this the Play is refused.
    public var minimumMB: Int
    /// Below this the Play goes on with a warning.
    public var recommendedMB: Int
    /// A measured need (a cohort title's `memoryMB`), or the untested default.
    public var measured: Bool

    public init(minimumMB: Int, recommendedMB: Int, measured: Bool) {
        self.minimumMB = minimumMB
        self.recommendedMB = max(minimumMB, recommendedMB)
        self.measured = measured
    }

    /// A title's need: its cohort entry's `memoryMB` (by app ID, else by folder,
    /// whichever way it was installed), else the untested default.
    public static func of(_ t: InstalledTitle, cohort: Cohort) -> MemoryNeed {
        let pin = t.appID.flatMap { app in cohort.titles.first { $0.appID == app } } ?? cohort.title(installDir: t.installDir)
        guard let mb = pin?.memoryMB, mb > 0 else {
            return MemoryNeed(minimumMB: runtimeFloorMB, recommendedMB: untestedMB, measured: false)
        }
        return MemoryNeed(minimumMB: mb, recommendedMB: mb + mb / 4, measured: true)
    }

    public enum Verdict: Equatable, Sendable {
        /// The limit is at least the recommended amount, or it is not known.
        case fits
        /// At least the minimum but below the recommended amount: the Play goes on, with a warning.
        case tight
        /// Below the minimum: iOS would end the game; the Play is refused.
        case tooLow
    }

    /// The Play's verdict under a limit in MB; nil (a limit that could not be read) never refuses.
    public func verdict(limitMB: Int?) -> Verdict {
        guard let limit = limitMB, limit > 0 else { return .fits }
        if limit < minimumMB { return .tooLow }
        if limit < recommendedMB { return .tight }
        return .fits
    }

    /// `launch=refused memory=<limit> need=<minimum>`'s fields, the result line a
    /// refused Play ends with (LaunchCoordinator).
    public static func refusalLine(limitMB: Int, needMB: Int) -> String {
        "launch=refused memory=\(limitMB) need=\(needMB)"
    }

    /// The limit and need of a refusal's result line; nil for any other line.
    public static func parseRefusal(_ line: String) -> (limitMB: Int, needMB: Int)? {
        var limit: Int?, need: Int?
        for field in line.split(separator: " ") {
            let kv = field.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            if kv[0] == "memory" { limit = Int(kv[1]) }
            if kv[0] == "need" { need = Int(kv[1]) }
        }
        guard line.hasPrefix("launch=refused "), let limit, let need else { return nil }
        return (limit, need)
    }

    /// Megabytes as a player reads them: `3.3 GB`, `896 MB`.
    public static func format(mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }
}
