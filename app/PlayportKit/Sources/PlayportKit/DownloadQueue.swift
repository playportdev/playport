// SPDX-License-Identifier: GPL-3.0-or-later
// The download queue's state, apart from the downloads themselves
// (UI/SteamInstalls.swift runs them; docs/plans/finished.md#the-gamepad-first-ui,
// Hard problem 1 and Downloads):
//
// - DownloadQueue: installs, updates, repairs and imports in the order they run,
//   one job per game by its store identity (decision 0057), each
//   waiting or held (the player's Pause, a game's launch, a failure), the
//   downloads finished today, and the automatic updates the player cancelled.
//   It is kept in the container (DownloadQueueStore) after every change,
//   because Playport restarts after every game (decision 0029): the new
//   process loads it, lets go of every hold but the player's, and carries on
//   once Steam is signed in.
// - Y on a waiting job ("Download next") moves it to the front, behind the
//   one running.
// - Updates Steam published are queued by themselves (`automaticUpdates`)
//   when Settings › Downloads says so, once per build: a cancelled one waits
//   for the next build.
// - DownloadRate: speed over the last seconds, and the time left.
// - DownloadMode: when the screen dims while a download runs.

import Foundation
import SteamClientKit

public struct DownloadJob: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case install, update, repair
        /// A copy from Files into C:\Games (a folder, a .zip, an installer).
        case `import`

        public var label: String {
            switch self {
            case .install: "Install"
            case .update: "Update"
            case .repair: "Repair"
            case .import: "Import"
            }
        }
    }

    /// Why a job is not waiting its turn.
    public enum Hold: Codable, Equatable, Sendable {
        /// The player's Pause: it stays paused, across restarts too, until Resume.
        case player
        /// A game started (decision 0004): the next process resumes it.
        case launch
        /// The download stopped (the reason, worded for the player): the next process tries again.
        case stopped(String)
    }

    /// The game, in its store (an import: the local folder it makes).
    public var key: StoreGameKey
    public var name: String
    public var kind: Kind
    /// The branch asked for; nil continues the paused download's or the install's.
    public var branch: String?
    public var hold: Hold?
    /// Queued by itself, for an update Steam published.
    public var automatic: Bool
    /// The build an automatic update goes to.
    public var buildID: UInt32?
    /// The download's size when known before it starts (Steam's manifest sizes).
    public var bytes: UInt64?
    public var id: StoreGameKey { key }
    /// Steam's app ID, for a Steam job.
    public var appID: UInt32? { key.steamAppID }

    public init(key: StoreGameKey, name: String, kind: Kind, branch: String? = nil, hold: Hold? = nil,
                automatic: Bool = false, buildID: UInt32? = nil, bytes: UInt64? = nil) {
        self.key = key
        self.name = name
        self.kind = kind
        self.branch = branch
        self.hold = hold
        self.automatic = automatic
        self.buildID = buildID
        self.bytes = bytes
    }

    public init(appID: UInt32, name: String, kind: Kind, branch: String? = nil, hold: Hold? = nil,
                automatic: Bool = false, buildID: UInt32? = nil, bytes: UInt64? = nil) {
        self.init(key: .steam(appID), name: name, kind: kind, branch: branch, hold: hold, automatic: automatic,
                  buildID: buildID, bytes: bytes)
    }

    enum CodingKeys: String, CodingKey { case key, appID, name, kind, branch, hold, automatic, buildID, bytes }

    /// A queue from before store identities names a Steam app ID only.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(StoreGameKey.self, forKey: .key) ?? .steam(try c.decode(UInt32.self, forKey: .appID))
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        hold = try c.decodeIfPresent(Hold.self, forKey: .hold)
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        buildID = try c.decodeIfPresent(UInt32.self, forKey: .buildID)
        bytes = try c.decodeIfPresent(UInt64.self, forKey: .bytes)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encodeIfPresent(appID, forKey: .appID)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(branch, forKey: .branch)
        try c.encodeIfPresent(hold, forKey: .hold)
        try c.encode(automatic, forKey: .automatic)
        try c.encodeIfPresent(buildID, forKey: .buildID)
        try c.encodeIfPresent(bytes, forKey: .bytes)
    }
}

/// A download that finished: the Downloads page's "Done today".
public struct DoneDownload: Codable, Equatable, Sendable {
    public var key: StoreGameKey
    public var name: String
    public var kind: DownloadJob.Kind
    public var bytes: UInt64?
    public var at: Date
    public var appID: UInt32? { key.steamAppID }

    public init(key: StoreGameKey, name: String, kind: DownloadJob.Kind, bytes: UInt64?, at: Date) {
        self.key = key
        self.name = name
        self.kind = kind
        self.bytes = bytes
        self.at = at
    }

    enum CodingKeys: String, CodingKey { case key, appID, name, kind, bytes, at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(StoreGameKey.self, forKey: .key) ?? .steam(try c.decode(UInt32.self, forKey: .appID))
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(DownloadJob.Kind.self, forKey: .kind)
        bytes = try c.decodeIfPresent(UInt64.self, forKey: .bytes)
        at = try c.decode(Date.self, forKey: .at)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encodeIfPresent(appID, forKey: .appID)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(bytes, forKey: .bytes)
        try c.encode(at, forKey: .at)
    }

    /// `Stardew Valley update · 240 MB`
    public var line: String {
        let what = kind == .install || kind == .import ? name : "\(name) \(kind.label.lowercased())"
        return what + (bytes.map { " · " + ByteCount.format($0) } ?? "")
    }
}

/// An installed Steam game and the build Steam has for its branch now.
public struct UpdateCandidate: Equatable, Sendable {
    public var appID: UInt32
    public var name: String
    public var installedBuild: UInt32?
    public var steamBuild: UInt32?
    public var bytes: UInt64?

    public init(appID: UInt32, name: String, installedBuild: UInt32?, steamBuild: UInt32?, bytes: UInt64? = nil) {
        self.appID = appID
        self.name = name
        self.installedBuild = installedBuild
        self.steamBuild = steamBuild
        self.bytes = bytes
    }
}

public struct DownloadQueue: Codable, Equatable, Sendable {
    /// In the order they run: the first job without a hold runs.
    public private(set) var jobs: [DownloadJob] = []
    /// Finished downloads, newest last; `pruned` keeps today's.
    public private(set) var done: [DoneDownload] = []
    /// App ID → the build of an automatic update the player cancelled.
    public private(set) var declined: [UInt32: UInt32] = [:]

    public init(jobs: [DownloadJob] = []) {
        self.jobs = jobs
    }

    public func job(_ key: StoreGameKey) -> DownloadJob? { jobs.first { $0.key == key } }
    public func job(_ appID: UInt32) -> DownloadJob? { job(.steam(appID)) }

    /// The job to run next: the first one waiting.
    public var next: DownloadJob? { jobs.first { $0.hold == nil } }

    /// Queues `job` at the end, or, when the game already has a job, lets go
    /// of its hold (a Resume) and takes the new branch. False when nothing changed.
    @discardableResult
    public mutating func add(_ job: DownloadJob) -> Bool {
        guard let i = jobs.firstIndex(where: { $0.key == job.key }) else {
            jobs.append(job)
            return true
        }
        guard jobs[i].hold != nil || (job.branch != nil && job.branch != jobs[i].branch) else { return false }
        jobs[i].hold = nil
        if job.branch != nil { jobs[i].branch = job.branch }
        // The player asked for it: an update queued by itself becomes theirs.
        if !job.automatic { jobs[i].automatic = false }
        return true
    }

    /// Y, "Download next": the job goes to the front, behind `running` (which
    /// is not stopped), and waits no longer.
    public mutating func moveToFront(_ key: StoreGameKey, running: StoreGameKey? = nil) {
        guard key != running, let i = jobs.firstIndex(where: { $0.key == key }) else { return }
        var job = jobs.remove(at: i)
        job.hold = nil
        let at = running.flatMap { r in jobs.firstIndex { $0.key == r } }.map { $0 + 1 } ?? 0
        jobs.insert(job, at: at)
    }

    /// The job that starts goes first, so the queue on disk says what ran.
    public mutating func started(_ key: StoreGameKey) {
        guard let i = jobs.firstIndex(where: { $0.key == key }), i != 0 else { return }
        jobs.insert(jobs.remove(at: i), at: 0)
    }

    public mutating func hold(_ key: StoreGameKey, _ hold: DownloadJob.Hold?) {
        guard let i = jobs.firstIndex(where: { $0.key == key }) else { return }
        jobs[i].hold = hold
    }

    /// Cancel: the job leaves the queue; an automatic update is not queued
    /// again for the same build.
    @discardableResult
    public mutating func remove(_ key: StoreGameKey) -> DownloadJob? {
        guard let i = jobs.firstIndex(where: { $0.key == key }) else { return nil }
        let job = jobs.remove(at: i)
        if job.automatic, let b = job.buildID, let app = key.steamAppID { declined[app] = b }
        return job
    }

    /// The job finished: it leaves the queue for Done today.
    public mutating func finished(_ key: StoreGameKey, bytes: UInt64?, at: Date) {
        guard let i = jobs.firstIndex(where: { $0.key == key }) else { return }
        let job = jobs.remove(at: i)
        done.append(DoneDownload(key: key, name: job.name, kind: job.kind, bytes: bytes, at: at))
        if let app = key.steamAppID { declined[app] = nil }
    }

    // Steam's shorthands, by app ID.
    public mutating func moveToFront(_ appID: UInt32, running: UInt32? = nil) { moveToFront(.steam(appID), running: running.map(StoreGameKey.steam)) }
    public mutating func started(_ appID: UInt32) { started(.steam(appID)) }
    public mutating func hold(_ appID: UInt32, _ hold: DownloadJob.Hold?) { self.hold(.steam(appID), hold) }
    @discardableResult
    public mutating func remove(_ appID: UInt32) -> DownloadJob? { remove(.steam(appID)) }
    public mutating func finished(_ appID: UInt32, bytes: UInt64?, at: Date) { finished(.steam(appID), bytes: bytes, at: at) }

    /// A new process (Playport restarts after every game): every job waits
    /// its turn again but the ones the player paused.
    public mutating func afterRestart() {
        for i in jobs.indices where jobs[i].hold != .player { jobs[i].hold = nil }
    }

    /// Done today, newest first.
    public func doneToday(now: Date, calendar: Calendar = .current) -> [DoneDownload] {
        done.filter { calendar.isDate($0.at, inSameDayAs: now) }.reversed()
    }

    /// Drops what finished before today.
    public mutating func prune(now: Date, calendar: Calendar = .current) {
        done.removeAll { !calendar.isDate($0.at, inSameDayAs: now) }
    }

    /// The updates to queue by themselves: a newer build on Steam than the
    /// one installed (build IDs only grow; a stale cache must not queue a
    /// step back), no job for the game yet, and not a build the player cancelled.
    public func automaticUpdates(_ candidates: [UpdateCandidate], enabled: Bool) -> [DownloadJob] {
        guard enabled else { return [] }
        return candidates.compactMap { c in
            guard let now = c.steamBuild, let had = c.installedBuild, now > had, job(c.appID) == nil,
                  declined[c.appID] != now else { return nil }
            return DownloadJob(appID: c.appID, name: c.name, kind: .update, automatic: true, buildID: now, bytes: c.bytes)
        }
    }
}

/// Library/Application Support/Playport/downloads.json: the queue, written after every change.
public struct DownloadQueueStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The saved queue; an empty one when there is none, or it cannot be read.
    public func load() -> DownloadQueue {
        guard let data = try? Data(contentsOf: url) else { return DownloadQueue() }
        return (try? Self.decoder.decode(DownloadQueue.self, from: data)) ?? DownloadQueue()
    }

    public func save(_ queue: DownloadQueue) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(queue).write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// The running download's speed over its last seconds, and the time left.
public struct DownloadRate: Sendable {
    /// Samples older than this leave the average.
    public var window: TimeInterval

    private var samples: [(t: TimeInterval, bytes: UInt64)] = []

    public init(window: TimeInterval = 10) {
        self.window = window
    }

    /// `bytes` downloaded so far in this run, at `t` seconds; a count that
    /// goes back (a new run) starts afresh.
    public mutating func add(bytes: UInt64, at t: TimeInterval) {
        if let last = samples.last, bytes < last.bytes || t < last.t { samples = [] }
        samples.append((t, bytes))
        samples.removeAll { $0.t < t - window }
    }

    public mutating func reset() { samples = [] }

    /// Bytes a second over the window; nil until two samples a second apart.
    public var bytesPerSecond: Double? {
        guard let a = samples.first, let b = samples.last, b.t - a.t >= 1 else { return nil }
        return Double(b.bytes - a.bytes) / (b.t - a.t)
    }

    /// Seconds to fetch `remaining` bytes at `rate`.
    public static func seconds(remaining: UInt64, rate: Double?) -> TimeInterval? {
        guard let rate, rate > 0 else { return nil }
        return Double(remaining) / rate
    }

    /// `about 4 min`, `less than a minute`, `about 1 h 20 min`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 60 { return "less than a minute" }
        if minutes < 60 { return "about \(max(1, minutes)) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "about \(h) h" : "about \(h) h \(m) min"
    }

    /// `4 min`, `1 h 20 min`, rounded up (Home's download card: `62% · 4 min`).
    public static func short(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// `18 MB/s`
    public static func speed(_ bytesPerSecond: Double) -> String {
        ByteCount.format(UInt64(max(0, bytesPerSecond))) + "/s"
    }
}

/// Download mode (DownloadMode.dc.html): a black page with the progress and
/// the screen turned down, after a minute without input while a download
/// runs and Settings › Downloads' dim switch is on.
public enum DownloadMode {
    public static let idleAfter: TimeInterval = 60

    public static func shouldDim(idleFor: TimeInterval, downloading: Bool, enabled: Bool) -> Bool {
        enabled && downloading && idleFor >= idleAfter
    }

    /// The brightness Download mode sets: low, and never above what the player had.
    public static func dimmed(from brightness: Double) -> Double {
        min(brightness, 0.05)
    }
}
