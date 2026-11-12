// SPDX-License-Identifier: GPL-3.0-or-later
// The running game's session, for its play time (PlayportKit PlayTime.swift)
// and the memory-kill note (PlayportKit MemoryKill.swift): begun when Play
// starts the launch, read every 250 ms on its own queue while the game runs (so
// a busy main thread does not stop it), and ended by TitleLaunch when the game
// ends, before the restart after it (decision 0029). Each reading beats the
// session and takes the app's footprint and memory limit (MemoryLimit); the
// session goes on disk every five seconds, and at once when a reading near the
// limit needs it (PlayMemory.needsWrite), so a process iOS ends there leaves
// its climb behind. A save that fails waits for the next beat or step, and is
// logged once until one succeeds. A session left on disk by a process that
// ended first (a crash, iOS, or the app ended from outside) is added by the
// next process's LibraryModel, up to its last beat, and tells it whether iOS
// ended the game for memory.
//
// While a session runs its end mark is armed (WineHost play_end.h): SIGTERM,
// SIGHUP, exit() and a host fault ntdll declines mark the Play's end beside
// the session, and so do the app going to the background (unmarked when it
// comes back) and iOS terminating it. iOS's memory kill marks nothing.
//
// A dev build's simulated limit (MemoryLimit.simulatedKey) ends the process as
// iOS ends one past its limit, once a reading reaches it, so a memory kill can
// be driven on a phone whose real limit the game stays under.

import Foundation
import PlayportKit
import UIKit
import WineHost

final class PlayClock: @unchecked Sendable {
    static let shared = PlayClock()
    /// Seconds between the session's writes when no reading needs one sooner.
    static let interval: TimeInterval = 5
    /// Between readings, as the runtime's own fast `[footprint]` sampler (PlayportKit MemoryKill).
    static let readInterval = DispatchTimeInterval.milliseconds(250)

    let store = PlaySessionStore(url: LibraryModel.paths.layout.stateRoot.appendingPathComponent("session.json"))
    private let queue = DispatchQueue(label: "playport.playclock")
    /// Guards the session and the timer (a lock, not queue.sync: a block handed to
    /// dispatch_sync is checked for escaping at its file location, which names the source's path).
    private let lock = NSLock()
    private var session: PlaySession?
    /// The session as last handed to the store, and when, whether or not it was saved.
    private var written: (session: PlaySession, at: Date)?
    /// The last save failed: logged once, not at every try.
    private var saveFailed = false
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    private init() {
        // On the posting thread (the main one), so each mark is on disk before the handler returns.
        let nc = NotificationCenter.default
        let marks: [(Notification.Name, String?)] = [
            (UIApplication.didEnterBackgroundNotification, "background"),
            (UIApplication.willEnterForegroundNotification, nil),
            (UIApplication.willTerminateNotification, "terminated"),
        ]
        for (name, why) in marks {
            observers.append(nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.markEnd(why) })
        }
    }

    /// Play started `titleID`'s launch.
    func begin(_ titleID: String) {
        lock.withLock {
            timer?.cancel()
            play_end_arm(store.endMarkURL.path)
            play_end_unmark()
            var s = PlaySession(titleID: titleID)
            read(into: &s)
            session = s
            write(s)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + Self.readInterval, repeating: Self.readInterval, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    /// The game ended: the session with its last beat now, and none on disk. Nil when none ran.
    func end() -> PlaySession? {
        lock.withLock {
            timer?.cancel()
            timer = nil
            play_end_disarm()
            guard var s = session else { return nil }
            s.beat()
            session = nil
            written = nil
            saveFailed = false
            store.clear()
            return s
        }
    }

    /// The app went to the background or iOS is terminating it (`why`), or it came back (nil): while
    /// a session runs, its end is marked as no memory kill, or unmarked again.
    private func markEnd(_ why: String?) {
        lock.withLock {
            guard session != nil else { return }
            if let why { play_end_mark(why) } else { play_end_unmark() }
        }
    }

    private func tick() {
        lock.withLock {
            guard var s = session else { return }
            s.beat()
            let reading = read(into: &s)
            session = s
            let due = written.map { Date().timeIntervalSince($0.at) >= Self.interval } ?? true
            if due || s.memory?.needsWrite(after: written?.session.memory) == true { write(s) }
            endAtSimulatedLimit(reading, s)
        }
    }

    /// A dev build's simulated limit: once a reading reaches it, the session goes on disk and the
    /// process ends as iOS ends one past its limit, with no end mark.
    private func endAtSimulatedLimit(_ reading: MemoryLimit.Reading, _ s: PlaySession) {
        #if !PLAYPORT_RELEASE
        guard let limit = reading.simulatedMB, reading.footprintMB >= limit else { return }
        write(s)
        LibraryModel.log("memory: footprint \(reading.footprintMB) MB reached the simulated limit of \(limit) MB;"
                         + " Playport ends as iOS ends a process past its limit")
        kill(getpid(), SIGKILL)
        #endif
    }

    /// One reading of the app's footprint and the limit a Play has (a dev build's simulated one first).
    @discardableResult
    private func read(into s: inout PlaySession) -> MemoryLimit.Reading {
        let r = MemoryLimit.read()
        s.read(footprintMB: r.footprintMB, limitMB: r.effectiveMB)
        return r
    }

    private func write(_ s: PlaySession) {
        written = (s, Date())
        do {
            try store.save(s)
            saveFailed = false
        } catch {
            if !saveFailed { LibraryModel.log("play session not saved: \(error); tried again at the next beat") }
            saveFailed = true
        }
    }
}
