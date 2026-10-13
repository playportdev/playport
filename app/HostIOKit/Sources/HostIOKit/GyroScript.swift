// SPDX-License-Identifier: GPL-3.0-or-later
/// A scripted gyro: the angular-velocity steps a dev build's `pp ui` action
/// `gyro:<script>` plays into gyro aim where the sensors' samples enter it
/// (S1Probe's GyroSensors.swift), so calibration, smoothing and both outputs
/// see what a turning device would give them, with the phone lying still.
///
/// Steps are separated by `/`; each is one or more `<axis>=<deg/s>` joined by
/// `+`, or `rest`, then `@<ms>`, its duration. The axes are the aim's, as the
/// player sees the screen:
///
/// - `yaw`: turning about the vertical, + to the right;
/// - `pitch`: tilting the top edge, + up (toward the player);
/// - `roll`: turning like a steering wheel, + clockwise (the top to the right).
///
/// `yaw=90@500/pitch=-30+yaw=10@300/rest@200` turns right at 90 °/s for half a
/// second, then down at 30 °/s while turning right at 10 °/s for 0.3 s, then
/// holds still. Rates are at most 2000 °/s, a step 1–10000 ms, a script
/// 60 s; an axis once per step.
///
/// The samples run at `hz` with gravity straight down the aim frame (the device
/// held upright in the current orientation, where yaw and player space agree):
/// first one at rest, then one at the end of each 1/`hz` s carrying the rate of
/// that interval, so a step's angle is exactly rate × duration, then
/// `restAfterMs` at rest so the right stick comes back to centre.
public struct GyroScript: Equatable, Sendable {
    public static let hz = 100.0
    public static let maxRate = 2000.0          // °/s
    public static let maxStepMs = 10_000
    public static let maxTotalMs = 60_000
    public static let restAfterMs = 150
    public static let upright = GyroVector(x: 0, y: -1, z: 0)

    public struct Step: Equatable, Sendable {
        /// rad/s in the aim frame (GyroAim).
        public var rate: GyroVector
        public var ms: Int
        public init(rate: GyroVector, ms: Int) { self.rate = rate; self.ms = ms }
    }

    public var steps: [Step]
    public init(steps: [Step]) { self.steps = steps }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    public var totalMs: Int { steps.reduce(0) { $0 + $1.ms } }

    public static func parse(_ text: String) throws -> GyroScript {
        func fail(_ m: String) -> ParseError { ParseError(message: m) }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var steps: [Step] = []
        for part in parts {
            let at = part.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
            guard at.count == 2, let ms = Int(at[1]), (1...maxStepMs).contains(ms) else {
                throw fail("\(part) is not <axis>=<deg/s>[+...]@<ms> or rest@<ms> (1-\(maxStepMs) ms)")
            }
            var rate = GyroVector.zero
            if at[0] != "rest" {
                var seen: Set<String> = []
                for term in at[0].split(separator: "+", omittingEmptySubsequences: false).map(String.init) {
                    let kv = term.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
                    guard kv.count == 2, let v = Double(kv[1]), v.isFinite, abs(v) <= maxRate else {
                        throw fail("\(term) is not <axis>=<deg/s> (yaw, pitch or roll, at most \(Int(maxRate)) deg/s)")
                    }
                    guard seen.insert(kv[0]).inserted else { throw fail("\(kv[0]) twice in \(part)") }
                    let r = v * Double.pi / 180
                    switch kv[0] {
                    case "yaw": rate.y = -r      // +y turns the view left
                    case "pitch": rate.x = r
                    case "roll": rate.z = -r     // +z is counter-clockwise as the player sees it
                    default: throw fail("\(kv[0]) is not yaw, pitch or roll")
                    }
                }
            }
            steps.append(Step(rate: rate, ms: ms))
        }
        let script = GyroScript(steps: steps)
        guard script.totalMs <= maxTotalMs else { throw fail("the script lasts \(script.totalMs) ms, more than \(maxTotalMs)") }
        return script
    }

    /// The rate at `ms` into the script; zero past its end.
    public func rate(atMs ms: Double) -> GyroVector {
        var t = 0.0
        for s in steps {
            if ms < t + Double(s.ms) { return s.rate }
            t += Double(s.ms)
        }
        return .zero
    }

    /// The samples from `start` (seconds, the sensors' clock): one at rest, the
    /// steps, then `restAfterMs` at rest.
    public func samples(from start: Double) -> [GyroSample] {
        let step = 1000 / Self.hz
        let n = Int((Double(totalMs + Self.restAfterMs) / step).rounded(.up))
        return (0...n).map { k in
            // Sample k ends the interval ((k - 1) step, k step] and carries its rate.
            let rate = k == 0 ? .zero : self.rate(atMs: (Double(k) - 0.5) * step)
            return GyroSample(time: start + Double(k) / Self.hz, rate: rate, gravity: Self.upright)
        }
    }
}
