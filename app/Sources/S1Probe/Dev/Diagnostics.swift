// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Developer's diagnostics (DeveloperSettings.swift), dev builds only: what the runtime can measure about a
// game, each switched from here and applied to the next launch's environment
// (LaunchCoordinator). A person switches them on this page, and the
// workstation through the same keys (`pp ui --action set:KEY=VALUE`,
// `pp perf --pass-prof`), decision 0012.
//
//   GPU capture         DXMT writes one frame as a Metal .gputrace into the
//                       game's folder (DXMT_CAPTURE_FRAME, dxmt_command_queue.cpp),
//                       and on the Vulkan backend KosmicKrisp does
//                       (MESA_KK_GPU_CAPTURE_FRAME, patches/mesa 0017),
//                       for `pp phone pull` and tools/gputrace.py. Metal allows
//                       a capture only in a process that starts with
//                       MTL_CAPTURE_ENABLED=1, which costs every frame, so it
//                       is set at start and only while this is on: a change
//                       takes effect at Playport's next start (after a game it
//                       restarts by itself, AppRestart).
//   GPU time per pass   winemetal samples the GPU timestamps of every encoder
//                       of two frames in every 1200 presents and logs them as
//                       [pass-prof] lines (DXMT_PASS_PROF, patches/dxmt 0008;
//                       `pp perf` tables them in passes.txt).
//   CPU sampling        the runtime samples the busiest threads' PCs at about
//                       1 kHz, 3 s in every 15 s, as [wprof] lines (WINE_IOS_PROF,
//                       patches/madeira-unix 0028; `pp perf` writes profile.txt).
//   Metal validation    (off, api, shaders, stop) Metal's API validation (MTL_DEBUG_LAYER), and with
//                       shaders also its shader validation (MTL_SHADER_VALIDATION),
//                       for the whole process: like GPU capture, from Playport's
//                       next start. Metal logs each error to the device log, where
//                       the phone redacts its text (<private>): pp gpu validate
//                       counts them. "Stop at the first error"
//                       (MTL_DEBUG_LAYER_ERROR_MODE=assert) ends the process at the
//                       first one, and the crash report carries its message.
//                       Both cost CPU and GPU time: no figures from such a run.
//   Runtime counters    (on by default) the runtime's measurement-only counters on
//                       its hot paths: FEX's transition probe, ntdll's lock, wait,
//                       QPC and alert census and the wineserver request timing,
//                       which the [xp-api], [sync-census] and [srv] lines read. Off
//                       sets MADEIRA_NO_COUNTERS from Playport's next start (the
//                       runtime reads it once, in __wine_main), as the release app
//                       has them off with the samplers too (MADEIRA_NO_DIAGNOSTICS):
//                       what the counters cost, measured with the samplers kept
//                       (`pp perf --no-counters`); those lines then read zero.
//
// `pp gpu` drives all of these (docs/GPU-DEBUGGING.md).

import Foundation
import Metal
import PlayportKit

enum GPUCapture {
    static let key = "gpuCaptureFrame"
    /// The frames Settings offers: DXMT's frame index, counted from the game's first present.
    static let frames = [300, 600, 1200, 1800, 3600]

    /// The frame this process captures, as the setting was at start (loadAtStart reads it first); 0 for none.
    static let armed = max(0, UserDefaults.standard.integer(forKey: key))

    /// Before anything creates a Metal device.
    static func loadAtStart() {
        guard armed > 0 else { return }
        setenv("MTL_CAPTURE_ENABLED", "1", 1)
    }

    /// DXMT captures only in the executable DXMT_CAPTURE_EXECUTABLE names, without
    /// its .exe, and only with MTL_CAPTURE_ENABLED=1 in the Windows environment
    /// too (dxmt_capture.cpp).
    fileprivate static func environment(exe: String, dir: String, graphics: GraphicsBackend,
                                        log: (String) -> Void) -> [String: String] {
        let wanted = UserDefaults.standard.integer(forKey: key)
        guard armed > 0 else {
            if wanted > 0 { log("gpu capture: frame \(wanted) is set, from Playport's next start") }
            return [:]
        }
        let ok = MTLCaptureManager.shared().supportsDestination(.gpuTraceDocument)
        var name = String(exe.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? "")
        if name.lowercased().hasSuffix(".exe") { name.removeLast(4) }
        log("gpu capture: frame \(armed) of \(name) on \(graphics.rawValue), to the game's folder; "
            + "Metal \(ok ? "allows" : "refuses") a trace document")
        guard ok else { return [:] }
        // KosmicKrisp counts its queue's presents and names the trace kk-frame<N>-<time>.gputrace.
        if graphics == .vulkan {
            return ["MESA_KK_GPU_CAPTURE_FRAME": String(armed), "MESA_KK_GPU_CAPTURE_DIRECTORY": dir]
        }
        return ["MTL_CAPTURE_ENABLED": "1", "DXMT_CAPTURE_EXECUTABLE": name, "DXMT_CAPTURE_FRAME": String(armed)]
    }
}

enum MetalValidation {
    static let key = "metalValidation"
    /// Off; the API layer; it and shader validation; the API layer, ending the process
    /// at its first error, whose message the crash report then carries (Metal logs the
    /// others to the device log with their text redacted).
    enum Level: String, CaseIterable { case off, api, shaders, stop }

    /// The level this process runs with, as the setting was at start.
    static let armed = Level(rawValue: UserDefaults.standard.string(forKey: key) ?? "off") ?? .off

    /// Before anything creates a Metal device.
    static func loadAtStart() {
        guard armed != .off else { return }
        setenv("MTL_DEBUG_LAYER", "1", 1)
        setenv("MTL_DEBUG_LAYER_ERROR_MODE", armed == .stop ? "assert" : "nslog", 1)
        setenv("MTL_DEBUG_LAYER_WARNING_MODE", "nslog", 1)
        if armed == .shaders { setenv("MTL_SHADER_VALIDATION", "1", 1) }
    }

    fileprivate static func log(_ log: (String) -> Void) {
        let wanted = Level(rawValue: UserDefaults.standard.string(forKey: key) ?? "off") ?? .off
        if armed != .off {
            // Metal wraps the device in its validation layer's class when the layer is on.
            let device = MTLCreateSystemDefaultDevice().map { String(describing: type(of: $0 as AnyObject)) } ?? "none"
            let what = ["api": "API", "shaders": "API and shaders", "stop": "API, ending at the first error"][armed.rawValue]!
            log("diagnostics: Metal validation (\(what)); device class \(device)")
        }
        if wanted != armed { log("diagnostics: Metal validation \(wanted.rawValue) from Playport's next start") }
    }
}

enum RuntimeCounters {
    static let key = "runtimeCountersOff"

    /// Whether this process runs with the counters off, as the setting was at start.
    static let armedOff = UserDefaults.standard.bool(forKey: key)

    /// Before the runtime starts.
    static func loadAtStart() {
        guard armedOff else { return }
        setenv("MADEIRA_NO_COUNTERS", "1", 1)
    }

    fileprivate static func log(_ log: (String) -> Void) {
        if armedOff { log("diagnostics: runtime counters off (MADEIRA_NO_COUNTERS)") }
        if UserDefaults.standard.bool(forKey: key) != armedOff {
            log("diagnostics: runtime counters \(armedOff ? "on" : "off") from Playport's next start")
        }
    }
}

enum Diagnostics {
    static let passProfileKey = "passProfile"
    static let cpuProfileKey = "cpuProfile"

    /// The next launch's diagnostic variables, each logged.
    static func launchEnvironment(exe: String, dir: String, graphics: GraphicsBackend,
                                  log: (String) -> Void) -> [String: String] {
        var env = GPUCapture.environment(exe: exe, dir: dir, graphics: graphics, log: log)
        MetalValidation.log(log)
        RuntimeCounters.log(log)
        let d = UserDefaults.standard
        if d.bool(forKey: passProfileKey) { env["DXMT_PASS_PROF"] = "1"; log("diagnostics: GPU time per pass") }
        if d.bool(forKey: cpuProfileKey) { env["WINE_IOS_PROF"] = "1"; log("diagnostics: CPU sampling") }
        return env
    }

    /// Before the runtime starts. The [wprof] sampler is one thread for the whole
    /// process, armed when the session root starts (decision 0027), and it reads
    /// WINE_IOS_PROF from the process's environment then, not from a title's.
    static func loadBeforeRuntime() {
        if UserDefaults.standard.bool(forKey: cpuProfileKey) { setenv("WINE_IOS_PROF", "1", 1) } else { unsetenv("WINE_IOS_PROF") }
    }
}
