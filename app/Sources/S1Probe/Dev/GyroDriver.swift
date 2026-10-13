// SPDX-License-Identifier: GPL-3.0-or-later
// The UI driver's `gyro:` (Dev/UIDriver.swift), dev builds only (decision
// 0012): a scripted gyro (HostIOKit GyroScript) fed into gyro aim where the
// sensors' samples enter it (GyroFeed in GyroSensors.swift), so calibration,
// smoothing, the pause button and both outputs work on it as on a turning
// device. While it plays its samples replace the sensors': the phone lying
// still on a desk does not fight it. Its samples are taken only while the
// sensors run (the game's gyro output on, the game in front, no menu), as a
// sensor's are; otherwise they move nothing and the line says why. With no
// game running and the Gyro aim page up, they move its test area's dot
// (nothing reaches a guest), and the line gives where the dot ended.
//
//   gyro:<axis>=<deg/s>[+<axis>=<deg/s>...]@<ms>[/<step>...]   (rest@<ms> holds still)
//
// yaw + turns right, pitch + up, roll + clockwise; `gyro:yaw=90@500/pitch=-30@300`.

#if canImport(UIKit)
import Foundation
import HostIOKit
import PlayportKit

extension GyroSensors {
    /// Plays `spec`; nil when it played (moving something or not), else why it could not.
    func driverPlay(_ spec: String) async -> String? {
        let script: GyroScript
        do { script = try GyroScript.parse(spec) } catch { return "\(error)" }
        let before = run
        let r = await feed.play(script)
        let state = switch before {
        case .running(let d, let o): "source \(d.rawValue), output \(o.rawValue)"
        case .previewing(let d, let o): "test area: source \(d.rawValue), output \(o.rawValue)"
        case .stopped(let why): "not running: \(why)"
        }
        var moved: String
        if r.taken == 0 {
            moved = "nothing moved"
        } else if case .running(_, .rightStick) = before {
            moved = String(format: "right stick peak %.2f", r.peak)
        } else if case .previewing(_, .rightStick) = before {
            moved = String(format: "right stick peak %.2f", r.peak)
        } else {
            moved = "mouse dx=\(r.dx) dy=\(r.dy)"
        }
        if case .previewing = before {
            let dot = feed.preview.dot
            moved += String(format: "; dot at x=%.2f y=%.2f", dot.x, dot.y)
        }
        Self.log("driver \(spec): \(r.samples) samples over \(script.totalMs + GyroScript.restAfterMs) ms, \(r.taken) taken "
                 + "(\(state)): \(moved)")
        return nil
    }

    /// The driver's summary line.
    var summary: String {
        switch run {
        case .running(let d, let o): "gyro running: source \(d.rawValue), output \(o.rawValue)"
        case .previewing(let d, let o): "gyro in the test area: source \(d.rawValue), output \(o.rawValue)"
        case .stopped(let why): "gyro stopped: \(why)"
        }
    }
}
#endif
