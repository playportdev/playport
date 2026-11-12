// SPDX-License-Identifier: GPL-3.0-or-later
// A Play iOS ended for memory, as the app saw it (PLA-847). iOS ends a process that passes its
// memory limit (jetsam) with no message and no chance to record anything, and the game runs in the
// app's process. So while a game runs the app reads its footprint (phys_footprint, the counter
// behind the runtime's `[footprint]` lines) and the limit into the Play's session (PlayTime.swift's
// session file, PlayMemory), on disk at every beat and at each step of a climb near the limit. A
// session still on disk when a process starts is a Play whose process ended first. Every end that
// runs code first marks itself beside the session (PlaySessionStore.endMarkURL; the app's WineHost
// play_end.h): a host crash ntdll declines, SIGTERM, exit(), the app in the background or
// terminated. A session with no mark whose last reading was within `nearLimitMB` of the limit was
// ended by iOS for memory, and the game's page says so with the Play's peak and the limit until a
// later Play of the game ends any other way. The app switcher ends an app that is in the
// background or that iOS tells it is terminating, both marked; a SIGKILL nothing announces (a
// `pp ui` run's end, iOS's watchdog) leaves no mark either, and near the limit reads as one.
//
// The app reads its own footprint rather than the runtime's `[footprint]` lines: a release build's
// log stops at its size limit, and with it those lines.
//
// It is an observation, never a requirement: nothing refuses, warns about or sizes a Play from it,
// and no title data carries a memory figure.

import Foundation

/// A Play's memory as the app read it, in MB.
public struct PlayMemory: Codable, Equatable, Sendable {
    /// A step of the footprint near the limit worth a write before the next beat.
    public static let stepMB = 32

    /// The highest footprint read during the Play.
    public var peakMB: Int
    /// The last reading's footprint and limit.
    public var footprintMB: Int
    public var limitMB: Int

    public init(footprintMB: Int, limitMB: Int) {
        peakMB = footprintMB
        self.footprintMB = footprintMB
        self.limitMB = limitMB
    }

    /// The last reading left less than `MemoryKill.nearLimitMB` under the limit.
    public var nearLimit: Bool { limitMB - footprintMB < MemoryKill.nearLimitMB }

    /// Whether this reading goes on disk now rather than at the next beat, given the last one
    /// written: on entering or leaving the zone near the limit, and at each `stepMB` the footprint
    /// moves inside it, so a kill finds its last climb on disk.
    public func needsWrite(after written: PlayMemory?) -> Bool {
        guard let written else { return true }
        if nearLimit != written.nearLimit { return true }
        return nearLimit && abs(footprintMB - written.footprintMB) >= Self.stepMB
    }
}

extension PlaySession {
    /// One reading of the app's footprint and limit; a limit not reported keeps the last one, and
    /// with none yet the reading is dropped.
    public mutating func read(footprintMB: Int, limitMB: Int?) {
        guard let limit = limitMB ?? memory?.limitMB else { return }
        guard var m = memory else {
            memory = PlayMemory(footprintMB: footprintMB, limitMB: limit)
            return
        }
        m.peakMB = max(m.peakMB, footprintMB)
        m.footprintMB = footprintMB
        m.limitMB = limit
        memory = m
    }
}

/// The last Play of a game ended for memory: its peak and the limit, for the game's page.
public struct MemoryKill: Codable, Equatable, Sendable {
    /// Near the limit: run l9's load step rose from 7,174 MB past its 8,192 MB limit between two
    /// 250 ms readings (FootprintJumpTriggerTests), so a kill's last reading can be 1,018 MB under.
    public static let nearLimitMB = 1_024

    public var peakMB: Int
    public var limitMB: Int

    public init(peakMB: Int, limitMB: Int) {
        self.peakMB = peakMB
        self.limitMB = limitMB
    }

    /// The end of a Play whose session its process left on disk: a memory kill when nothing marked
    /// another end and the last reading was near the limit, else nil.
    public init?(leftBy session: PlaySession) {
        guard session.endedBy == nil, let m = session.memory, m.nearLimit else { return nil }
        self.init(peakMB: m.peakMB, limitMB: m.limitMB)
    }
}

extension Catalog {
    /// A Play of `titleID` ended: one iOS ended for memory notes it on the game, replacing an older
    /// note; any other end clears the game's note.
    public mutating func playEnded(_ titleID: String, kill: MemoryKill?) {
        update(titleID) { $0.memoryKill = kill }
    }
}
