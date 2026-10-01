// SPDX-License-Identifier: GPL-3.0-or-later
// Steam downloads from the UI: install, update and repair through
// SteamClientKit's TitleInstaller, one job at a time and the rest queued, in
// the order PlayportKit's DownloadQueue keeps. The queue is written to the
// container after every change (DownloadQueueStore), because Playport
// restarts after every game (decision 0029): a game's launch holds every job
// (decision 0004), and the new process lets go of every hold but the player's
// Pause and carries on once Steam is signed in. Only when that restart failed
// does this process keep them held (InstallCopy.afterLaunch).
//
// A job stops, with its stage and journal kept for resume, on Pause, on
// sign-out, on a launch, on any failure, and while the network is one
// Settings › Downloads does not allow (cellular, unless it says so; the job
// then waits its turn again). Updates Steam published are queued by
// themselves when Settings says so (`checkUpdates`). Downloads run in the
// foreground only: the screen stays on while one runs (Download mode dims
// it, DownloadModeView.swift), and iOS suspending the app pauses it.
// Uninstall and offline verify are LibraryModel's: they need no Steam session.

import Combine
import Foundation
import PlayportKit
import SteamClientKit
import UIKit

@MainActor
final class SteamInstalls: ObservableObject {
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

        var appID: UInt32 { record.appID }
        var name: String { record.name }
        var kind: Kind { record.kind }
        var branch: String? { record.branch }
        var id: UInt32 { appID }

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

        /// Bytes still to fetch: the running job's, else Steam's size for a job not begun.
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
                let verb = kind == .repair ? "Repairing" : kind == .update ? "Updating" : "Downloading"
                return fraction.map { "\(verb) \(Int($0 * 100))%" } ?? verb
            case .finishing: return "Finishing…"
            case .paused: return "Paused"
            }
        }
    }

    /// The queue as the screens show it, by app ID; `order` is its order.
    @Published private(set) var jobs: [UInt32: Job] = [:]
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
    private var active: (appID: UInt32, task: Task<Void, Never>)?
    private var progress: [UInt32: InstallEngine.Progress] = [:]
    private var rate = DownloadRate()
    private var ratePerSecond: Double?
    /// Jobs stopped on purpose: what happens to them once the cancel lands.
    private enum Stop { case hold(DownloadJob.Hold), requeue, cancel }
    private var stopping: [UInt32: Stop] = [:]
    private var lastLogged: Date = .distantPast
    /// Steam is signed in: the queue may run (the new process waits for its restore).
    private var signedIn = false
    private var cancellables: Set<AnyCancellable> = []
    private let service: SteamService

    init(service: SteamService) {
        self.service = service
        // Resolved now, before a launch moves HOME into the prefix (SteamPaths).
        store = DownloadQueueStore(url: SteamPaths.downloads)
        var q = store.load()
        // A new process: what a game's launch (or a failure) held waits its turn again.
        q.afterRestart()
        q.prune(now: Date())
        queue = q
        if !q.jobs.isEmpty {
            SteamUILog.logger.info("install", "queue loaded: " + q.jobs.map { "\($0.appID) \($0.kind.rawValue)\($0.hold == nil ? "" : " held")" }.joined(separator: ", "))
        }
        saveQueue()
        rebuild()
        NetworkPath.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.networkChanged() } }
            .store(in: &cancellables)
    }

    var layout: InstallLayout { LibraryModel.paths.layout }
    var isBusy: Bool { active != nil }
    /// The running job, then the rest in the order they start (Home's Downloading and Up next, Downloads).
    var order: [Job] {
        let running = active.flatMap { jobs[$0.appID] }
        return (running.map { [$0] } ?? []) + queue.jobs.filter { $0.appID != active?.appID }.compactMap { jobs[$0.appID] }
    }
    var runningAppID: UInt32? { active?.appID }

    // MARK: actions

    /// Installs (or updates, or resumes) `appID`, on `branch` when one is
    /// named (a beta, or public to leave one); queued behind a running job.
    /// An installed game's download is its update.
    func install(_ appID: UInt32, name: String, branch: String? = nil) {
        let installed = LibraryModel.shared.catalog.titles.contains { $0.appID == appID }
        let bytes = SteamAccountModel.current?.games.first { $0.id == appID }?.info.installSize(branch: branch ?? Branch.publicName)
        enqueue(DownloadJob(appID: appID, name: name, kind: installed ? .update : .install, branch: branch,
                            bytes: installed ? nil : bytes))
    }

    /// Re-downloads the files of a Steam install that fail verification.
    func repair(_ appID: UInt32, name: String) { enqueue(DownloadJob(appID: appID, name: name, kind: .repair)) }

    func resume(_ appID: UInt32) {
        guard let job = queue.job(appID), job.hold != nil else { return }
        enqueue(job)
    }

    func pause(_ appID: UInt32) { stop(appID, .hold(.player)) }

    /// Y, "Download next": the job goes to the front, behind the one running.
    func downloadNext(_ appID: UInt32) {
        guard appID != active?.appID else { return }
        queue.moveToFront(appID, running: active?.appID)
        SteamUILog.logger.info("install", "app \(appID): moved to the front")
        rebuild()
        pump()
    }

    /// Cancel: stops the job, if any, takes it out of the queue and deletes the staged download.
    func discard(_ appID: UInt32) {
        if active?.appID == appID {
            stopping[appID] = .cancel
            active?.task.cancel()
        }
        queue.remove(appID)
        progress[appID] = nil
        rebuild()
        let installer = TitleInstaller(layout: layout, session: nil, log: SteamUILog.logger)
        // The journals first, at once, so the download no longer shows as resumable;
        // the staged trees can take a while. A job still winding down writes only
        // into files it has open, and the next run of it starts afresh.
        for n in (try? FileManager.default.contentsOfDirectory(atPath: layout.stagingRoot.path)) ?? []
        where n.hasPrefix("\(appID)_") && n.hasSuffix(".journal") {
            try? FileManager.default.removeItem(at: layout.stagingRoot.appendingPathComponent(n))
        }
        Task.detached(priority: .utility) { installer.discardStage(appID: appID) }
        SteamUILog.logger.info("install", "app \(appID): cancelled, staged download discarded")
        pump()
    }

    /// A download of `appID` left on disk by an earlier run, with no job for it now.
    func hasStageOnDisk(_ appID: UInt32) -> Bool {
        jobs[appID] == nil && TitleInstaller(layout: layout, session: nil, log: .silent).hasStage(appID: appID)
    }

    /// A title launch: every job is held, and the next process resumes them;
    /// none starts again in this one (the service refuses Steam work).
    func holdForLaunch() {
        suspended = true
        holdAll(.launch)
    }

    /// Sign-out: every job is held until Steam is signed in again.
    func holdForSignOut() {
        signedIn = false
        holdAll(.stopped(InstallCopy.signOut))
    }

    private func holdAll(_ hold: DownloadJob.Hold) {
        for job in queue.jobs where job.hold == nil {
            if job.appID == active?.appID { stop(job.appID, .hold(hold)) } else { queue.hold(job.appID, hold) }
        }
        rebuild()
        updateIdleTimer()
    }

    /// Steam's session is up (at every start of the app, once restored): the
    /// queue runs, with every hold but the player's let go.
    func steamSignedIn() {
        guard !signedIn else { return }
        signedIn = true
        if !suspended { queue.afterRestart() }
        rebuild()
        pump()
    }

    /// Steam is no longer signed in (offline, expired): nothing new starts.
    func steamSignedOut() {
        signedIn = false
        rebuild()
    }

    /// Queues the updates Steam published for installed games, when Settings
    /// › Downloads updates games by themselves (PlayportKit DownloadQueue.automaticUpdates).
    func checkUpdates(games: [SteamGame], titles: [InstalledTitle]) {
        guard !suspended, !TitleLaunch.shared.running else { return }
        let candidates = titles.compactMap { t -> UpdateCandidate? in
            // Only a Steam install follows Steam (SteamInstallStatus.updateAvailable).
            guard t.source == .installed, let app = t.appID, let g = games.first(where: { $0.id == app }) else { return nil }
            return UpdateCandidate(appID: app, name: t.name, installedBuild: t.buildID,
                                   steamBuild: g.info.depots.buildID(branch: t.branch ?? Branch.publicName))
        }
        let found = queue.automaticUpdates(candidates, enabled: DownloadPreferences.current.autoUpdate)
        guard !found.isEmpty else { return }
        for job in found {
            SteamUILog.logger.info("install", "app \(job.appID): update to build \(job.buildID.map(String.init) ?? "?") queued by itself")
            queue.add(job)
        }
        rebuild()
        pump()
    }

    // MARK: running

    private func enqueue(_ job: DownloadJob) {
        guard job.appID != active?.appID else { return }
        queue.add(job)
        rebuild()
        pump()
    }

    private func stop(_ appID: UInt32, _ how: Stop) {
        if active?.appID == appID {
            stopping[appID] = how
            active?.task.cancel()
            // On disk at once: the process may end (a launch's restart) before the cancel lands.
            if case let .hold(h) = how { queue.hold(appID, h) }
            rebuild()
        } else if case let .hold(h) = how {
            queue.hold(appID, h)
            rebuild()
        }
    }

    /// Why nothing may start now, or nil.
    private var blocker: String? {
        if suspended { return nil }   // the jobs say it themselves (InstallCopy.afterLaunch)
        if !signedIn { return "Waiting for Steam" }
        let net = NetworkPath.shared
        if !net.connected { return "Waiting for a connection" }
        if !net.mayDownload { return "Waiting for Wi-Fi" }
        return nil
    }

    private func networkChanged() {
        // The published values change after objectWillChange: look on the next turn.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let running = self.active?.appID, !NetworkPath.shared.mayDownload {
                    SteamUILog.logger.info("install", "app \(running): stopped, the network does not allow downloads now")
                    self.stop(running, .requeue)
                }
                self.rebuild()
                self.pump()
            }
        }
    }

    private func pump() {
        guard active == nil, !suspended, blocker == nil, let job = queue.next else { return }
        let appID = job.appID
        queue.started(appID)
        rate.reset()
        ratePerSecond = nil
        let (service, layout, kind, branch) = (service, layout, job.kind, job.branch)
        let task = Task {
            let result: Result<UInt64?, Error>
            do {
                let installer = try await service.titleInstaller(layout: layout)
                var engine = InstallEngine.Options()
                engine.progressInterval = 0.5
                let progress: @Sendable (InstallEngine.Progress) -> Void = { p in
                    Task { @MainActor in self.progressed(appID, p) }
                }
                // The progress lines go to the log from `progressed`, less often.
                let say: @Sendable (String) -> Void = { line in
                    if !line.hasPrefix("progress:") { SteamUILog.logger.info("install", line) }
                }
                switch kind {
                case .install, .update:
                    let r = try await installer.install(.init(appID: appID, branch: branch, engine: engine), progress: progress, say: say)
                    result = .success(kind == .install ? r.stage?.bytes : r.stage?.downloadedBytes)
                case .repair:
                    let r = try await installer.repair(appID: appID, engine: engine, progress: progress, say: say)
                    LibraryModel.shared.recordVerification(appID: appID, report: r)
                    result = .success(nil)
                }
            } catch {
                result = .failure(error)
            }
            self.finished(appID, result)
        }
        active = (appID, task)
        SteamUILog.logger.info("install", "app \(appID): \(kind.rawValue) started")
        rebuild()
        updateIdleTimer()
    }

    private func progressed(_ appID: UInt32, _ p: InstallEngine.Progress) {
        guard active?.appID == appID, stopping[appID] == nil else { return }
        progress[appID] = p
        rate.add(bytes: p.downloadedBytes, at: p.seconds)
        ratePerSecond = rate.bytesPerSecond
        rebuild(appID)
        if Date().timeIntervalSince(lastLogged) >= 30 {
            lastLogged = Date()
            SteamUILog.logger.info("install", "app \(appID) " + TitleInstaller.progressLine(p))
        }
    }

    private func finished(_ appID: UInt32, _ result: Result<UInt64?, Error>) {
        active = nil
        let stopped = stopping.removeValue(forKey: appID)
        let bytes = progress[appID].map { queue.job(appID)?.kind == .install ? $0.bytesTotal : $0.downloadedBytes }
        switch result {
        case let .success(done):
            queue.finished(appID, bytes: done ?? bytes, at: Date())
            progress[appID] = nil
            SteamUILog.logger.info("install", "app \(appID): done")
            LibraryModel.shared.refresh()
            // What the game's Steam API emulator is told, while the session is up.
            Task { await SteamAccountModel.current?.loadGameProfile(appID, refresh: true) }
        case let .failure(error):
            switch stopped {
            case let .hold(h)?:
                queue.hold(appID, h)
                SteamUILog.logger.info("install", "app \(appID): paused, stage kept")
            case .requeue?:
                SteamUILog.logger.info("install", "app \(appID): waits its turn again, stage kept")
            case .cancel?:
                progress[appID] = nil
            case nil:
                queue.hold(appID, .stopped(InstallCopy.reason(error)))
                SteamUILog.logger.warn("install", "app \(appID): stopped: \(error)")
            }
        }
        rebuild()
        updateIdleTimer()
        pump()
    }

    // MARK: what the screens see

    private func rebuild(_ only: UInt32? = nil) {
        let why = blocker
        var out = only == nil ? [:] : jobs
        for record in queue.jobs where only == nil || record.appID == only {
            let phase: Job.Phase
            if record.appID == active?.appID, stopping[record.appID] == nil {
                if let p = progress[record.appID] {
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
            out[record.appID] = Job(record: record, phase: phase, progress: progress[record.appID],
                                    rate: record.appID == active?.appID ? ratePerSecond : nil,
                                    waitingFor: phase == .queued ? why : nil)
        }
        jobs = out
        if blocked != why { blocked = why }
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

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = active != nil || !LibraryModel.shared.verifying.isEmpty
    }
}

/// What the player is told when a download stops. A release build words it
/// without internals (decision 0009); the dev build adds the raw error.
enum InstallCopy {
    static let afterLaunch = "A game has run in this session. Close Playport and reopen it to continue downloading."
    static let launch = "Paused while a game runs."
    static let signOut = "Paused: signed out of Steam."

    static func reason(_ error: Error) -> String {
        let text: String
        switch error as? SteamError {
        case let .insufficientSpace(needed, available)?:
            text = "Not enough free space: \(ByteCount.format(needed)) needed, \(ByteCount.format(available)) free."
        case .notLoggedOn?, .noCredentials?:
            text = "Sign in to Steam to continue."
        case .transport?, .timeout?, .retriesExhausted?:
            text = "Steam can't be reached. Check the connection, then resume."
        case .unsafeContent?:
            text = "Another game's folder is in the way, or the download contains a file Playport refuses."
        case .verificationFailed?:
            text = "Some files could not be verified. Resume to fetch them again."
        default:
            text = "The download stopped."
        }
        #if PLAYPORT_RELEASE
        return text
        #else
        return "\(text) (\(error))"
        #endif
    }
}
