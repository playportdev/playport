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
// - Sensitivity (a multiplier of GyroAim's scale), vertical ratio, turn axis
//   (player space, yaw or roll), invert X and Y.
// - Pause button: none by default; a pad button that, held, stops the aim
//   (saved as `none` or an action name, `pad:lb`).
//
// Every field may be left out of saved JSON (its default); a value this
// build does not know is refused, as GameControls' are.

import Foundation
import HostIOKit

/// Where gyro aim reads rotation from.
public enum GyroSource: String, Codable, CaseIterable, Sendable {
    /// The connected controller's gyro when it has one, else the iPhone's.
    case auto
    case phone
    case controller
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

    /// The sensitivities and vertical ratios a value is kept to.
    public static let sensitivityRange = 0.05...20.0
    public static let verticalRatioRange = 0.0...4.0

    public var output = GyroOutput.off
    public var source = GyroSource.auto
    public var sensitivity = 1.0
    public var verticalRatio = 1.0
    public var turnAxis = GyroTurnAxis.playerSpace
    public var invertX = false
    public var invertY = false
    public var pauseButton = GyroPauseButton.none

    public init(output: GyroOutput = .off, source: GyroSource = .auto, sensitivity: Double = 1, verticalRatio: Double = 1,
                turnAxis: GyroTurnAxis = .playerSpace, invertX: Bool = false, invertY: Bool = false,
                pauseButton: GyroPauseButton = .none) {
        self.output = output; self.source = source; self.sensitivity = sensitivity; self.verticalRatio = verticalRatio
        self.turnAxis = turnAxis; self.invertX = invertX; self.invertY = invertY; self.pauseButton = pauseButton
    }

    enum CodingKeys: String, CodingKey { case output, source, sensitivity, verticalRatio, turnAxis, invertX, invertY, pauseButton }

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
    }

    /// What `defaults` holds (Settings › Controls › Gyro aim), each key missing (or not understood) read as its default.
    public init(_ defaults: UserDefaults) {
        let d = GyroSettings()
        output = defaults.string(forKey: Self.outputKey).flatMap(GyroOutput.init(rawValue:)) ?? d.output
        source = defaults.string(forKey: Self.sourceKey).flatMap(GyroSource.init(rawValue:)) ?? d.source
        sensitivity = Self.kept(defaults.object(forKey: Self.sensitivityKey) as? Double, in: Self.sensitivityRange, else: d.sensitivity)
        verticalRatio = Self.kept(defaults.object(forKey: Self.verticalRatioKey) as? Double, in: Self.verticalRatioRange,
                                  else: d.verticalRatio)
        turnAxis = defaults.string(forKey: Self.turnAxisKey).flatMap(GyroTurnAxis.init(rawValue:)) ?? d.turnAxis
        invertX = defaults.object(forKey: Self.invertXKey) as? Bool ?? d.invertX
        invertY = defaults.object(forKey: Self.invertYKey) as? Bool ?? d.invertY
        pauseButton = defaults.string(forKey: Self.pauseButtonKey).flatMap(GyroPauseButton.init(name:)) ?? d.pauseButton
    }

    static func kept(_ v: Double?, in range: ClosedRange<Double>, else d: Double) -> Double {
        guard let v, v.isFinite, range.contains(v) else { return d }
        return v
    }

    /// What HostIOKit GyroAim takes.
    public var aimConfig: GyroAim.Config {
        GyroAim.Config(output: output, turnAxis: turnAxis, sensitivity: sensitivity, verticalRatio: verticalRatio,
                       invertX: invertX, invertY: invertY)
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

    public init(output: GyroOutput? = nil, source: GyroSource? = nil, sensitivity: Double? = nil, verticalRatio: Double? = nil,
                turnAxis: GyroTurnAxis? = nil, invertX: Bool? = nil, invertY: Bool? = nil, pauseButton: GyroPauseButton? = nil) {
        self.output = output; self.source = source; self.sensitivity = sensitivity; self.verticalRatio = verticalRatio
        self.turnAxis = turnAxis; self.invertX = invertX; self.invertY = invertY; self.pauseButton = pauseButton
    }

    public var isEmpty: Bool { self == GameGyro() }

    /// The game's settings over the defaults; a number out of range follows the default.
    public func resolved(over d: GyroSettings) -> GyroSettings {
        GyroSettings(output: output ?? d.output, source: source ?? d.source,
                     sensitivity: GyroSettings.kept(sensitivity, in: GyroSettings.sensitivityRange, else: d.sensitivity),
                     verticalRatio: GyroSettings.kept(verticalRatio, in: GyroSettings.verticalRatioRange, else: d.verticalRatio),
                     turnAxis: turnAxis ?? d.turnAxis, invertX: invertX ?? d.invertX, invertY: invertY ?? d.invertY,
                     pauseButton: pauseButton ?? d.pauseButton)
    }
}
