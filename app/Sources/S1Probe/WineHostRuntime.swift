// SPDX-License-Identifier: GPL-3.0-or-later
// The runtime over the wine_host C ABI (one Mach process, wineserver as a
// thread), for a title launch (LaunchCoordinator).

import CryptoKit
import Foundation
import HostIO
import MachO
import PlayportKit
import WineHost

/// The app process's one Wine session (decisions 0027, 0030). A Play acquires
/// the JIT pool, starts the wineserver and the session root
/// (playport-session.exe, the process's one __wine_main), and runs its title
/// as the root's child. The runtime cannot start twice in a process (a second
/// wine_host_init or __wine_main aborts it), so once the pool is blessed the
/// process plays nothing more: Playport restarts itself (AppRestart, decision
/// 0029). Used by one launch thread at a time (LaunchCoordinator).
final class WineHostRuntime: @unchecked Sendable {
    static let shared = WineHostRuntime()

    /// The container's Documents, fixed at first use (the app's init):
    /// wine_host_init later points HOME at the prefix, and FileManager's
    /// Documents with it.
    nonisolated static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    var prefixURL: URL { Self.documents.appendingPathComponent("prefix") }

    /// One line into the app log (AppLog), the file wine_host_init also appends to.
    static func appendLog(_ line: String) { AppLog.append(line) }

    private init() {}

    /// The pool was blessed: from here on the runtime is this process's, and
    /// no other title can start in it.
    private(set) var poolAcquired = false

    /// Acquires the JIT pool (JitProvider), checks it (SelfCheck), starts
    /// wine_host and the session root. The wait for the debugger plus the bless
    /// is the activation cost. pooled runs once the pool is blessed and
    /// checked, before wine_host_init (the launch screen's step). The
    /// presentation switches are TitleScreen's, set before this. selfcheck
    /// names the failed assumption when the pool's self-check stopped the start.
    func start(poolMB mb: Int, wait: TimeInterval, pooled: () -> Void = {})
        -> (ok: Bool, activationSeconds: Double, detail: String, selfcheck: String?) {
        guard BuiltInJit.beginRuntime() else {
            return (false, 0, "Restart Playport after importing or migrating pairing credentials", nil)
        }
        precondition(!poolAcquired, "the session starts once per process")
        guard let runtime = Manifest.runtime else { return (false, 0, "no Runtime in bundle", nil) }
        #if PLAYPORT_RELEASE
        Self.quietRuntime()
        #else
        // KosmicKrisp's shader-source counts and slow Metal builds (mesa 0016).
        setenv("MESA_KK_DEBUG", "compile", 0)
        #endif
        let size = mb << 20
        let t0 = Date()
        let pool: JitProvider.Pool
        do {
            pool = try JitProvider.acquire(size: size, wait: wait)
        } catch {
            return (false, Date().timeIntervalSince(t0), "JIT pool (\(mb) MiB): \(error)", nil)
        }
        poolAcquired = true
        let activation = Date().timeIntervalSince(t0)
        let check = SelfCheck.run(pool: pool)
        guard check.ok else { return (false, activation, "pool \(mb) MiB; selfcheck \(check.name)", check.name) }
        pooled()
        let rc = runtime.path.withCString { rt in
            prefixURL.path.withCString { px in
                AppLog.path.withCString { lp in
                    var cfg = wine_host_config(abi_version: WINE_HOST_ABI_VERSION, runtime_dir: rt,
                                               prefix_dir: px, log_path: lp, log: nil,
                                               jit_rx: pool.rx, jit_rw: pool.rw, jit_size: size)
                    return wine_host_init(&cfg)
                }
            }
        }
        guard rc == 0 else { return (false, activation, "pool \(mb) MiB; wine_host_init -> \(rc)", nil) }
        let root = wine_host_session_start(15_000)
        return (root == 0, activation, "pool \(mb) MiB; wine_host_init -> 0; session root -> \(root)", nil)
    }

    #if PLAYPORT_RELEASE
    /// A release build's runtime logs only what the runtime itself calls an
    /// error, and measures nothing (decision 0009). The switches are the ones
    /// the Hollow Knight measurements ran with (MADEIRA_QUIET, WINEDEBUG=-all),
    /// plus MADEIRA_NO_DIAGNOSTICS (patches/madeira-unix 0018, patches/dxmt
    /// 0005, 0007), DXMT's own level, and Proton's defaults for DXVK and
    /// vkd3d-proton when logging is off (DXVK_LOG_LEVEL, VKD3D_DEBUG,
    /// VKD3D_SHADER_DEBUG = none). A title's configuration (madeira.cfg env.*)
    /// still wins over the ones set without overwrite.
    private static func quietRuntime() {
        setenv("MADEIRA_QUIET", "1", 1)          // no [PROF] sampler, no per-present or poll lines
        setenv("MADEIRA_NO_DIAGNOSTICS", "1", 1) // no samplers, no ntdll or DXMT census
        setenv("WINEDEBUG", "-all", 0)           // no Wine debug channel
        setenv("DXMT_LOG_LEVEL", "error", 0)     // DXMT's info and warn lines
        setenv("DXVK_LOG_LEVEL", "none", 0)      // DXVK (d3d9, d3d11 on Vulkan), as Proton
        setenv("VKD3D_DEBUG", "none", 0)         // vkd3d-proton (d3d12), as Proton
        setenv("VKD3D_SHADER_DEBUG", "none", 0)  // its shader compiler, as Proton
    }
    #endif

    /// Starts a title as the session root's child (wine_host_session_launch):
    /// `environment` is set over the root's own for this title only.
    func launch(exe: String, args: [String], environment: [String: String]) -> Int32 {
        request(exe: exe, args: args, environment: environment, wine_host_session_launch)
    }

    /// Starts one of the title's own prerequisite installers as the session
    /// root's child, before the title (wine_host_session_prerequisite, decision
    /// 0079); `wait` then waits for it as for the title.
    func launchPrerequisite(exe: String, args: [String], environment: [String: String]) -> Int32 {
        request(exe: exe, args: args, environment: environment, wine_host_session_prerequisite)
    }

    /// launchPrerequisite with the store's own command-line string after the executable's quoted
    /// path, as it is (wine_host_session_prerequisite_line, decision 0090: GOG's redistributables).
    func launchPrerequisite(exe: String, commandLine: String, environment: [String: String]) -> Int32 {
        request(exe: exe, args: [commandLine], environment: environment) { exe, args, _, env, nenv, timeout in
            wine_host_session_prerequisite_line(exe, args?[0], env, nenv, timeout)
        }
    }

    private typealias SessionRequest = (UnsafePointer<CChar>?, UnsafePointer<UnsafePointer<CChar>?>?, Int32,
                                        UnsafePointer<UnsafePointer<CChar>?>?, Int32, Int32) -> Int32

    private func request(exe: String, args: [String], environment: [String: String], _ call: SessionRequest) -> Int32 {
        let cArgs = args.map { strdup($0) }
        let cEnv = environment.keys.sorted().map { strdup("\($0)=\(environment[$0]!)") }
        defer { (cArgs + cEnv).forEach { free($0) } }
        return cArgs.map { UnsafePointer($0) }.withUnsafeBufferPointer { a in
            cEnv.map { UnsafePointer($0) }.withUnsafeBufferPointer { e in
                call(exe, a.baseAddress, Int32(a.count), e.baseAddress, Int32(e.count), 30_000)
            }
        }
    }

    /// Waits up to `ms` for the running title (wine_host_session_wait).
    func wait(ms: Int32) -> (rc: Int32, code: Int32) {
        var code: Int32 = 0
        let rc = wine_host_session_wait(ms, &code)
        return (rc, code)
    }
}

/// The staged Runtime/ tree ships at the app root (xtool.yml `resources`),
/// where ntdll's unix side looks for nls/ and <arch>-windows/.
enum Manifest {
    static var runtime: URL? {
        let root = Bundle.main.bundleURL
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts.tsv").path) ? root : nil
    }

    /// Whether this build carries a graphics backend: DXMT always, another
    /// only when its builtins were staged under the runtime (GraphicsBackend.runtimeOverlay).
    static func has(_ graphics: GraphicsBackend) -> Bool {
        guard let overlay = graphics.runtimeOverlay else { return true }
        guard let runtime else { return false }
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: runtime.appendingPathComponent(overlay).path, isDirectory: &dir)
            && dir.boolValue
    }

    /// This app build, for a prerequisite that failed with another (PLA-171): the first 16 hex
    /// digits of the SHA-256 of the runtime's record (artifacts.tsv, every staged file's digest)
    /// and the executable's LC_UUID (the linker's digest of the app's own code). Two installs of
    /// one IPA have the same; a build that changed a runtime file or the app's code another.
    static let build: String = {
        var h = SHA256()
        if let runtime, let record = try? Data(contentsOf: runtime.appendingPathComponent("artifacts.tsv")) {
            h.update(data: record)
        }
        h.update(data: Data((executableUUID() ?? "no-uuid").utf8))
        return h.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }()

    /// The main executable's LC_UUID, nil without one.
    private static func executableUUID() -> String? {
        guard let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64 else { return nil }
        var at = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let command = at.loadUnaligned(as: load_command.self)
            if command.cmd == UInt32(LC_UUID) {
                return UUID(uuid: at.loadUnaligned(as: uuid_command.self).uuid).uuidString
            }
            at = at.advanced(by: Int(command.cmdsize))
        }
        return nil
    }
}
