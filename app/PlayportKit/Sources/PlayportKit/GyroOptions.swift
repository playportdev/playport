// SPDX-License-Identifier: GPL-3.0-or-later
// Gyro aim's rows (GyroAim.dc.html, QuickMenuControls.dc.html): what each row
// of Game options › Controls › Gyro aim, Settings › Controls › Gyro aim and the
// in-game menu's Controls panel shows and stores, kept here so the three agree.
//
// - A row's choices have string ids: an enum's raw value, a pause button's
//   name (`none`, `pad:lb`), a number as Swift prints it (`1.5`), `true` or
//   `false`. A game's row stores its choice in the game's GameGyro; Settings'
//   writes the `gyro.*` key (`stored(_:)` gives the value to write).
// - A game's row is "changed for this game" (the amber dot) while its GameGyro
//   sets that field; Y clears it (`cleared`), so the row follows the default.
// - Numbers (sensitivity, anti-dead-zone, vertical ratio) step along fixed
//   choices; a value between them (from `controls:` or `set:`) shows as itself
//   and steps from the nearest.
// - The anti-dead-zone row shows only while the output is Right stick (`isShown`).

import Foundation
import HostIOKit

/// A row of the Gyro aim page, in the page's order.
public enum GyroRow: String, CaseIterable, Sendable {
    case output, source, pauseButton, sensitivity, antiDeadZone, verticalRatio, turnAxis, invertX, invertY

    public var title: String {
        switch self {
        case .output: "Gyro aim"
        case .source: "Gyro from"
        case .pauseButton: "Pause button"
        case .sensitivity: "Sensitivity"
        case .antiDeadZone: "Anti-dead zone"
        case .verticalRatio: "Up and down"
        case .turnAxis: "Turn with"
        case .invertX: "Invert left and right"
        case .invertY: "Invert up and down"
        }
    }

    /// Its Settings default's UserDefaults key (GyroSettings).
    public var key: String {
        switch self {
        case .output: GyroSettings.outputKey
        case .source: GyroSettings.sourceKey
        case .pauseButton: GyroSettings.pauseButtonKey
        case .sensitivity: GyroSettings.sensitivityKey
        case .antiDeadZone: GyroSettings.antiDeadZoneKey
        case .verticalRatio: GyroSettings.verticalRatioKey
        case .turnAxis: GyroSettings.turnAxisKey
        case .invertX: GyroSettings.invertXKey
        case .invertY: GyroSettings.invertYKey
        }
    }

    /// A switch (on or off) rather than a list of choices.
    public var isSwitch: Bool { self == .invertX || self == .invertY }

    /// A number row: left and right step it.
    public var isNumber: Bool { self == .sensitivity || self == .antiDeadZone || self == .verticalRatio }

    /// Whether the row shows for `s`: the anti-dead-zone only for the right stick.
    public func isShown(in s: GyroSettings) -> Bool { self != .antiDeadZone || s.output == .rightStick }

    /// The choices, left to right: (id, label).
    public var choices: [(id: String, label: String)] {
        switch self {
        case .output: GyroOutput.allCases.map { ($0.rawValue, GyroText.output($0)) }
        case .source: GyroSource.allCases.map { ($0.rawValue, GyroText.source($0)) }
        case .pauseButton: GyroSteps.pauseButtons.map { ($0.name, GyroText.pauseButton($0)) }
        case .sensitivity: GyroSteps.sensitivity.map { (String($0), GyroText.sensitivity($0)) }
        case .antiDeadZone: GyroSteps.antiDeadZone.map { (String($0), GyroText.antiDeadZone($0)) }
        case .verticalRatio: GyroSteps.verticalRatio.map { (String($0), GyroText.verticalRatio($0)) }
        case .turnAxis: GyroTurnAxis.allCases.map { ($0.rawValue, GyroText.turnAxis($0)) }
        case .invertX, .invertY: [("false", "Off"), ("true", "On")]
        }
    }

    /// The current choice's id in `s`.
    public func id(in s: GyroSettings) -> String {
        switch self {
        case .output: s.output.rawValue
        case .source: s.source.rawValue
        case .pauseButton: s.pauseButton.name
        case .sensitivity: String(s.sensitivity)
        case .antiDeadZone: String(s.antiDeadZone)
        case .verticalRatio: String(s.verticalRatio)
        case .turnAxis: s.turnAxis.rawValue
        case .invertX: String(s.invertX)
        case .invertY: String(s.invertY)
        }
    }

    /// The index among `choices` of the value in `s`; a number between the steps is at its nearest.
    public func index(in s: GyroSettings) -> Int {
        switch self {
        case .sensitivity: GyroSteps.nearest(s.sensitivity, in: GyroSteps.sensitivity)
        case .antiDeadZone: GyroSteps.nearest(s.antiDeadZone, in: GyroSteps.antiDeadZone)
        case .verticalRatio: GyroSteps.nearest(s.verticalRatio, in: GyroSteps.verticalRatio)
        default: choices.firstIndex { $0.id == id(in: s) } ?? 0
        }
    }

    /// What the row shows for `s`.
    public func text(_ s: GyroSettings) -> String {
        switch self {
        case .output: GyroText.output(s.output)
        case .source: GyroText.source(s.source)
        case .pauseButton: GyroText.pauseButton(s.pauseButton)
        case .sensitivity: GyroText.sensitivity(s.sensitivity)
        case .antiDeadZone: GyroText.antiDeadZone(s.antiDeadZone)
        case .verticalRatio: GyroText.verticalRatio(s.verticalRatio)
        case .turnAxis: GyroText.turnAxis(s.turnAxis)
        case .invertX: s.invertX ? "On" : "Off"
        case .invertY: s.invertY ? "On" : "Off"
        }
    }

    /// The choice `by` steps from the value in `s` (stopping at the ends, or going round with `wrapping`).
    public func step(_ s: GyroSettings, by: Int, wrapping: Bool = false) -> String {
        let all = choices
        let i = index(in: s) + by
        return all[wrapping ? (i % all.count + all.count) % all.count : max(0, min(all.count - 1, i))].id
    }

    /// Whether the game's own settings set this row (the amber dot).
    public func isSet(in g: GameGyro?) -> Bool {
        guard let g else { return false }
        return switch self {
        case .output: g.output != nil
        case .source: g.source != nil
        case .pauseButton: g.pauseButton != nil
        case .sensitivity: g.sensitivity != nil
        case .antiDeadZone: g.antiDeadZone != nil
        case .verticalRatio: g.verticalRatio != nil
        case .turnAxis: g.turnAxis != nil
        case .invertX: g.invertX != nil
        case .invertY: g.invertY != nil
        }
    }

    /// The game's settings with this row set to the choice `id` (nil: back to the default); nil when nothing is left set.
    public func setting(_ id: String?, in g: GameGyro?) -> GameGyro? {
        var g = g ?? GameGyro()
        switch self {
        case .output: g.output = id.flatMap(GyroOutput.init(rawValue:))
        case .source: g.source = id.flatMap(GyroSource.init(rawValue:))
        case .pauseButton: g.pauseButton = id.flatMap(GyroPauseButton.init(name:))
        case .sensitivity: g.sensitivity = id.flatMap(Double.init)
        case .antiDeadZone: g.antiDeadZone = id.flatMap(Double.init)
        case .verticalRatio: g.verticalRatio = id.flatMap(Double.init)
        case .turnAxis: g.turnAxis = id.flatMap(GyroTurnAxis.init(rawValue:))
        case .invertX: g.invertX = id.flatMap(Bool.init)
        case .invertY: g.invertY = id.flatMap(Bool.init)
        }
        return g.isEmpty ? nil : g
    }

    /// Y on a game's row: the row follows the default again.
    public func cleared(_ g: GameGyro?) -> GameGyro? { setting(nil, in: g) }

    /// The value to write to `key` for the choice `id` (Settings' default): a Double, a Bool or a String.
    public func stored(_ id: String) -> Any {
        switch self {
        case .sensitivity: Double(id) ?? GyroSettings.defaultSensitivity
        case .verticalRatio: Double(id) ?? 1
        case .antiDeadZone: Double(id) ?? GyroSettings.defaultAntiDeadZone
        case .invertX, .invertY: id == "true"
        default: id
        }
    }
}

/// The choices the number and pause rows step along.
public enum GyroSteps {
    public static let sensitivity: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]
    /// None, then around a game's own dead zone (XInput's is 0.27).
    public static let antiDeadZone: [Double] = [0, 0.1, 0.15, 0.2, 0.24, 0.27, 0.3, 0.35, 0.4, 0.5]
    public static let verticalRatio: [Double] = [0, 0.25, 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.25, 1.5, 2]
    /// None, then the buttons a hand rests on first.
    public static let pauseButtons: [GyroPauseButton] = [.none] + [PadControl.lb, .rb, .lt, .rt, .ls, .rs, .a, .b, .x, .y,
                                                                    .back, .start, .up, .down, .left, .right].map { .pad($0) }

    /// The index of the step nearest to `v`.
    public static func nearest(_ v: Double, in steps: [Double]) -> Int {
        steps.indices.min { abs(steps[$0] - v) < abs(steps[$1] - v) } ?? 0
    }
}

/// The words the gyro rows use.
public enum GyroText {
    public static func output(_ o: GyroOutput) -> String {
        switch o {
        case .off: "Off"
        case .mouse: "Mouse"
        case .rightStick: "Right stick"
        }
    }

    public static func source(_ s: GyroSource) -> String {
        switch s {
        case .auto: "Auto"
        case .phone: "iPhone"
        case .controller: "Controller"
        }
    }

    public static func device(_ d: GyroDevice) -> String {
        switch d {
        case .phone: "iPhone"
        case .controller: "Controller"
        }
    }

    public static func turnAxis(_ t: GyroTurnAxis) -> String {
        switch t {
        case .playerSpace: "Player space"
        case .yaw: "Yaw"
        case .roll: "Roll"
        }
    }

    public static func pauseButton(_ b: GyroPauseButton) -> String {
        guard let c = b.control else { return "None" }
        return switch c {
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .lb: "LB"
        case .rb: "RB"
        case .lt: "LT"
        case .rt: "RT"
        case .start: "Menu"
        case .back: "View"
        case .ls: "L3"
        case .rs: "R3"
        case .up: "D-pad up"
        case .down: "D-pad down"
        case .left: "D-pad left"
        case .right: "D-pad right"
        case .leftStick: "Left stick"
        case .rightStick: "Right stick"
        }
    }

    /// `2.0×`; two places when one would round it (`0.25×`).
    public static func sensitivity(_ v: Double) -> String {
        let one = String(format: "%.1f", v)
        return (abs(Double(one)! - v) < 0.001 ? one : String(format: "%.2f", v)) + "×"
    }

    /// `27%`, `None` for 0.
    public static func antiDeadZone(_ v: Double) -> String {
        v <= 0 ? "None" : String(format: "%.0f%%", v * 100)
    }

    /// `0.8× of across`.
    public static func verticalRatio(_ v: Double) -> String { sensitivity(v) + " of across" }

    /// The in-game menu's and Game options' short value: `Mouse · 2.0×`, `Off`.
    public static func summary(_ s: GyroSettings) -> String {
        s.output == .off ? "Off" : "\(output(s.output)) · \(sensitivity(s.sensitivity))"
    }

    /// The source row's value and, when no gyro can be read, why: `Auto · iPhone`,
    /// `Controller · none` ("No controller with a gyro is connected"). `device` is the gyro the choice reads now.
    public static func sourceInUse(_ s: GyroSource, device: GyroDevice?) -> (value: String, why: String?) {
        switch (s, device) {
        case (.auto, let d?): ("Auto · " + self.device(d), nil)
        case (_, _?): (source(s), nil)
        case (.controller, nil): ("Controller · none", "No controller with a gyro is connected")
        case (.phone, nil): ("iPhone · none", "This iPhone reports no gyro")
        case (.auto, nil): ("Auto · none", "No gyro on this iPhone or a connected controller")
        }
    }
}
