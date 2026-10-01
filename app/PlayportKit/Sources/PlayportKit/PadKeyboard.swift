// SPDX-License-Identifier: GPL-3.0-or-later
// The controller keyboard's logic (UI/Pad/PadKeyboardView.swift): its keys,
// where the D-pad moves between them, and the text it edits. The view draws
// `PadKeyboard.layout` and forwards presses and taps here, so the same
// sequence of presses types the same text on the phone and in these tests.
//
// Three layers share one shape (five rows, ten units wide), so the key the
// cursor is on stays put when Shift or ?123 switches layers: lower case,
// upper case (one letter, then back to lower case) and symbols. Every layer
// has the digits on top, and `-` (a backtick with Shift), space and `.` at the bottom.

import Foundation

public enum PadKey: Hashable, Sendable {
    case char(Character)
    case shift
    case symbols
    case backspace
    case space
    case done
}

public struct PadKeyboard: Equatable, Sendable {
    public enum Layer: Sendable { case lower, upper, symbols }

    /// One key and how wide it is, in units of a letter key.
    public struct Cell: Equatable, Sendable {
        public var key: PadKey
        public var width: Double
    }

    public private(set) var text: [Character]
    /// Where the next character goes, 0...text.count.
    public private(set) var caret: Int
    public private(set) var layer: Layer = .lower
    public private(set) var row: Int
    public private(set) var column: Int
    public var maxLength: Int
    /// Where a vertical move aims, in units from the left: kept across up and
    /// down so the cursor comes back to the key it left.
    private var aim: Double?

    /// The cursor starts on `q`, the caret after the text.
    public init(text: String = "", maxLength: Int = 256) {
        self.text = Array(text.prefix(maxLength))
        caret = self.text.count
        self.maxLength = maxLength
        row = 1
        column = 0
    }

    public var string: String { String(text) }
    public var key: PadKey { Self.layout(layer)[row][column].key }

    // MARK: layout

    private static let digits = Array("1234567890")
    private static let letters: [[Character]] = [Array("qwertyuiop"), Array("asdfghjkl'"), Array("zxcvbnm")]
    private static let signs: [[Character]] = [Array("!@#$%^&*()"), Array("<>=+[]{}\\|"), Array(";:\",/?_")]

    /// The rows of `layer`, top to bottom.
    public static func layout(_ layer: Layer) -> [[Cell]] {
        func chars(_ cs: [Character]) -> [Cell] { cs.map { Cell(key: .char($0), width: 1) } }
        // Shift turns ' into ~ and - into `, so every printable ASCII character
        // (a password's) is on some layer.
        let rows: [[Character]] = switch layer {
        case .lower: [digits] + letters
        case .upper: [digits] + letters.map { $0.map { $0 == "'" ? "~" : Character($0.uppercased()) } }
        case .symbols: [digits] + signs
        }
        return [
            chars(rows[0]),
            chars(rows[1]),
            chars(rows[2]),
            [Cell(key: .shift, width: 1.5)] + chars(rows[3]) + [Cell(key: .backspace, width: 1.5)],
            [Cell(key: .symbols, width: 1.5), Cell(key: .char(layer == .upper ? "`" : "-"), width: 1), Cell(key: .space, width: 4.5),
             Cell(key: .char("."), width: 1), Cell(key: .done, width: 2)],
        ]
    }

    // MARK: moving

    /// Moves the cursor. Sideways wraps around the row; up and down stop at
    /// the top and bottom rows and land on the key under the one left.
    public mutating func move(_ d: FocusDirection) {
        let rows = Self.layout(layer)
        switch d {
        case .left, .right:
            let n = rows[row].count
            column = (column + (d == .right ? 1 : n - 1)) % n
            aim = nil
        case .up, .down:
            let target = row + (d == .down ? 1 : -1)
            guard rows.indices.contains(target) else { return }
            let x = aim ?? Self.centre(rows[row], column)
            aim = x
            row = target
            column = Self.column(at: x, in: rows[target])
        }
    }

    /// The cursor onto a key directly (a tap).
    public mutating func focus(row: Int, column: Int) {
        let rows = Self.layout(layer)
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return }
        self.row = row
        self.column = column
        aim = nil
    }

    private static func centre(_ cells: [Cell], _ i: Int) -> Double {
        cells[..<i].reduce(0) { $0 + $1.width } + cells[i].width / 2
    }

    private static func column(at x: Double, in cells: [Cell]) -> Int {
        var left = 0.0
        for (i, c) in cells.enumerated() {
            if x < left + c.width { return i }
            left += c.width
        }
        return cells.count - 1
    }

    // MARK: editing

    public enum Outcome: Equatable, Sendable {
        /// The text or the layer changed, or nothing did.
        case edited
        /// Done: the player is finished with the text.
        case done
    }

    /// Presses the key under the cursor (A).
    @discardableResult
    public mutating func press() -> Outcome { press(key) }

    /// Presses `key`, wherever the cursor is.
    @discardableResult
    public mutating func press(_ key: PadKey) -> Outcome {
        switch key {
        case .char(let c): insert(c)
        case .space: insert(" ")
        case .backspace: backspace()
        case .shift: layer = layer == .lower ? .upper : .lower
        case .symbols: layer = layer == .symbols ? .lower : .symbols
        case .done: return .done
        }
        return .edited
    }

    public mutating func insert(_ c: Character) {
        guard text.count < maxLength else { return }
        text.insert(c, at: caret)
        caret += 1
        if layer == .upper { layer = .lower }
    }

    /// Deletes the character before the caret; false when there was none.
    @discardableResult
    public mutating func backspace() -> Bool {
        guard caret > 0 else { return false }
        caret -= 1
        text.remove(at: caret)
        return true
    }

    /// Moves the caret by `by` characters, within the text.
    public mutating func moveCaret(by: Int) {
        caret = min(max(caret + by, 0), text.count)
    }

    public mutating func clear() {
        text = []
        caret = 0
    }
}

/// A picker's index when the player steps it (left and right on a value, up
/// and down in a list): wrapping around, or stopping at the ends.
public enum PickerIndex {
    public static func step(_ index: Int, by: Int, count: Int, wrap: Bool) -> Int {
        guard count > 0 else { return 0 }
        let i = min(max(index, 0), count - 1)
        if wrap { return ((i + by) % count + count) % count }
        return min(max(i + by, 0), count - 1)
    }
}
