// SPDX-License-Identifier: GPL-3.0-or-later
/// A scripted game controller: what the workstation plays into XInput slot 0
/// so a title can be driven with nobody at the phone (docs/DEVICE.md,
/// "Driving a title"). The app's HostIO reads the script from a file in
/// Documents and plays it from the moment the file changes.
///
/// One step per line, `<ms> [control ...]`: hold those controls for that many
/// milliseconds, then go to the next line. Controls are the XInput names
/// `A B X Y LB RB START BACK LS RS UP DOWN LEFT RIGHT`, and `HOME`, the
/// controller's Home button, which never reaches the guest: held for half a
/// second it opens Playport's in-game menu (InGameMenu.swift), and while the
/// menu is up the script's presses are the menu's. A trigger as `LT` or
/// `LT=0.5`, a stick axis as `LX=-1` (-1...1, +y up); `-` or nothing is the
/// pad at rest. A line `loop` repeats the whole script; without it the pad
/// rests after the last step. `#` starts a comment. Example: walk right for
/// two seconds, jump while walking, let go.
///
///     2000 RIGHT
///     300  RIGHT A
///     500  -
public struct PadScript: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public var ms: Int
        public var input: PadInput
        public init(ms: Int, input: PadInput) { self.ms = ms; self.input = input }
    }

    public var steps: [Step]
    public var loops: Bool
    public init(steps: [Step] = [], loops: Bool = false) { self.steps = steps; self.loops = loops }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var line: Int, message: String
        public var description: String { "line \(line): \(message)" }
    }

    public var totalMs: Int { steps.reduce(0) { $0 + $1.ms } }

    public static func parse(_ text: String) throws -> PadScript {
        var script = PadScript()
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let n = i + 1
            let words = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
            guard let first = words.first else { continue }
            if first.lowercased() == "loop" {
                guard words.count == 1 else { throw ParseError(line: n, message: "loop takes nothing") }
                script.loops = true
                continue
            }
            guard let ms = Int(first), ms >= 0 else { throw ParseError(line: n, message: "\(first): not a duration in ms") }
            var input = PadInput()
            for w in words.dropFirst() {
                if let err = apply(w, to: &input) { throw ParseError(line: n, message: err) }
            }
            script.steps.append(Step(ms: ms, input: input))
        }
        if script.loops && script.totalMs == 0 { throw ParseError(line: 0, message: "a loop needs a step longer than 0 ms") }
        return script
    }

    /// Nil when `word` was applied; the reason otherwise.
    static func apply(_ word: String, to p: inout PadInput) -> String? {
        let parts = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let name = parts[0].uppercased()
        var value: Float = 1
        if parts.count == 2 {
            guard let v = Float(parts[1]), v.isFinite else { return "\(word): bad value" }
            value = v
        }
        switch name {
        case "-": return parts.count == 1 ? nil : "\(word): - takes no value"
        case "LT", "RT":
            guard (0...1).contains(value) else { return "\(word): a trigger is 0...1" }
            if name == "LT" { p.leftTrigger = value } else { p.rightTrigger = value }
            return nil
        case "LX", "LY", "RX", "RY":
            guard parts.count == 2 else { return "\(word): an axis needs =value" }
            guard (-1...1).contains(value) else { return "\(word): an axis is -1...1" }
            switch name {
            case "LX": p.lx = value
            case "LY": p.ly = value
            case "RX": p.rx = value
            default: p.ry = value
            }
            return nil
        default:
            guard parts.count == 1 else { return "\(word): a button takes no value" }
            switch name {
            case "A": p.a = true
            case "B": p.b = true
            case "X": p.x = true
            case "Y": p.y = true
            case "LB": p.leftShoulder = true
            case "RB": p.rightShoulder = true
            case "START": p.menu = true
            case "BACK": p.options = true
            case "HOME": p.home = true
            case "LS": p.leftThumb = true
            case "RS": p.rightThumb = true
            case "UP": p.up = true
            case "DOWN": p.down = true
            case "LEFT": p.left = true
            case "RIGHT": p.right = true
            default: return "\(word): no such control"
            }
            return nil
        }
    }

    /// The step playing `ms` after the script started, and the pad then; the
    /// step is nil (and the pad at rest) once a script without loop is over.
    public func at(ms: Int) -> (step: Int?, input: PadInput) {
        let total = totalMs
        guard !steps.isEmpty, ms >= 0 else { return (nil, PadInput()) }
        var t = ms
        if loops { t %= total } else if t >= total { return (nil, PadInput()) }
        for (i, s) in steps.enumerated() {
            if t < s.ms { return (i, s.input) }
            t -= s.ms
        }
        return (nil, PadInput())
    }
}
