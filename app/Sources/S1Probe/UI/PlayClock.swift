// SPDX-License-Identifier: GPL-3.0-or-later
// The running game's session, for its play time (PlayportKit PlayTime.swift):
// begun when Play starts the launch, beaten every five seconds on its own
// queue while the game runs (so a busy main thread does not stop it), and
// ended by TitleLaunch when the game ends, before the restart after it
// (decision 0029). A session left on disk by a process that ended first (a
// crash, or the app ended from outside) is added by the next process's
// LibraryModel, up to its last beat.

import Foundation
import PlayportKit

final class PlayClock: @unchecked Sendable {
    static let shared = PlayClock()
    /// Seconds between beats.
    static let interval = 5

    let store = PlaySessionStore(url: LibraryModel.paths.layout.stateRoot.appendingPathComponent("session.json"))
    private let queue = DispatchQueue(label: "playport.playclock")
    /// Guards the session and the timer (a lock, not queue.sync: a block handed to
    /// dispatch_sync is checked for escaping at its file location, which names the source's path).
    private let lock = NSLock()
    private var session: PlaySession?
    private var timer: DispatchSourceTimer?

    /// Play started `titleID`'s launch.
    func begin(_ titleID: String) {
        lock.withLock {
            timer?.cancel()
            let s = PlaySession(titleID: titleID)
            session = s
            write(s)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .seconds(Self.interval), repeating: .seconds(Self.interval), leeway: .seconds(1))
            t.setEventHandler { [weak self] in self?.beat() }
            t.resume()
            timer = t
        }
    }

    /// The game ended: the session with its last beat now, and none on disk. Nil when none ran.
    func end() -> PlaySession? {
        lock.withLock {
            timer?.cancel()
            timer = nil
            guard var s = session else { return nil }
            s.beat()
            session = nil
            store.clear()
            return s
        }
    }

    private func beat() {
        lock.withLock {
            guard var s = session else { return }
            s.beat()
            session = s
            write(s)
        }
    }

    private func write(_ s: PlaySession) {
        do {
            try store.save(s)
        } catch {
            LibraryModel.log("play session not saved: \(error)")
        }
    }
}
