// SPDX-License-Identifier: GPL-3.0-or-later
// Gyro aim's settings (docs/plans/2026-10-09-touch-controls.md, "Gyro";
// GyroAim.dc.html), stored like the on-screen controls' (Controls.swift):
// the defaults under their own UserDefaults keys, each game's own (GameGyro)
// as JSON with nil fields following the defaults. HostIOKit GyroAim does the
// processing; `aimConfig` is what it takes.
//
// - Output: Off (the default), Mouse or Right stick. Always on when not Off:
//   no button has to be held.
// - Source: Automatic (a controller's gyro when it has one, else the
//   iPhone's), iPhone or Controller.
// - Sensitivity (a multiplier of GyroAim's scale; 1.5× by default, owner
//   2026-10-13, 1.0× still GyroAim's own scale), vertical ratio, turn axis
//   (player space, yaw or roll), invert X and Y.
// - Anti-dead-zone (right stick only): where the stick's deflection starts,
//   past a game's own dead zone; 0.27 by default (XInput's right-stick dead
//   zone, 8689/32767), 0 for none.
// - Pause button: none by default; a pad button that, held, stops the aim
//   (saved as `none` or an action name, `pad:lb`).
// - Smoothing: Auto (the default: Off for a controller's gyro, Normal for the
//   iPhone's; owner 2026-10-13, a controller's felt delayed with it), Off,
//   Light or Normal (HostIOKit GyroSmoothing). GyroAim takes it resolved for
//   the gyro it reads (`aimConfig(device:)`).
//
// Every field may be left out of saved JSON (its default); a value this
// build does not know is refused, as GameControls' are. A game's own are part
// of its GameControls record (ControlsStore).
//
// GyroRun decides when the sensors run, and which (S1Probe's GyroSensors.swift).

import Foundation
import HostIOKit

/// Where gyro aim reads rotation from.
public enum GyroSource: String, Codable, CaseIterable, Sendable {
    /// The connected controller's gyro when it has one, else the iPhone's.
    case auto
    case phone
    case controller
}

/// How much gyro aim steadies slow motion: a level, or Auto (by the gyro read).
public enum GyroSmoothingChoice: String, Codable, CaseIterable, Sendable {
    case auto, off, light, normal

    /// The level GyroAim takes for `device`'s gyro: Auto is Off for a controller, Normal for the iPhone.
    public func smoothing(for device: GyroDevice) -> GyroSmoothing {
        switch self {
        case .auto: device == .controller ? .off : .normal
        case .off: .off
        case .light: .light
        case .normal: .normal
        }
    }
}

/// The pad button that stops gyro aim while held, or none.
public enum GyroPauseButton: Equatable, Sendable {
    case none
    case pad(PadControl)

    /// The control, nil for none.
    public var control: PadControl? {
        if case .pad(let c) = self { return c }
        return nil
    }

    /// `none`, or the button's action name (`pad:lb`).
    public var name: String {
        switch self {
        case .none: "none"
        case .pad(let c): InputAction.pad(c).name
        }
    }

    /// From its saved form; nil for anything but `none` or a pad button (not a stick).
    public init?(name: String) {
        if name == "none" { self = .none; return }
        guard case .pad(let c)? = InputAction(name: name), !c.isStick else { return nil }
        self = .pad(c)
    }
}

extension GyroPauseButton: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let b = GyroPauseButton(name: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "\(s) is not a gyro pause button")
        }
        self = b
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}

/// Gyro aim's settings, complete: the defaults, or a game's resolved over them.
public struct GyroSettings: Codable, Equatable, Sendable {
    public static let outputKey = "gyro.output"
    public static let sourceKey = "gyro.source"
    public static let sensitivityKey = "gyro.sensitivity"
    public static let verticalRatioKey = "gyro.verticalRatio"
    public static let turnAxisKey = "gyro.turnAxis"
    public static let invertXKey = "gyro.invertX"
    public static let invertYKey = "gyro.invertY"
    public static let pauseButtonKey = "gyro.pauseButton"
    public static let antiDeadZoneKey = "gyro.antiDeadZone"
    public static let smoothingKey = "gyro.smoothing"

    /// The sensitivities and vertical ratios a value is kept to.
    public static let sensitivityRange = 0.05...20.0
    public static let verticalRatioRange = 0.0...4.0
    public static let antiDeadZoneRange = 0.0...0.9
    public static let defaultSensitivity = 1.5
    /// XInput's right-stick dead zone (XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE, 8689 of 32767), rounded.
    public static let defaultAntiDeadZone = 0.27

    public var output = GyroOutput.off
    public var source = GyroSource.auto
    public var sensitivity = GyroSettings.defaultSensitivity
    public var verticalRatio = 1.0
    public var turnAxis = GyroTurnAxis.playerSpace
    public var invertX = false
    public var invertY = false
    public var pauseButton = GyroPauseButton.none
    public var antiDeadZone = GyroSettings.defaultAntiDeadZone
    public var smoothing = GyroSmoothingChoice.auto

    public init(output: GyroOutput = .off, source: GyroSource = .auto, sensitivity: Double = GyroSettings.defaultSensitivity,
                verticalRatio: Double = 1,
                turnAxis: GyroTurnAxis = .playerSpace, invertX: Bool = false, invertY: Bool = false,
                pauseButton: GyroPauseButton = .none, antiDeadZone: Double = GyroSettings.defaultAntiDeadZone,
                smoothing: GyroSmoothingChoice = .auto) {
        self.output = output; self.source = source; self.sensitivity = sensitivity; self.verticalRatio = verticalRatio
        self.turnAxis = turnAxis; self.invertX = invertX; self.invertY = invertY; self.pauseButton = pauseButton
        self.antiDeadZone = antiDeadZone; self.smoothing = smoothing
    }

    enum CodingKeys: String, CodingKey {
        case output, source, sensitivity, verticalRatio, turnAxis, invertX, invertY, pauseButton, antiDeadZone, smoothing
    }

    /// Each field left out is its default; a number out of range is its default too.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GyroSettings()
        output = try c.decodeIfPresent(GyroOutput.self, forKey: .output) ?? d.output
        source = try c.decodeIfPresent(GyroSource.self, forKey: .source) ?? d.source
        sensitivity = Self.kept(try c.decodeIfPresent(Double.self, forKey: .sensitivity), in: Self.sensitivityRange, else: d.sensitivity)
        verticalRatio = Self.kept(try c.decodeIfPresent(Double.self, forKey: .verticalRatio), in: Self.verticalRatioRange,
                                  else: d.verticalRatio)
        turnAxis = try c.decodeIfPresent(GyroTurnAxis.self, forKey: .turnAxis) ?? d.turnAxis
        invertX = try c.decodeIfPresent(Bool.self, forKey: .invertX) ?? d.invertX
        invertY = try c.decodeIfPresent(Bool.self, forKey: .invertY) ?? d.invertY
        pauseButton = try c.decodeIfPresent(GyroPauseButton.self, forKey: .pauseButton) ?? d.pauseButton
        antiDeadZone = Self.kept(try c.decodeIfPresent(Double.self, forKey: .antiDeadZone), in: Self.antiDeadZoneRange,
                                 else: d.antiDeadZone)
        smoothing = try c.decodeIfPresent(GyroSmoothingChoice.self, forKey: .smoothing) ?? d.smoothing
    }

    /// What `defaults` holds (Settings › Controls › Gyro aim), each key missing (or not understood) read as its default.
    public init(_ defaults: UserDefaults) {
        let d = GyroSettings()
        output = defaults.string(forKey: Self.outputKey).flatMap(GyroOutput.init(rawValue:)) ?? d.output
        source = defaults.string(forKey: Self.sourceKey).flatMap(GyroSource.init(rawValue:)) ?? d.source
        sensitivity = Self.kept(Self.number(defaults, Self.sensitivityKey), in: Self.sensitivityRange, else: d.sensitivity)
        verticalRatio = Self.kept(Self.number(defaults, Self.verticalRatioKey), in: Self.verticalRatioRange, else: d.verticalRatio)
        turnAxis = defaults.string(forKey: Self.turnAxisKey).flatMap(GyroTurnAxis.init(rawValue:)) ?? d.turnAxis
        invertX = defaults.object(forKey: Self.invertXKey) as? Bool ?? d.invertX
        invertY = defaults.object(forKey: Self.invertYKey) as? Bool ?? d.invertY
        pauseButton = defaults.string(forKey: Self.pauseButtonKey).flatMap(GyroPauseButton.init(name:)) ?? d.pauseButton
        antiDeadZone = Self.kept(Self.number(defaults, Self.antiDeadZoneKey), in: Self.antiDeadZoneRange, else: d.antiDeadZone)
        smoothing = defaults.string(forKey: Self.smoothingKey).flatMap(GyroSmoothingChoice.init(rawValue:)) ?? d.smoothing
    }

    /// A number key: a number, or a String that reads as one (the driver's `set:gyro.sensitivity=1.5` stores "1.5").
    static func number(_ defaults: UserDefaults, _ key: String) -> Double? {
        switch defaults.object(forKey: key) {
        case let v as Double: v
        case let v as Int: Double(v)
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    static func kept(_ v: Double?, in range: ClosedRange<Double>, else d: Double) -> Double {
        guard let v, v.isFinite, range.contains(v) else { return d }
        return v
    }

    /// What HostIOKit GyroAim takes, reading `device`'s gyro (the smoothing is resolved for it).
    public func aimConfig(device: GyroDevice) -> GyroAim.Config {
        GyroAim.Config(output: output, turnAxis: turnAxis, sensitivity: sensitivity, verticalRatio: verticalRatio,
                       invertX: invertX, invertY: invertY, antiDeadZone: antiDeadZone,
                       smoothing: smoothing.smoothing(for: device))
    }

    /// One line for the logs: `output=mouse source=auto sensitivity=1.0 verticalRatio=1.0 turnAxis=playerSpace invert=-- pause=none
    /// smoothing=auto`, with ` antiDeadZone=0.27` after it for the right stick.
    public var summary: String {
        "output=\(output.rawValue) source=\(source.rawValue) sensitivity=\(sensitivity) verticalRatio=\(verticalRatio) "
            + "turnAxis=\(turnAxis.rawValue) invert=\(invertX ? "x" : "-")\(invertY ? "y" : "-") pause=\(pauseButton.name)"
            + " smoothing=\(smoothing.rawValue)"
            + (output == .rightStick ? " antiDeadZone=\(antiDeadZone)" : "")
    }

    /// Whether the pause button is held in a pad's values.
    public func paused(by pad: PadValues?) -> Bool {
        guard let c = pauseButton.control, let pad else { return false }
        return c.isHeld(in: pad)
    }
}

/// A game's own gyro aim settings, nil fields following the defaults. Saved as
/// JSON per catalogue id, as GameControls are.
public struct GameGyro: Codable, Equatable, Sendable {
    public var output: GyroOutput?
    public var source: GyroSource?
    public var sensitivity: Double?
    public var verticalRatio: Double?
    public var turnAxis: GyroTurnAxis?
    public var invertX: Bool?
    public var invertY: Bool?
    public var pauseButton: GyroPauseButton?
    public var antiDeadZone: Double?
    public var smoothing: GyroSmoothingChoice?

    public init(output: GyroOutput? = nil, source: GyroSource? = nil, sensitivity: Double? = nil, verticalRatio: Double? = nil,
                turnAxis: GyroTurnAxis? = nil, invertX: Bool? = nil, invertY: Bool? = nil, pauseButton: GyroPauseButton? = nil,
                antiDeadZone: Double? = nil, smoothing: GyroSmoothingChoice? = nil) {
        self.output = output; self.source = source; self.sensitivity = sensitivity; self.verticalRatio = verticalRatio
        self.turnAxis = turnAxis; self.invertX = invertX; self.invertY = invertY; self.pauseButton = pauseButton
        self.antiDeadZone = antiDeadZone; self.smoothing = smoothing
    }

    public var isEmpty: Bool { self == GameGyro() }

    /// The game's settings over the defaults; a number out of range follows the default.
    public func resolved(over d: GyroSettings) -> GyroSettings {
        GyroSettings(output: output ?? d.output, source: source ?? d.source,
                     sensitivity: GyroSettings.kept(sensitivity, in: GyroSettings.sensitivityRange, else: d.sensitivity),
                     verticalRatio: GyroSettings.kept(verticalRatio, in: GyroSettings.verticalRatioRange, else: d.verticalRatio),
                     turnAxis: turnAxis ?? d.turnAxis, invertX: invertX ?? d.invertX, invertY: invertY ?? d.invertY,
                     pauseButton: pauseButton ?? d.pauseButton,
                     antiDeadZone: GyroSettings.kept(antiDeadZone, in: GyroSettings.antiDeadZoneRange, else: d.antiDeadZone),
                     smoothing: smoothing ?? d.smoothing)
    }
}

/// The gyro a game's aim reads.
public enum GyroDevice: String, Sendable {
    case phone, controller
}

extension GyroSource {
    /// The gyro this choice reads, given which have one: Automatic takes the
    /// controller's when it reports rotation rate, else the iPhone's; iPhone and
    /// Controller take only their own (nil when it has none).
    public func device(phone: Bool, controller: Bool) -> GyroDevice? {
        switch self {
        case .auto: controller ? .controller : phone ? .phone : nil
        case .phone: phone ? .phone : nil
        case .controller: controller ? .controller : nil
        }
    }
}

/// What gyro aim's sensors depend on (S1Probe's GyroSensors gathers it on every change).
public struct GyroConditions: Equatable, Sendable {
    /// The running game's settings (its own over the defaults).
    public var settings: GyroSettings
    /// A game is running, has drawn its first frame and is not quitting.
    public var gameDrawing: Bool
    /// The app is active (focused) and in the foreground.
    public var appActive: Bool
    /// The in-game menu or a game's web page holds the game's input (HostIO.holdGuest).
    public var guestHeld: Bool
    /// A guest dialog is over the game (its pads are held too).
    public var dialog: Bool
    public var phoneHasGyro: Bool
    /// The current controller reports rotation rate.
    public var controllerHasGyro: Bool

    public init(settings: GyroSettings, gameDrawing: Bool, appActive: Bool, guestHeld: Bool = false, dialog: Bool = false,
                phoneHasGyro: Bool = true, controllerHasGyro: Bool = false) {
        self.settings = settings; self.gameDrawing = gameDrawing; self.appActive = appActive; self.guestHeld = guestHeld
        self.dialog = dialog; self.phoneHasGyro = phoneHasGyro; self.controllerHasGyro = controllerHasGyro
    }
}

/// What the Gyro aim page's test area needs to run the sensors for its dot
/// (S1Probe's GyroSensors gathers it while the page is up).
public struct GyroPreviewConditions: Equatable, Sendable {
    /// The page's settings: a game's own over the defaults, or the defaults.
    public var settings: GyroSettings
    /// A game is running (any step): the game's gyro, never the page's, then.
    public var gameRunning: Bool
    /// The app is active and in the foreground.
    public var appActive: Bool
    public var phoneHasGyro: Bool
    public var controllerHasGyro: Bool

    public init(settings: GyroSettings, gameRunning: Bool = false, appActive: Bool = true, phoneHasGyro: Bool = true,
                controllerHasGyro: Bool = false) {
        self.settings = settings; self.gameRunning = gameRunning; self.appActive = appActive
        self.phoneHasGyro = phoneHasGyro; self.controllerHasGyro = controllerHasGyro
    }
}

/// Whether gyro aim's sensors run, which, and for what: only while its output
/// is not Off and the game is in front and taking input (`running`: the output
/// goes to the guest). Anything else stops them; when they start again GyroAim
/// restarts its windows (no jump from before the stop). Outside a game, the
/// Gyro aim page's test area runs them for its dot (`previewing`: the output
/// goes to the dot, never to the guest).
public enum GyroRun: Equatable, Sendable {
    case stopped(String)
    case running(GyroDevice, GyroOutput)
    case previewing(GyroDevice, GyroOutput)

    public static func decide(_ c: GyroConditions) -> GyroRun {
        if c.settings.output == .off { return .stopped("output off") }
        if !c.gameDrawing { return .stopped("no game in front") }
        if !c.appActive { return .stopped("app not active") }
        if c.guestHeld { return .stopped("menu") }
        if c.dialog { return .stopped("dialog") }
        guard let d = c.settings.source.device(phone: c.phoneHasGyro, controller: c.controllerHasGyro) else {
            return .stopped(c.settings.source == .controller ? "no controller with a gyro" : "no gyro")
        }
        return .running(d, c.settings.output)
    }

    /// The game's run, else (no game running, `preview` given: the page is up)
    /// the test area's. A running game always wins, and its output alone reaches the guest.
    public static func decide(_ c: GyroConditions, preview: GyroPreviewConditions?) -> GyroRun {
        let game = decide(c)
        guard case .stopped = game, let p = preview, !p.gameRunning else { return game }
        if p.settings.output == .off { return .stopped("preview: output off") }
        if !p.appActive { return .stopped("preview: app not active") }
        guard let d = p.settings.source.device(phone: p.phoneHasGyro, controller: p.controllerHasGyro) else {
            return .stopped(p.settings.source == .controller ? "preview: no controller with a gyro" : "preview: no gyro")
        }
        return .previewing(d, p.settings.output)
    }

    public var device: GyroDevice? {
        switch self {
        case .running(let d, _), .previewing(let d, _): d
        case .stopped: nil
        }
    }

    /// The guest takes the output (a game's run, not the test area's).
    public var toGuest: Bool {
        if case .running = self { return true }
        return false
    }
}

/// When the "Gyro aim" chip shows over the controls (owner, 2026-10-13): briefly,
/// as gyro aim starts for the game: the game starts with it on, it is turned on
/// in the in-game menu (seen on Resume), or its source or output changes. A
/// Resume, or the app coming back, with nothing changed shows nothing; turning
/// it off forgets what was shown.
public struct GyroChipCue: Sendable {
    /// How long it stays, between its fades.
    public static let seconds = 2.5
    private var shown: GyroRun?

    public init() {}

    /// The game's run now (GyroRun.decide) and its output setting: true when the chip shows now.
    public mutating func update(_ run: GyroRun, output: GyroOutput) -> Bool {
        if output == .off { shown = nil; return false }
        guard case .running = run, run != shown else { return false }
        shown = run
        return true
    }
}
