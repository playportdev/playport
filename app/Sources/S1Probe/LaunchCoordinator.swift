// SPDX-License-Identifier: GPL-3.0-or-later
// One title launch, from the product UI's Play button (TitleLaunch). Refuse a
// title that needs more than the app's memory limit (MemoryLimit, PlayportKit
// MemoryNeed), resolve the executable's DOS path on drive C, add the Unity
// screen switches, run the start-up self-check (SelfCheck), bring up host I/O.
// The Play then acquires the JIT pool (JitProvider, through
// WineHostRuntime.start, which checks it) in the size the limit gives it
// (PlayportKit JitPool) and starts the runtime and its session root. That is
// once per app process: after the title Playport restarts itself (decision
// 0029), and a Play in a process that already blessed its pool is refused
// (decision 0030). The title runs as the session root's
// child with its directory as the working directory; the launch waits for it
// and everything it started to exit, logging the pool's use as `title: pool:`
// lines while it runs and as a `pool:` mark when it exits. A title that ran the
// pool out ends as its own outcome, whatever its exit code; for one still running
// 10 s after it ran out (a failed image load can leave it presenting black
// frames) the launch ends without it, and the restart that follows ends the
// game (decisions 0022, 0030). A title with its own madeira.cfg keys
// (PlayportKit TitleConfig) gets them through MADEIRA_DOCS_DIR, set before
// it starts. A Steam game's id (PlayportKit SteamGameID: SteamAppId, SteamGameId
// and STEAM_COMPAT_APP_ID, as Steam sets them and Proton passes them to Wine),
// FEX's settings (FEXProfile: the game's memory ordering, and the host CPU
// features FEX cannot read on iOS, HostCPU) and the backend's variables go into
// the title's own environment, over the session root's, and into the app's
// for the runtime's unix side. A Steam game's encrypted app ticket, fetched after
// Play (LibraryModel.play), goes into the emulator's settings before the runtime
// starts and out of them when the launch ends (decision 0017). An Epic game's ownership token,
// fetched after Play with its exchange code, goes into its file the same way (decision 0059).
// A web page the game opens during the play reaches the host (UrlOpenerHost, decision 0064)
// while the launch runs. A GOG game's Galaxy service (GOGClientKit GalaxyListener, decision
// 0063), started at Play, stops when the launch ends.
// Progress goes to the app log
// (AppLog) as `title:` lines and, for the UI, to a step callback; the outcome's line is the
// `title: done` result the drivers parse, unchanged. `title: +<s> s` lines time the
// launch from its start to the game's first frame, in both variants.

import Foundation
import HostIOKit
import PlayportKit
import EpicClientKit
import GOGClientKit
import SteamClientKit
import WineHost

enum LaunchCoordinator {
    struct Request {
        var exe: String
        var args: [String]
        /// madeira.cfg keys over the shared file for this launch (TitleConfig); empty for none.
        var config: [String: String] = [:]
        /// The title's Steam app ID, set as Steam's game id (SteamGameID); nil for none.
        var steamAppID: UInt32? = nil
        /// Which layer runs the game's Direct3D (LaunchSettings).
        var graphics: GraphicsBackend = .default
        /// The game's Graphics options (LaunchSettings.graphicsEnvironment; dev builds only,
        /// decision 0060), over the backend's own environment.
        var graphicsEnvironment: [String: String] = [:]
        /// FEX's memory ordering for the game (FEXProfile.launch); nil leaves FEX's own defaults.
        var fex: FEXProfile.Launch? = nil
        /// The JIT pool (docs/ARCHITECTURE.md, JIT pool placement); nil sizes it
        /// from the memory limit (JitPool.sizeMB).
        var poolMB: Int? = nil
        /// How long the pool acquire waits for a debugger.
        var jitWait: TimeInterval
        /// The game's steam_api: the emulator or its own (LaunchSettings); nil
        /// for a title with no Steam app ID.
        var steamAPI: SteamAPI? = nil
        /// What the title needs of the app's memory limit (MemoryNeed); nil checks nothing.
        var memory: MemoryNeed? = nil
        /// An Epic game's ownership token file (decision 0059); nil for a game of another store.
        var epic: Epic? = nil
        /// The title's name, for a web page the game opens (UrlOpenerHost).
        var title: String = ""
        /// A GOG game's Galaxy service, listening since Play (decision 0063); nil for none.
        var galaxy: GalaxyListener? = nil
    }

    /// An Epic game's launch: its folder, and the ownership token for `-epicovt`
    /// (fetched after Play), nil for a game that needs none or plays offline.
    struct Epic {
        var root: URL
        var ownershipToken: Secret<String>? = nil
    }

    /// What SteamAPISwap needs at a launch. The settings come from the Steam
    /// service's kept profile and stored session, with no network.
    struct SteamAPI {
        var appID: UInt32
        /// The game's folder under C:\Games.
        var root: URL
        var mode: SteamAPISwap.Mode
        var settings: @Sendable () async -> SteamAPISwap.Settings
        /// The game's encrypted app ticket (decision 0017), fetched after Play
        /// before the session closed; nil starts the game without one.
        var ticket: Secret<[UInt8]>? = nil
        /// The play's auth session and web API tickets (decision 0062), armed after
        /// Play; nil leaves the emulator's made-up ones.
        var tickets: SteamTicketBroker? = nil
    }

    enum Step: Equatable {
        case preparing
        case waitingForJit(until: Date)
        case startingRuntime
        case startingGame
        case running(since: Date)
        /// The game asked for its first drawable (PacedMetalLayer).
        case drawing
    }

    struct Outcome: Equatable {
        enum Kind: Equatable {
            /// Nothing was started (no such executable); nothing was spent.
            case refused
            /// The JIT pool, the runtime or the executable failed to start.
            case failed
            /// The title exited with this code (an NTSTATUS crash code stays unsigned).
            case exited(UInt32)
            /// The JIT pool ran out (JitPool.Use.exhaustion) before the title ended,
            /// whatever its exit code: its own outcome, not a crash or a failed start.
            case outOfJitMemory(JitPool.Exhaustion)
        }

        var kind: Kind
        /// What follows `title: done nonce=<n> ` in the result line.
        var line: String
        /// The JIT pool the launch had, in MiB; 0 when it never got one.
        var poolMB: Int = 0
    }

    fileprivate static func log(_ line: String) { WineHostRuntime.appendLog("title: " + line) }

    /// Puts the game's steam_api in the launch's mode: the emulator with its
    /// settings written and SteamStub taken off the executables Playport can
    /// unwrap, or the game's own of both. A failure is logged and the launch
    /// goes on: the game then meets whichever files are in place.
    private static func prepareSteamAPI(_ s: SteamAPI) {
        final class Box: @unchecked Sendable { var settings: SteamAPISwap.Settings? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        Task.detached { box.settings = await s.settings(); done.signal() }
        let settings = done.wait(timeout: .now() + 10) == .timedOut ? nil : box.settings
        let fields = settings.map { t in
            "persona \(t.personaName == nil ? "none" : "set"), steamid \(t.steamID == nil ? "none" : "set"), \(t.dlc.count) DLC"
        } ?? "no settings in 10 s: app ID only"
        guard let runtime = Manifest.runtime else {
            log("steamapi: no staged runtime; the game's own steam_api stays")
            return
        }
        // A ticket a crash or a kill left behind goes before anything else (decision 0017).
        removeTicket(s, when: "before the launch")
        do {
            let state = try SteamAPISwap.ensure(s.mode, in: s.root, emulator: runtime.appendingPathComponent("steamapi", isDirectory: true),
                                                settings: settings ?? .init(appID: s.appID))
            log("steamapi: \(s.mode.rawValue): \(state.rawValue)" + (s.mode == .emulated ? " (\(fields))" : ""))
            if s.mode == .emulated {
                if let ticket = s.ticket {
                    let n = try SteamAPISwap.writeTicket(ticket, in: s.root)
                    log("ticket: the encrypted app ticket (\(ticket.value.count) bytes) written to \(n) configs.user.ini")
                } else {
                    log("ticket: none; the emulator makes up its own")
                }
            }
            // The emulator's unix calls reach the play's broker, or none (SteamTicketHost).
            SteamTicketHost.arm(s.mode == .emulated ? s.tickets : nil)
            if s.mode == .emulated {
                log(s.tickets != nil ? "ticket: auth session and web API tickets armed; the CM session stays logged on for them"
                                     : "ticket: auth session and web API tickets off; the emulator makes up its own")
            }
            var stub = "none"
            if s.mode == .emulated {
                for site in try SteamStub.remove(in: s.root) {
                    log("steamstub: \(site.path): \(site.info.label), " + (site.info.unsupported ?? (site.removed ? "removed" : "kept")))
                    stub = site.removed ? "removed" : "unsupported"
                }
            } else if try SteamStub.restore(in: s.root) > 0 {
                log("steamstub: the game's own executables are back")
                stub = "restored"
            }
            #if !PLAYPORT_RELEASE
            RunEvents.emit("steamapi", ["mode": s.mode.rawValue, "state": state.rawValue, "stub": stub])
            #endif
        } catch {
            log("steamapi: \(s.mode.rawValue) failed: \(error)")
            #if !PLAYPORT_RELEASE
            RunEvents.emit("steamapi", ["mode": s.mode.rawValue, "error": "\(error)"])
            #endif
        }
    }

    /// Takes the encrypted app ticket out of the game's emulator settings
    /// (decision 0017): at the game's exit, and before a launch for one a crash
    /// or a kill left behind. Logged only when there was one.
    private static func removeTicket(_ s: SteamAPI, when: String) {
        do {
            let n = try SteamAPISwap.removeTickets(in: s.root)
            if n > 0 || (when == "at exit" && s.ticket != nil) { log("ticket: removed from \(n) configs.user.ini \(when)") }
        } catch {
            log("ticket: not removed \(when): \(error)")
        }
    }

    /// Writes the Epic game's ownership token file after removing one a crash or a kill
    /// left behind (decision 0059). A failed write is logged; the game then says it
    /// could not check its ownership.
    private static func prepareEpic(_ e: Epic) {
        removeOwnershipFile(e, when: "before the launch")
        guard let token = e.ownershipToken else { return }
        do {
            try EpicOwnershipFile.write(token, in: e.root)
            log("epic: the ownership token (\(token.value.utf8.count) bytes) written to \(EpicOwnershipFile.name)")
        } catch {
            log("epic: the ownership token not written: \(error)")
        }
    }

    /// Takes the ownership token file out of the game's folder: at the game's exit, and
    /// before a launch for one a crash or a kill left behind. Logged only when there was one.
    private static func removeOwnershipFile(_ e: Epic, when: String) {
        do {
            let n = try EpicOwnershipFile.remove(in: e.root)
            if n > 0 || (when == "at exit" && e.ownershipToken != nil) { log("epic: ownership token file removed (\(n)) \(when)") }
        } catch {
            log("epic: ownership token file not removed \(when): \(error)")
        }
    }

    /// MADEIRA_DOCS_DIR as the process was launched with it, before any title's
    /// config pointed it elsewhere: a later launch in the same process (after one
    /// that failed without spending it) starts from this, not from the last title's.
    private static let inheritedDocsDir: String? = ProcessInfo.processInfo.environment["MADEIRA_DOCS_DIR"]
        .flatMap { $0.isEmpty ? nil : $0 }

    /// Sets the launch's variables over the process's own, for the runtime's
    /// unix side, and returns them for the title's own environment
    /// (WineHostRuntime.launch). It runs once per app process, after the pool
    /// is blessed (decision 0030), so no earlier title's are undone. FEX's win
    /// over the backend's, which win over Steam's game id, and FEX_HOSTFEATURES gets the host's features added to whichever
    /// value is set (FEXProfile.hostFeatures). Steam's game id is logged with its
    /// value where the backend does not replace it.
    private static func applyEnvironment(backend: [String: String], steamAppID: UInt32?,
                                         fex: FEXProfile.Launch?) -> [String: String] {
        var env = SteamGameID.launchEnvironment(appID: steamAppID,
                                                backend: backend.merging(fex?.environment ?? [:]) { _, f in f })
        let own = env["FEX_HOSTFEATURES"] ?? getenv("FEX_HOSTFEATURES").map { String(cString: $0) }
        if let features = FEXProfile.hostFeatures(player: own, lrcpc2: HostCPU.lrcpc2) { env["FEX_HOSTFEATURES"] = features }
        log("fex: host \(HostCPU.summary); FEX_HOSTFEATURES \(env["FEX_HOSTFEATURES"] ?? "unset")")
        if let fex {
            let profile = fex.override.map { "Proton's \($0.pattern) entry for this game" } ?? "Proton's defaults"
            log("fex: ordering \(fex.summary) maxinst=\(fex.maxInst)\(fex.maxInstChosen ? "*" : "") "
                + "x87reduced=\(fex.x87Reduced ? 1 : 0)\(fex.x87Chosen ? "*" : "") "
                + "diskcache=\(fex.diskCache ? 1 : 0)\(fex.diskCacheChosen ? "*" : "") (* the game's page; the rest \(profile))")
        }
        for name in env.keys.sorted() { setenv(name, env[name]!, 1) }
        let steam = SteamGameID.names.filter { env[$0] != nil && backend[$0] == nil }
        if !steam.isEmpty { log("environment: Steam's " + steam.map { "\($0)=\(env[$0]!)" }.joined(separator: ", ")) }
        if !backend.isEmpty { log("environment: the backend's " + backend.keys.sorted().joined(separator: ", ")) }
        return env
    }

    /// Blocks until the title exits or the launch fails. Never on the main
    /// thread, which keeps serving the surface, input and the JIT vehicle.
    static func run(_ r: Request, step: @escaping (Step) -> Void = { _ in }) -> Outcome {
        precondition(!Thread.isMainThread, "LaunchCoordinator.run blocks; call it off the main thread")
        // However the launch ends, the Galaxy service ends with it (decision 0063).
        defer { r.galaxy?.stop() }
        let launched = Date()
        let mark = { (what: String) in
            let s = Date().timeIntervalSince(launched)
            log(String(format: "+%.2f s %@", s, what))
            #if !PLAYPORT_RELEASE
            RunEvents.emit("mark", ["what": what, "s": (s * 100).rounded() / 100])
            #endif
        }
        step(.preparing)
        var args = r.args
        let runtime = WineHostRuntime.shared
        guard !runtime.poolAcquired else {
            // One title per app process (decision 0030): this one's pool is blessed, and the
            // restart after its title failed. The UI offers no Play then (TitleLaunch.spent);
            // a driven one gets this.
            log("session: this app process has played its title; Playport must be relaunched")
            return Outcome(kind: .refused, line: "launch=refused session=spent")
        }

        // A limit below the title's need would end in a jetsam kill partway: refuse
        // before any JIT is spent, with the numbers its alert shows.
        var memory = MemoryLimit.read()
        if let need = r.memory {
            var verdict = need.verdict(limitMB: memory.effectiveMB)
            // Game Mode raises the limit a few seconds after the app comes to the front
            // (6 GB to 8 GB on the reference phone): a Play that early waits for it.
            let deadline = Date().addingTimeInterval(5)
            while verdict == .tooLow, memory.simulatedMB == nil, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
                memory = MemoryLimit.read()
                verdict = need.verdict(limitMB: memory.effectiveMB)
            }
            log("memory: limit \(memory.effectiveMB.map { "\($0) MB" } ?? "not reported")"
                + (memory.simulatedMB != nil ? " (simulated)" : "")
                + ", footprint \(memory.footprintMB) MB; the title needs \(need.minimumMB) MB"
                + " (\(need.measured ? "measured" : "untested"), \(need.recommendedMB) MB recommended): \(verdict)")
            if verdict == .tooLow, let limit = memory.effectiveMB {
                return Outcome(kind: .refused, line: MemoryNeed.refusalLine(limitMB: limit, needMB: need.minimumMB))
            }
        }

        // Resolve before the pool is blessed, so a name that is not staged costs no activation.
        var tp = title_path()
        var msg = [CChar](repeating: 0, count: 512)
        let resolved = title_path_resolve(runtime.prefixURL.path, r.exe, &tp, &msg, msg.count)
        let reason = String(decoding: msg.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        log("resolve \(r.exe) -> \(resolved) \(reason)")
        guard resolved == 0 else {
            return Outcome(kind: .refused, line: "launch=refused resolve=\(resolved) reason=\(reason)")
        }

        // The backend's builtins go before the runtime's own (wine_host_init,
        // WINEDLLPATH). One this build does not carry refuses the launch
        // before any JIT is spent, rather than running the game on another.
        guard Manifest.has(r.graphics) else {
            log("graphics: \(r.graphics.rawValue) is not in this build")
            return Outcome(kind: .refused, line: "launch=refused graphics=\(r.graphics.rawValue) reason=not-in-this-build")
        }
        if let overlay = r.graphics.runtimeOverlay {
            setenv("PLAYPORT_DLL_OVERLAY", overlay, 1)
        } else {
            unsetenv("PLAYPORT_DLL_OVERLAY")
        }
        log("graphics: \(r.graphics.rawValue)")

        if r.config.isEmpty {
            // Undo an earlier launch's title config: this one reads the shared file.
            if let inherited = inheritedDocsDir { setenv("MADEIRA_DOCS_DIR", inherited, 1) } else { unsetenv("MADEIRA_DOCS_DIR") }
        } else {
            // The shared file is wherever the runtime would have read it: the inherited
            // $MADEIRA_DOCS_DIR, else the prefix's Documents.
            let docs = runtime.prefixURL.appendingPathComponent("Documents", isDirectory: true)
            let shared = inheritedDocsDir.map { URL(fileURLWithPath: $0) } ?? docs
            do {
                let dir = try TitleConfig.prepare(shared: shared, documents: docs, exe: r.exe, config: r.config, title: r.exe)
                setenv("MADEIRA_DOCS_DIR", dir.path, 1)
                log("config: MADEIRA_DOCS_DIR=\(dir.path) with " + r.config.keys.sorted().map { "\($0) = \(r.config[$0]!)" }.joined(separator: ", "))
            } catch {
                return Outcome(kind: .refused, line: "launch=refused config=\(error)")
            }
        }

        if let s = r.steamAPI { prepareSteamAPI(s) }
        // However the launch ends from here, the ticket goes with it (decision 0017).
        defer { if let s = r.steamAPI { removeTicket(s, when: "at exit") } }
        if let e = r.epic { prepareEpic(e) }
        // And the ownership token file (decision 0059).
        defer { if let e = r.epic { removeOwnershipFile(e, when: "at exit") } }
        // A web page the game opens goes to the host for this play only (decision 0064).
        UrlOpenerHost.arm(.init(title: r.title.isEmpty ? (r.exe as NSString).lastPathComponent : r.title, epicSignIn: r.epic != nil))
        defer { UrlOpenerHost.arm(nil) }

        // A Unity title reopens at the window size it saved; ask it for the whole screen (TitleScreen.swift).
        let dir = (withUnsafeBytes(of: tp.unix_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } as NSString)
            .deletingLastPathComponent
        if FileManager.default.fileExists(atPath: dir + "/UnityPlayer.dll"),
           let w = ProcessInfo.processInfo.environment["MADEIRA_SCREEN_W"].flatMap(Int.init),
           let h = ProcessInfo.processInfo.environment["MADEIRA_SCREEN_H"].flatMap(Int.init) {
            let extra = Display.unityScreenArgs(existing: args, width: w, height: h)
            args += extra
            log(extra.isEmpty ? "Unity title; the launch sets its own screen switches" : "Unity title; added \(extra.joined(separator: " "))")
        }

        // The host's side of the start-up self-check (SelfCheck): a phone that breaks
        // an assumption the runtime makes is refused before any JIT is spent.
        let host = SelfCheck.run()
        guard host.ok else {
            return Outcome(kind: .refused, line: "launch=refused selfcheck=\(host.name)")
        }

        log("display: \(TitleScreen.summary)")
        Fastsync.apply(log: log)
        ThermalLog.start()
        HostIO.prepareRuntime(log: WineHostRuntime.appendLog)
        if HostIO.surfaceReady.wait(timeout: .now() + 15) == .timedOut {
            log("no GameSurface after 15 s; the swap chain will find no layer")
        }
        // Every byte of the pool counts against the limit from the bless on. Read
        // again: Game Mode may have raised the limit since the Play.
        memory = MemoryLimit.read()
        let poolMB = r.poolMB ?? MemoryLimit.poolMB(memory)
        log("jit pool: \(poolMB) MiB for a memory limit of \(memory.effectiveMB.map { "\($0) MB" } ?? "not reported")"
            + (memory.simulatedPoolMB != nil ? " (simulated pool)" : ""))
        mark("surface ready; asking for JIT")
        #if !PLAYPORT_RELEASE
        Diagnostics.loadBeforeRuntime()
        #endif
        step(.waitingForJit(until: Date().addingTimeInterval(r.jitWait)))
        let started = runtime.start(poolMB: poolMB, wait: r.jitWait) { step(.startingRuntime) }
        log("runtime: \(started.detail), activation \(String(format: "%.2f", started.activationSeconds)) s")
        mark("runtime started")
        guard started.ok else {
            let line = started.selfcheck.map { "launch=failed selfcheck=\($0)" } ?? "launch=failed runtime=\(started.detail)"
            return Outcome(kind: .failed, line: line)
        }

        // After the session root started: its environment is the app's without the title's.
        var backend = r.graphics.runtimeEnvironment
        #if !PLAYPORT_RELEASE
        if !r.graphicsEnvironment.isEmpty {
            log("graphics options: " + r.graphicsEnvironment.keys.sorted().map { "\($0)=\(r.graphicsEnvironment[$0]!)" }
                .joined(separator: " "))
            backend = r.graphics.environment(graphicsOptions: r.graphicsEnvironment)
        }
        backend.merge(Diagnostics.launchEnvironment(exe: r.exe, dir: dir, graphics: r.graphics, log: log)) { own, _ in own }
        #endif
        let environment = applyEnvironment(backend: backend, steamAppID: r.steamAppID, fex: r.fex)
        step(.startingGame)
        PacedMetalLayer.onFirstFrame {
            mark("first frame")
            step(.drawing)
        }
        let pool = PoolLog()
        let rc = runtime.launch(exe: r.exe, args: args, environment: environment)
        log("wine_host_session_launch -> \(rc)")
        mark("game started")
        guard rc == 0 else {
            PacedMetalLayer.onFirstFrame { }
            return pool.end(Outcome(kind: .failed, line: "launch=failed run_exe=\(rc)"), mark: mark)
        }

        let t0 = Date()
        step(.running(since: t0))
        while true {
            // In 2 s slices, so the pool's use is logged as it grows.
            let w = runtime.wait(ms: 2_000)
            let elapsed = Date().timeIntervalSince(t0)
            if w.rc == 0 {
                let exit = UInt32(bitPattern: w.code)
                return pool.end(Outcome(kind: .exited(exit), line: "exit=\(String(format: "0x%08x", exit)) after_s=\(Int(elapsed))"),
                                mark: mark)
            }
            if w.rc < 0 {
                return pool.end(Outcome(kind: .failed, line: "launch=failed wait=\(w.rc)"), mark: mark)
            }
            pool.sample()
            if let t = pool.exhaustedAt, Date().timeIntervalSince(t) >= PoolLog.grace {
                // The restart that follows the launch ends it (decisions 0022, 0030).
                log("pool: the game is still running \(Int(PoolLog.grace)) s after it ran out of JIT memory; the restart ends it")
                return pool.end(Outcome(kind: .failed, line: "still-running after_s=\(Int(elapsed))"), mark: mark)
            }
        }
    }

    /// The pool's use during a launch: a `title: pool:` line (and a dev build's
    /// `pool` event) whenever it moved enough (JitPool.Use.worthLogging), and at
    /// the end a `pool:` mark, the use the result event reports. A pool that ran
    /// out turns the outcome into `.outOfJitMemory`. The runtime's known limits
    /// (RuntimeLimits) go the same way, as `limits:` lines whenever a count moved
    /// and a `limits:` mark at the end; reaching one does not change the outcome.
    /// So does the FEX arena's use (FexBand), as `band:` lines and a `band:` mark;
    /// a dev build also writes the arena's map into the log at the end.
    private final class PoolLog {
        /// How long a title that ran the pool out gets to end on its own.
        static let grace: TimeInterval = 10
        private var last: JitPool.Use?
        private var lastLimits: RuntimeLimits.Counts?
        private var lastBand: FexBand.Use?
        /// The thread count / 16 of the last map a dev build dumped.
        private var bandMapBucket: UInt64 = 0
        /// When a reading first showed the pool run out.
        private(set) var exhaustedAt: Date?

        static func read() -> JitPool.Use? {
            var s = wine_host_pool_stats()
            guard wine_host_pool_stats_read(&s) == 0 else { return nil }
            return JitPool.Use(size: s.size, head: s.head, headLive: s.head_live, headFree: s.head_free, tail: s.tail,
                               tailLive: s.tail_live, aliasLive: s.alias_live, aliasSlots: s.alias_slots,
                               aliasCap: s.alias_cap, images: s.images, childCopies: s.child_copies,
                               childBytes: s.child_bytes, headExhausted: s.head_exhausted, tailRefused: s.tail_refused,
                               tailFatal: s.tail_fatal, aliasFull: s.alias_full)
        }

        static func readLimits() -> RuntimeLimits.Counts? {
            var s = wine_host_limit_stats()
            guard wine_host_limit_stats_read(&s) == 0 else { return nil }
            return RuntimeLimits.Counts(wxDropped: s.wx_dropped, x18Images: s.x18_images, x18Sites: s.x18_sites,
                                        splitLock: s.split_lock)
        }

        static func readBand() -> FexBand.Use? {
            var s = wine_host_band_stats()
            guard wine_host_band_stats_read(&s) == 0 else { return nil }
            return FexBand.Use(size: s.size, used: s.used, peak: s.peak, views: s.views, largestFree: s.largest_free,
                               spanSlots: s.span_slots, spans: s.spans, callret: s.callret, l1: s.l1,
                               other: s.other, refused: s.refused)
        }

        private func sampleBand() {
            guard let band = Self.readBand(), band.worthLogging(after: lastBand) else { return }
            lastBand = band
            LaunchCoordinator.log(band.line)
            #if !PLAYPORT_RELEASE
            RunEvents.emit("band", ["line": band.line])
            // The map at 16, 32, 48… threads: a run the driver ends has no end-of-launch map.
            if band.callret / 16 > bandMapBucket {
                bandMapBucket = band.callret / 16
                wine_host_band_dump("\(band.callret) threads")
            }
            #endif
        }

        private func sampleLimits() {
            guard let limits = Self.readLimits(), limits.worthLogging(after: lastLimits) else { return }
            lastLimits = limits
            LaunchCoordinator.log(limits.line)
            #if !PLAYPORT_RELEASE
            RunEvents.emit("limits", ["line": limits.line])
            #endif
        }

        func sample() {
            sampleLimits()
            sampleBand()
            guard let use = Self.read(), use.worthLogging(after: last) else { return }
            if let e = use.exhaustion, exhaustedAt == nil {
                exhaustedAt = Date()
                LaunchCoordinator.log("pool: ran out of JIT memory (\(e.rawValue))")
            }
            last = use
            LaunchCoordinator.log(use.line)
            #if !PLAYPORT_RELEASE
            RunEvents.emit("pool", ["line": use.line])
            #endif
        }

        func end(_ outcome: Outcome, mark: (String) -> Void) -> Outcome {
            if let limits = Self.readLimits() { mark(limits.line) }
            if let band = Self.readBand() { mark(band.line) }
            #if !PLAYPORT_RELEASE
            wine_host_band_dump("launch end")
            #endif
            guard let use = Self.read() else { return outcome }
            last = use
            mark(use.line)
            var o = outcome
            o.poolMB = Int(use.size >> 20)
            guard let e = use.exhaustion else { return o }
            o.kind = .outOfJitMemory(e)
            o.line = JitPool.resultField(e) + " " + outcome.line
            return o
        }
    }
}

/// The phone's thermal state (ProcessInfo.thermalState) at the launch and at every
/// change, as `title: thermal: …` lines: a measured run that did not start at
/// `nominal` started hot and is not comparable with one that did (pp perf).
enum ThermalLog {
    static func name(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown(\(s.rawValue))"
        }
    }

    /// Observes for the life of the process, once (every launch logs its own start).
    private static let observing: Bool = {
        _ = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
            WineHostRuntime.appendLog("title: thermal: \(name(ProcessInfo.processInfo.thermalState))")
        }
        return true
    }()

    static func start() {
        WineHostRuntime.appendLog("title: thermal: \(name(ProcessInfo.processInfo.thermalState)) at launch")
        _ = observing
    }
}
