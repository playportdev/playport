// SPDX-License-Identifier: GPL-3.0-or-later
// The download queue from the UI: installs, updates, repairs and imports, one
// job at a time and the rest queued, in the order PlayportKit's DownloadQueue
// keeps, each keyed by its game's store identity (decision 0057). What a job
// does is its store's driver's (DownloadDriver): Steam's (SteamInstalls.swift),
// the import from Files (Import.swift). The queue is written to the container
// after every change (DownloadQueueStore), because Playport restarts after
// every game (decision 0029): a game's launch holds every job (decision 0004),
// and the new process lets go of every hold but the player's Pause and carries
// on once each job's driver may run it (Steam signed in, the network). Only
// when that restart failed does this process keep them held (InstallCopy.afterLaunch).
//
// A job stops, with its stage kept for resume, on Pause, on a launch, on any
// failure, and when its driver can no longer run it (Steam signed out, a
// network Settings › Downloads does not allow); it then waits its turn again.
// Downloads run in the foreground only: the screen stays on while one runs
// (Download mode dims it, DownloadModeView.swift), and iOS suspending the app pauses it.

import Combine
import Foundation
import PlayportKit
import SteamClientKit
import UIKit

/// What runs one store's jobs.
@MainActor
protocol DownloadDriver: AnyObject {
    /// Why this store's jobs cannot start now (not signed in, the network), or nil.
    var blocker: String? { get }
    /// Runs the job to its end; returns the bytes to show in Done today, when known.
    func run(_ job: DownloadJob, progress: @escaping @Sendable (InstallEngine.Progress) -> Void) async throws -> UInt64?
    /// After a job finished well.
    func finished(_ job: DownloadJob)
    /// Cancel: deletes what the job staged.
    func discard(_ key: StoreGameKey)
    /// What the player is told when a job stopped with `error`.
    func reason(_ error: Error) -> String
}

@MainActor
final class Downloads: ObservableObject {
    typealias Kind = DownloadJob.Kind

    /// A job as the screens show it: the queue's record and, for the running one, its progress.
    struct Job: Identifiable {
        enum Phase: Equatable {
            case queued, preparing, downloading, finishing
            /// Stopped with the stage kept; the reason when it was not the player's Pause.
            case paused(String?)
        }

        var record: DownloadJob
        var phase: Phase
        var progress: InstallEngine.Progress?
        /// Bytes a second over the last seconds, while it downloads.
        var rate: Double?
        /// Why a waiting job is not running now (the network, Steam), when not simply its turn.
        var waitingFor: String?

        var key: StoreGameKey { record.key }
        var appID: UInt32? { record.appID }
        var name: String { record.name }
        var kind: Kind { record.kind }
        var branch: String? { record.branch }
        var id: StoreGameKey { key }

        var isRunning: Bool {
            switch phase {
            case .preparing, .downloading, .finishing: true
            case .queued, .paused: false
            }
        }

        var fraction: Double? {
            guard let p = progress, p.bytesTotal > 0 else { return nil }
            return Double(p.bytesDone) / Double(p.bytesTotal)
        }

        /// `1.20 GB of 5.31 GB · 12.4 MB/s`
        var detail: String? {
            guard let p = progress else { return nil }
            return "\(ByteCount.format(p.bytesDone)) of \(ByteCount.format(p.bytesTotal))"
                + (phase == .downloading ? rate.map { " · " + DownloadRate.speed($0) } ?? "" : "")
        }

        /// Bytes still to fetch: the running job's, else the store's size for a job not begun.
        var remaining: UInt64? {
            if let p = progress { return p.bytesTotal > p.bytesDone ? p.bytesTotal - p.bytesDone : 0 }
            return record.bytes
        }

        /// `about 4 min left`, while it downloads at a known speed.
        var timeLeft: String? {
            guard phase == .downloading, let r = remaining, let s = DownloadRate.seconds(remaining: r, rate: rate) else { return nil }
            return DownloadRate.duration(s) + " left"
        }

        var status: String {
            switch phase {
            case .queued: return waitingFor ?? "Waiting"
            case .preparing: return kind == .repair ? "Checking files…" : "Preparing…"
            case .downloading:
                let verb = kind == .repair ? "Repairing" : kind == .update ? "Updating" : kind == .import ? "Copying" : "Downloading"
                return fraction.map { "\(verb) \(Int($0 * 100))%" } ?? verb
            case .finishing: return "Finishing…"
            case .paused: return "Paused"
            }
        }
    }

    /// The queue as the screens show it, by game; `order` is its order.
    @Published private(set) var jobs: [StoreGameKey: Job] = [:]
    /// What finished today, newest first (the Downloads page's Done today).
    @Published private(set) var doneToday: [DoneDownload] = []
    /// Why no job runs now although one waits (not signed in, the network), else nil.
    @Published private(set) var blocked: String?
    /// A title has launched in this process and the restart after it failed:
    /// no download starts again until Playport is reopened.
    @Published private(set) var suspended = false

    private var queue: DownloadQueue {
        didSet { if queue != oldValue { saveQueue() } }
    }
    private let store: DownloadQueueStore
    private var drivers: [Store: DownloadDriver] = [:]
    private var active: (key: StoreGameKey, task: Task<Void, Never>)?
    private var progress: [StoreGameKey: InstallEngine.Progress] = [:]
    private var rate = DownloadRate()
    private var ratePerSecond: Double?
    /// Jobs stopped on purpose: what happens to them once the cancel lands.
    enum Stop { case hold(DownloadJob.Hold), requeue, cancel }
    private var stopping: [StoreGameKey: Stop] = [:]
    private var lastLogged: Date = .distantPast
    private var cancellables: Set<AnyCancellable> = []

    init() {
        // Resolved now, before a launch moves HOME into the prefix (SteamPaths).
        store = DownloadQueueStore(url: SteamPaths.downloads)
        var q = store.load()
        // A new process: what a game's launch (or a failure) held waits its turn again.
        q.afterRestart()
        q.prune(now: Date())
        queue = q
        if !q.jobs.isEmpty {
            SteamUILog.logger.info("install", "queue loaded: " + q.jobs.map { "\($0.key) \($0.kind.rawValue)\($0.hold == nil ? "" : " held")" }.joined(separator: ", "))
        }
        saveQueue()
        rebuild()
        NetworkPath.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.conditionsChanged() } }
            .store(in: &cancellables)
    }

    /// `driver` runs `store`'s jobs from now on.
    func register(_ driver: DownloadDriver, for store: Store) {
        drivers[store] = driver
        rebuild()
        pump()
    }

    var layout: InstallLayout { LibraryModel.paths.layout }
    var isBusy: Bool { active != nil }
    /// The running job, then the rest in the order they start (Home's Downloading and Up next, Downloads).
    var order: [Job] {
        let running = active.flatMap { jobs[$0.key] }
        return (running.map { [$0] } ?? []) + queue.jobs.filter { $0.key != active?.key }.compactMap { jobs[$0.key] }
    }
    var running: StoreGameKey? { active?.key }
    var runningAppID: UInt32? { active?.key.steamAppID }
    func record(_ key: StoreGameKey) -> DownloadJob? { queue.job(key) }

    // MARK: actions

    /// Queues `job`, or lets go of its hold (a Resume); behind a running job.
    func enqueue(_ job: DownloadJob) {
        if job.key == active?.key {
            // Resumed while its pause is still winding down: it waits its turn
            // again once the stop lands, and starts from the kept stage.
            if stopping[job.key] != nil {
                stopping[job.key] = .requeue
                queue.hold(job.key, nil)
                rebuild()
            }
            return
        }
        queue.add(job)
        rebuild()
        pump()
    }

    func resume(_ key: StoreGameKey) {
        guard let job = queue.job(key), job.hold != nil else { return }
        enqueue(job)
    }

    func pause(_ key: StoreGameKey) { stop(key, .hold(.player)) }

    /// Y, "Download next": the job goes to the front, behind the one running.
    func downloadNext(_ key: StoreGameKey) {
        guard key != active?.key else { return }
        queue.moveToFront(key, running: active?.key)
        SteamUILog.logger.info("install", "\(key): moved to the front")
        rebuild()
        pump()
    }

    /// Cancel: stops the job, if any, takes it out of the queue and deletes what it staged.
    func discard(_ key: StoreGameKey) {
        if active?.key == key {
            stopping[key] = .cancel
            active?.task.cancel()
        }
        queue.remove(key)
        progress[key] = nil
        rebuild()
        drivers[key.store]?.discard(key)
        SteamUILog.logger.info("install", "\(key): cancelled, staged work discarded")
        pump()
    }

    /// Holds a job without running it (an import whose source must be picked again).
    func hold(_ key: StoreGameKey, _ hold: DownloadJob.Hold) {
        stop(key, .hold(hold))
    }

    /// A title launch: every job is held, and the next process resumes them;
    /// none starts again in this one.
    func holdForLaunch() {
        suspended = true
        holdAll(.launch) { _ in true }
    }

    /// Holds `store`'s waiting and running jobs (a sign-out).
    func holdAll(of store: Store, _ hold: DownloadJob.Hold) {
        holdAll(hold) { $0.key.store == store }
    }

    private func holdAll(_ hold: DownloadJob.Hold, where match: (DownloadJob) -> Bool) {
        for job in queue.jobs where job.hold == nil && match(job) {
            if job.key == active?.key { stop(job.key, .hold(hold)) } else { queue.hold(job.key, hold) }
        }
        rebuild()
        updateIdleTimer()
    }

    /// A driver's conditions changed (signed in, the network): a running job it may
    /// no longer run waits its turn again, and the queue looks for one to start.
    func conditionsChanged(letGoOf store: Store? = nil, stopBlocked: Bool = true) {
        if let store, !suspended {
            // Its jobs held by the stop that preceded (a sign-out, a failure) wait their turn again.
            for job in queue.jobs where job.key.store == store {
                if case .stopped? = job.hold { queue.hold(job.key, nil) }
                if job.hold == .launch { queue.hold(job.key, nil) }
            }
        }
        // The published values change after objectWillChange: look on the next turn.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if stopBlocked, let running = self.active?.key, let why = self.drivers[running.store]?.blocker {
                    SteamUILog.logger.info("install", "\(running): stopped, \(why)")
                    self.stop(running, .requeue)
                }
                self.rebuild()
                self.pump()
            }
        }
    }

    /// Queues the automatic updates among `candidates` (PlayportKit DownloadQueue.automaticUpdates).
    func queueAutomaticUpdates(_ candidates: [UpdateCandidate]) {
        let found = queue.automaticUpdates(candidates, enabled: DownloadPreferences.current.autoUpdate)
        guard !found.isEmpty else { return }
        for job in found {
            SteamUILog.logger.info("install", "\(job.key): update to build \(job.buildID.map(String.init) ?? "?") queued by itself")
            queue.add(job)
        }
        rebuild()
        pump()
    }

    // MARK: running

    private func stop(_ key: StoreGameKey, _ how: Stop) {
        if active?.key == key {
            stopping[key] = how
            active?.task.cancel()
            // On disk at once: the process may end (a launch's restart) before the cancel lands.
            if case let .hold(h) = how { queue.hold(key, h) }
            rebuild()
        } else if case let .hold(h) = how {
            queue.hold(key, h)
            rebuild()
        }
    }

    /// Why `job` may not start now, or nil.
    private func blocker(_ job: DownloadJob) -> String? {
        if suspended { return nil }   // the jobs say it themselves (InstallCopy.afterLaunch)
        guard let driver = drivers[job.key.store] else { return "Waiting for \(job.key.store.label)" }
        return driver.blocker
    }

    private func pump() {
        guard active == nil, !suspended,
              let job = queue.jobs.first(where: { $0.hold == nil && blocker($0) == nil }),
              let driver = drivers[job.key.store] else { return }
        let key = job.key
        queue.started(key)
        rate.reset()
        ratePerSecond = nil
        let task = Task {
            let result: Result<UInt64?, Error>
            do {
                let progress: @Sendable (InstallEngine.Progress) -> Void = { p in
                    Task { @MainActor in self.progressed(key, p) }
                }
                result = .success(try await driver.run(job, progress: progress))
            } catch {
                result = .failure(error)
            }
            self.finished(job, result)
        }
        active = (key, task)
        SteamUILog.logger.info("install", "\(key): \(job.kind.rawValue) started")
        rebuild()
        updateIdleTimer()
    }

    private func progressed(_ key: StoreGameKey, _ p: InstallEngine.Progress) {
        guard active?.key == key, stopping[key] == nil else { return }
        progress[key] = p
        rate.add(bytes: p.downloadedBytes, at: p.seconds)
        ratePerSecond = rate.bytesPerSecond
        rebuild(key)
        if Date().timeIntervalSince(lastLogged) >= 30 {
            lastLogged = Date()
            SteamUILog.logger.info("install", "\(key) " + TitleInstaller.progressLine(p))
        }
    }

    private func finished(_ job: DownloadJob, _ result: Result<UInt64?, Error>) {
        let key = job.key
        active = nil
        let stopped = stopping.removeValue(forKey: key)
        let bytes = progress[key].map { job.kind == .install || job.kind == .import ? $0.bytesTotal : $0.downloadedBytes }
        switch result {
        case let .success(done):
            queue.finished(key, bytes: done ?? bytes, at: Date())
            progress[key] = nil
            SteamUILog.logger.info("install", "\(key): done")
            LibraryModel.shared.refresh()
            drivers[key.store]?.finished(job)
        case let .failure(error):
            switch stopped {
            case let .hold(h)?:
                queue.hold(key, h)
                SteamUILog.logger.info("install", "\(key): paused, stage kept")
            case .requeue?:
                SteamUILog.logger.info("install", "\(key): waits its turn again, stage kept")
            case .cancel?:
                progress[key] = nil
            case nil:
                let why = drivers[key.store]?.reason(error) ?? InstallCopy.reason(error)
                queue.hold(key, .stopped(why))
                SteamUILog.logger.warn("install", "\(key): stopped: \(error)")
            }
        }
        rebuild()
        updateIdleTimer()
        pump()
    }

    // MARK: what the screens see

    private func rebuild(_ only: StoreGameKey? = nil) {
        var out = only == nil ? [:] : jobs
        var firstWaiting: String?
        for record in queue.jobs where only == nil || record.key == only {
            let phase: Job.Phase
            if record.key == active?.key, stopping[record.key] == nil {
                if let p = progress[record.key] {
                    phase = p.bytesDone >= p.bytesTotal ? .finishing : .downloading
                } else {
                    phase = .preparing
                }
            } else {
                switch record.hold {
                case nil: phase = .queued
                case .player?: phase = .paused(nil)
                case .launch?: phase = .paused(suspended ? InstallCopy.afterLaunch : InstallCopy.launch)
                case let .stopped(reason)?: phase = .paused(reason)
                }
            }
            let why = phase == .queued ? blocker(record) : nil
            if phase == .queued, firstWaiting == nil { firstWaiting = why }
            out[record.key] = Job(record: record, phase: phase, progress: progress[record.key],
                                  rate: record.key == active?.key ? ratePerSecond : nil, waitingFor: why)
        }
        jobs = out
        if only == nil {
            let why = active == nil ? firstWaiting : nil
            if blocked != why { blocked = why }
        }
        let today = queue.doneToday(now: Date())
        if doneToday != today { doneToday = today }
    }

    private func saveQueue() {
        do {
            try store.save(queue)
        } catch {
            SteamUILog.logger.warn("install", "queue not saved: \(error)")
        }
    }

    func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = active != nil || !LibraryModel.shared.verifying.isEmpty
    }
}

/// What the player is told when a download stops. A release build words it
/// without internals (decision 0009); the dev build adds the raw error.
enum InstallCopy {
    static let afterLaunch = "A game has run in this session. Close Playport and reopen it to continue downloading."
    static let launch = "Paused while a game runs."
    static let signOut = "Paused: signed out of Steam."

    static func reason(_ error: Error, store: String = "Steam") -> String {
        let text: String
        switch error as? ClientError {
        case let .insufficientSpace(needed, available)?:
            text = "Not enough free space: \(ByteCount.format(needed)) needed, \(ByteCount.format(available)) free."
        case .notLoggedOn?, .noCredentials?:
            text = "Sign in to \(store) to continue."
        case .transport?, .timeout?, .retriesExhausted?:
            text = "\(store) can't be reached. Check the connection, then resume."
        case .unsafeContent?:
            text = "Another game's folder is in the way, or the download contains a file Playport refuses."
        case .verificationFailed?:
            text = "Some files could not be verified. Resume to fetch them again."
        default:
            text = "The download stopped."
        }
        return detailed(text, error)
    }

    /// `text`, and in a dev build the raw error after it.
    static func detailed(_ text: String, _ error: Error) -> String {
        #if PLAYPORT_RELEASE
        return text
        #else
        return "\(text) (\(error))"
        #endif
    }
}
