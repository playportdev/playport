// SPDX-License-Identifier: GPL-3.0-or-later
/// Gyro aim (docs/plans/2026-10-09-touch-controls.md, "Gyro"): a gyro's
/// angular-velocity samples turned into relative mouse motion or a right-stick
/// deflection. Pure: the samples' timestamps are its only clock, so a recorded
/// or scripted sequence gives the same output every time.
///
/// Frame and units. A sample is in the aim frame, whatever the source (the
/// phone held in landscape, a controller held flat; the sources map their own
/// axes onto it): x to the right, y up, z toward the player, right-handed.
/// Rates are rad/s about those axes, so +y turns the view left and +x tilts it
/// up. Gravity is in the same frame, any length (held upright it is about
/// (0, -1, 0)); only its direction is used.
///
/// - **Calibration.** The bias (what the gyro reads at rest) is learnt while
///   the device is still: over the last `stillWindow` seconds every axis
///   stayed within `stillSpread` (max − min), the mean rate is under
///   `maxBias`, and gravity's direction moved less than `stillGravitySpread`.
///   The first estimate needs only `firstStillWindow` seconds (a pad just put
///   down or connected is drifting until then: touch controls 2f) and sets the
///   bias to its mean; later windows are `stillWindow` long and move it toward
///   theirs with time constant `biasTimeConstant`. Nothing is learnt from a
///   window with any motion in it, so a held aim is never taken for bias.
/// - **Turn axis.** Player space (the default) turns about the world's
///   vertical however the device is tilted: the rate's component about
///   gravity, relaxed by `playerSpaceRelax` toward the yaw-and-roll rate so a
///   steep tilt still turns fully. Yaw takes the device's y alone, roll its z
///   (a steering wheel). The vertical is always the device's x (pitch).
/// - **Smoothing.** Soft tiered (`GyroSmoothing.normal`): speeds under
///   `smoothingLow` are the average over the last `smoothingWindow` seconds,
///   speeds over `smoothingHigh` pass as they are, and between them a blend.
///   It steadies a held aim without delaying a turn. `light` halves the
///   window and both thresholds; `off` passes every sample as it is (a
///   controller's gyro felt delayed with it: touch controls U).
/// - **Mouse.** Angle × `mouseCountsPerDegree` × sensitivity, in whole counts
///   with the remainder carried to the next sample: linear, no acceleration,
///   no dead zone.
/// - **Right stick.** Speed × sensitivity / `stickFullScale` as a deflection,
///   at most 1; InputMixer adds it to slot 0's right stick and clamps. With an
///   anti-dead-zone a (0..<1), a deflection d is a + d × (1 − a) along its own
///   direction, so the slowest turn already starts past the game's own stick
///   dead zone (Portal 2 ate 0.33 and below: touch controls 2d); a deflection
///   under `stickRest` (a still device's residual) stays zero, so nothing creeps.
/// - **Vertical ratio and invert** scale and flip the two output axes.
/// - **Pause.** While the pause button is held the output is zero; the
///   smoothing restarts on release and the calibration carries on as if
///   nothing happened, so release brings no jump.
/// - A gap of more than `maxStep` between samples (the sensors stopped)
///   restarts the windows and moves nothing for the gap; `restart()` does the
///   same at once when the sensors start again.
/// - A sample with a value that is not finite (NaN, infinity) is dropped: it
///   moves nothing and leaves the windows, the bias and the smoothing as they were.

import Foundation

public struct GyroAim: Sendable {
    public static let stillWindow = 1.0                         // s
    public static let firstStillWindow = 0.5                    // s, until the first estimate
    public static let stillSpread = 0.04                        // rad/s, max − min per axis (≈ 2.3 °/s)
    public static let maxBias = 0.05                            // rad/s (≈ 2.9 °/s)
    public static let stillGravitySpread = 0.02                 // unit vector, max − min per axis (≈ 1.1°)
    public static let biasTimeConstant = 0.5                    // s
    public static let playerSpaceRelax = 1.41
    public static let smoothingWindow = 0.125                   // s
    public static let smoothingLow = 0.04, smoothingHigh = 0.08 // rad/s (≈ 2.3 and 4.6 °/s)
    public static let mouseCountsPerDegree = 20.0               // at sensitivity 1
    public static let stickFullScale = 180.0                    // °/s for a full deflection at sensitivity 1
    public static let maxStep = 0.1                             // s
    /// The right-stick deflection under which the stick rests (a still device's residual noise).
    public static let stickRest = 0.005

    public struct Config: Equatable, Sendable {
        public var output: GyroOutput
        public var turnAxis: GyroTurnAxis
        public var sensitivity: Double
        public var verticalRatio: Double
        public var invertX: Bool
        public var invertY: Bool
        /// Right stick only: where a deflection starts, 0..<1 (0: none).
        public var antiDeadZone: Double
        public var smoothing: GyroSmoothing

        public init(output: GyroOutput = .off, turnAxis: GyroTurnAxis = .playerSpace, sensitivity: Double = 1,
                    verticalRatio: Double = 1, invertX: Bool = false, invertY: Bool = false, antiDeadZone: Double = 0,
                    smoothing: GyroSmoothing = .normal) {
            self.output = output; self.turnAxis = turnAxis; self.sensitivity = sensitivity
            self.verticalRatio = verticalRatio; self.invertX = invertX; self.invertY = invertY
            self.antiDeadZone = antiDeadZone; self.smoothing = smoothing
        }
    }

    /// A change of any setting drops the carried remainder and the smoothing.
    public var config: Config {
        didSet { if config != oldValue { motion.reset(); smoothing = [] } }
    }

    /// The learnt bias, rad/s; zero until the device was first still.
    public private(set) var bias = GyroVector.zero
    public private(set) var calibrated = false

    private var last: Double?
    /// The calibration window: `window[windowStart...]`, the last `stillWindow` seconds
    /// (the samples before `windowStart` are dropped in batches, not one by one).
    private var window: [GyroSample] = []
    private var windowStart = 0
    private var smoothing: [(time: Double, aim: (x: Double, y: Double))] = []
    private var motion = RelativeMotion()

    public init(config: Config = Config()) { self.config = config }

    /// The sensors start again (after a stop: the menu, the background, a
    /// setting): the windows, the smoothing and the carried remainder start
    /// over, so nothing from before the stop moves the aim; the bias learnt is kept.
    public mutating func restart() {
        last = nil
        window = []
        windowStart = 0
        smoothing = []
        motion.reset()
    }

    /// One sample; `paused` while the pause button is held.
    public mutating func add(_ s: GyroSample, paused: Bool = false) -> GyroAimOutput {
        guard s.time.isFinite, s.rate.isFinite, s.gravity.isFinite else {
            switch config.output {
            case .off: return .none
            case .mouse: return .mouse(dx: 0, dy: 0)
            case .rightStick: return .rightStick(x: 0, y: 0)
            }
        }
        let dt: Double
        if let l = last, s.time - l <= Self.maxStep {
            dt = max(0, s.time - l)
        } else {
            dt = 0
            if last != nil { window = []; windowStart = 0; smoothing = [] }
        }
        last = max(last ?? s.time, s.time)
        calibrate(s, dt: dt)
        guard config.output != .off else { return .none }
        if paused {
            smoothing = []
            return config.output == .mouse ? .mouse(dx: 0, dy: 0) : .rightStick(x: 0, y: 0)
        }

        let r = s.rate - bias
        let turn: Double
        switch config.turnAxis {
        case .yaw: turn = r.y
        case .roll: turn = r.z
        case .playerSpace: turn = Self.playerSpaceYaw(rate: r, gravity: s.gravity)
        }
        let smoothed = smooth((x: -turn, y: r.x), time: s.time)
        // Right and up positive, in degrees per second.
        let degrees = 180 / Double.pi
        let h = smoothed.x * degrees * (config.invertX ? -1 : 1)
        let v = smoothed.y * degrees * config.verticalRatio * (config.invertY ? -1 : 1)
        switch config.output {
        case .off:
            return .none
        case .mouse:
            let k = Self.mouseCountsPerDegree * config.sensitivity * dt
            // Windows' +y is down.
            let d = motion.add(dx: h * k, dy: -v * k) ?? (0, 0)
            return .mouse(dx: d.0, dy: d.1)
        case .rightStick:
            var x = h * config.sensitivity / Self.stickFullScale, y = v * config.sensitivity / Self.stickFullScale
            let length = (x * x + y * y).squareRoot()
            if length > 1 { x /= length; y /= length }
            return Self.past(antiDeadZone: config.antiDeadZone, x: x, y: y)
        }
    }

    /// A deflection (length at most 1) moved past an anti-dead-zone along its own
    /// direction; one under `stickRest`, or any with no anti-dead-zone, as it is.
    static func past(antiDeadZone a: Double, x: Double, y: Double) -> GyroAimOutput {
        guard a > 0, a.isFinite else { return .rightStick(x: x, y: y) }
        let d = min(1, (x * x + y * y).squareRoot())
        guard d >= stickRest else { return .rightStick(x: 0, y: 0) }
        let k = (min(a, 1) + d * (1 - min(a, 1))) / d
        return .rightStick(x: x * k, y: y * k)
    }

    /// The rate about the world's vertical (+ left), relaxed toward the rate in the yaw-roll plane.
    static func playerSpaceYaw(rate r: GyroVector, gravity g: GyroVector) -> Double {
        let n = g.length
        guard n > 0, n.isFinite else { return r.y }
        let world = -(g.y * r.y + g.z * r.z) / n
        let bound = (r.y * r.y + r.z * r.z).squareRoot()
        return (world < 0 ? -1 : 1) * min(abs(world) * playerSpaceRelax, bound)
    }

    private mutating func calibrate(_ s: GyroSample, dt: Double) {
        window.append(s)
        while window.count - windowStart > 1, window[windowStart + 1].time <= s.time - Self.stillWindow { windowStart += 1 }
        if windowStart >= 256, windowStart * 2 >= window.count {
            window.removeFirst(windowStart)
            windowStart = 0
        }
        let span = calibrated ? Self.stillWindow : Self.firstStillWindow
        guard let start = window[windowStart...].lastIndex(where: { $0.time <= s.time - span }), window.count - start > 1
        else { return }
        let still = window[start...]
        var lo = window[start].rate, hi = lo, sum = GyroVector.zero
        var glo = window[start].gravity.unit, ghi = glo
        for w in still {
            lo = lo.min(w.rate); hi = hi.max(w.rate); sum = sum + w.rate
            let g = w.gravity.unit
            glo = glo.min(g); ghi = ghi.max(g)
        }
        let spread = hi - lo, gspread = ghi - glo
        guard spread.x <= Self.stillSpread, spread.y <= Self.stillSpread, spread.z <= Self.stillSpread,
              gspread.x <= Self.stillGravitySpread, gspread.y <= Self.stillGravitySpread, gspread.z <= Self.stillGravitySpread
        else { return }
        let mean = sum * (1 / Double(still.count))
        guard mean.length <= Self.maxBias else { return }
        if calibrated {
            bias = bias + (mean - bias) * (1 - exp(-dt / Self.biasTimeConstant))
        } else {
            bias = mean
            calibrated = true
        }
    }

    private mutating func smooth(_ aim: (x: Double, y: Double), time: Double) -> (x: Double, y: Double) {
        let scale: Double
        switch config.smoothing {
        case .off: return aim
        case .light: scale = 0.5
        case .normal: scale = 1
        }
        let low = Self.smoothingLow * scale, high = Self.smoothingHigh * scale
        let speed = (aim.x * aim.x + aim.y * aim.y).squareRoot()
        let direct = max(0, min(1, (speed - low) / (high - low)))
        smoothing.append((time, (aim.x * (1 - direct), aim.y * (1 - direct))))
        while let f = smoothing.first, f.time <= time - Self.smoothingWindow * scale { smoothing.removeFirst() }
        var sx = 0.0, sy = 0.0
        for e in smoothing { sx += e.aim.x; sy += e.aim.y }
        let n = Double(smoothing.count)
        return (aim.x * direct + sx / n, aim.y * direct + sy / n)
    }
}

/// What gyro aim drives.
public enum GyroOutput: String, Codable, CaseIterable, Sendable {
    case off, mouse, rightStick
}

/// How much GyroAim steadies slow motion: none, or its soft tiered smoothing
/// over half or all of its window and thresholds.
public enum GyroSmoothing: String, Codable, CaseIterable, Sendable {
    case off, light, normal
}

/// Which rotation turns the view left and right.
public enum GyroTurnAxis: String, Codable, CaseIterable, Sendable {
    /// About the world's vertical, however the device is tilted.
    case playerSpace
    /// About the device's own up axis.
    case yaw
    /// About the axis toward the player, like a steering wheel.
    case roll
}

/// One sample: rad/s in the aim frame (GyroAim), gravity in the same frame, time in seconds.
public struct GyroSample: Equatable, Sendable {
    public var time: Double
    public var rate: GyroVector
    public var gravity: GyroVector
    public init(time: Double, rate: GyroVector, gravity: GyroVector = GyroVector(x: 0, y: -1, z: 0)) {
        self.time = time; self.rate = rate; self.gravity = gravity
    }
}

public struct GyroVector: Equatable, Sendable {
    public var x: Double, y: Double, z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
    public static let zero = GyroVector(x: 0, y: 0, z: 0)

    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
    var unit: GyroVector { let n = length; return n > 0 ? self * (1 / n) : .zero }
    func min(_ o: GyroVector) -> GyroVector { GyroVector(x: Swift.min(x, o.x), y: Swift.min(y, o.y), z: Swift.min(z, o.z)) }
    func max(_ o: GyroVector) -> GyroVector { GyroVector(x: Swift.max(x, o.x), y: Swift.max(y, o.y), z: Swift.max(z, o.z)) }
    static func + (a: GyroVector, b: GyroVector) -> GyroVector { GyroVector(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func - (a: GyroVector, b: GyroVector) -> GyroVector { GyroVector(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func * (a: GyroVector, k: Double) -> GyroVector { GyroVector(x: a.x * k, y: a.y * k, z: a.z * k) }
}

/// GyroAim's result for one sample.
public enum GyroAimOutput: Equatable, Sendable {
    /// Gyro aim is off.
    case none
    /// Relative mouse motion, Windows orientation (+y down); (0, 0) moves nothing.
    case mouse(dx: Int32, dy: Int32)
    /// A right-stick deflection, -1...1, XInput orientation (+y up), to add to slot 0's.
    case rightStick(x: Double, y: Double)
}

extension PadControl {
    /// Whether a pad's values hold this control: its button, or its trigger past
    /// XInput's threshold (XINPUT_GAMEPAD_TRIGGER_THRESHOLD, 30). A stick is never held.
    public func isHeld(in v: PadValues) -> Bool {
        switch self {
        case .lt: return v.leftTrigger > 30
        case .rt: return v.rightTrigger > 30
        case .leftStick, .rightStick: return false
        default:
            var p = PadInput()
            p.press(self)
            return v.buttons & PadMapping.values(p).buttons != 0
        }
    }
}
