// SPDX-License-Identifier: GPL-3.0-or-later
// HIO_VPAD: the scripted pad the workstation's measurement runs drive
// (`pp pad`). Dev builds only (decision 0009).

#if canImport(UIKit)
import Foundation
import HostIO
import HostIOKit

extension HostIO {
    /// HIO_VPAD=<file in Documents>: the scripted pad (VirtualPad), in the
    /// lowest free slot, connected now because Unity lists controllers only
    /// when its input starts.
    func startVirtualPad() {
        guard let name = ProcessInfo.processInfo.environment["HIO_VPAD"], !name.isEmpty, !name.contains("/") else { return }
        guard let slot = connectSlot(ObjectIdentifier(VirtualPad.self)) else { return }
        VirtualPad.shared.start(path: WineHostRuntime.documents.appendingPathComponent(name).path, slot: slot)
    }
}

/// The scripted pad (HostIOKit.PadScript, docs/DEVICE.md "Scripted controller"):
/// every 8 ms, on its own queue, the script's pad goes to the controller
/// snapshot (host_pad_set takes a short lock, and an unchanged pad is not a
/// new XInput packet); every 200 ms the file is checked, and a changed file replaces the
/// script and starts it from the top. A file already there at start is an
/// earlier session's script (a looping walk would play into the menus), so
/// only one written after the start plays. The log gets each step as it starts,
/// with the wall-clock time, so frame-time lines can be matched to what the
/// Knight was doing. Its values reach the guest through HostIO's gate, as a
/// controller's do, so the in-game menu holds them too.
final class VirtualPad: @unchecked Sendable {
    static let shared = VirtualPad()
    private let queue = DispatchQueue(label: "hostio.vpad", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var path = "", slot = 0
    private var stamp: (Date?, Int)? = nil
    private var script = PadScript(), t0: UInt64 = 0, step: Int? = nil, ticks = 0, loads = 0
    private var menuSeen = PadInput()

    func start(path: String, slot: Int) {
        queue.async { [self] in
            self.path = path
            self.slot = slot
            var rest = hio_pad_state()
            host_pad_set(Int32(slot), &rest)
            stamp = Self.stamp(path)
            HostIO.log("vpad: slot \(slot) connected; script \(path)"
                       + (stamp == nil ? "" : " (the file there now is left from before; waiting for a new one)"))
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
            t.setEventHandler { [self] in tick() }
            t.resume()
            timer = t
        }
    }

    private static func ms(_ ns: UInt64) -> Int { Int(ns / 1_000_000) }

    /// Local wall-clock time as the runtime's own lines carry it ([HH:MM:SS.mmm]),
    /// so a step lines up with the Metal HUD and [xp] lines around it.
    private static func clock() -> String {
        var tv = timeval(), tm = tm()
        gettimeofday(&tv, nil)
        var t = tv.tv_sec
        localtime_r(&t, &tm)
        return String(format: "[%02d:%02d:%02d.%03d]", tm.tm_hour, tm.tm_min, tm.tm_sec, Int(tv.tv_usec) / 1000)
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        if ticks % 25 == 0 { reload(now) }
        ticks += 1
        let (s, input) = script.at(ms: Self.ms(now - t0))
        if s != step {
            step = s
            let what = s.map { "step \($0 + 1)/\(script.steps.count)" } ?? "done"
            HostIO.log("\(Self.clock()) vpad: \(what) (script \(loads))")
        }
        HostIO.publish(PadMapping.values(input), slot: slot, changesOnly: true)
        // The in-game menu reads the script as it reads a controller: HOME held opens it,
        // and while it is up the script's presses are the menu's (HostIO.menuInput).
        if input != menuSeen {
            menuSeen = input
            DispatchQueue.main.async { MainActor.assumeIsolated { HostIO.shared.menuInput(input) } }
        }
    }

    private static func stamp(_ path: String) -> (Date?, Int)? {
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        return a.map { ($0[.modificationDate] as? Date, ($0[.size] as? NSNumber)?.intValue ?? -1) }
    }

    private func reload(_ now: UInt64) {
        guard let s = Self.stamp(path), s.0 != stamp?.0 || s.1 != stamp?.1 else { return }
        stamp = s
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        do {
            script = try PadScript.parse(text)
            loads += 1
            t0 = now
            step = -1   // logs the first step
            HostIO.log("\(Self.clock()) vpad: script \(loads) loaded: \(script.steps.count) steps, "
                       + "\(script.totalMs) ms\(script.loops ? ", looping" : "")")
        } catch {
            HostIO.log("vpad: \(path): \(error); keeping script \(loads)")
        }
    }
}
#endif
