// SPDX-License-Identifier: GPL-3.0-or-later
// The ActionPicker's logic (ActionPicker.dc.html; UI/ActionPickerView.swift):
// what one input does, chosen by controller or touch. The Controller page
// (ControllerMapPage.swift) opens it for a controller input; phase 5's layout
// editor opens it for an on-screen control, with its own `accepts`.
//
// - Tabs: Keyboard, Mouse, Controller, Playport (LB and RB switch them). Only
//   the choices `accepts` takes are shown, and a tab with none is left out:
//   a whole stick gets Mouse look (`mouse:move`) and the pad's sticks only.
// - The cursor moves over the tab's rows, then the bottom row: the modifier
//   chips (Shift, Ctrl, Alt; Keyboard only) and the recent choices. Up and down
//   land on the cell under the one left, as the controller keyboard does.
// - A key is chosen with the modifiers that are on (`key:shift+0x31`); a
//   modifier key itself never carries its own modifier. A recent choice is
//   chosen as it was. Playport's "Nothing" unbinds the input.
// - Recent choices (ActionPickerRecent): the newest first, each once, at most
//   `limit`, kept under `controls.recentActions`.
// - "Press a real key" (RealKeyCapture): a hardware keyboard's key, as KeyMap
//   gives it, with the modifiers held; a modifier pressed and let go alone is
//   itself the key.

import Foundation
import HostIOKit

public enum ActionPickerTab: String, CaseIterable, Sendable {
    case keyboard, mouse, controller, playport

    public var title: String {
        switch self {
        case .keyboard: "Keyboard"
        case .mouse: "Mouse"
        case .controller: "Controller"
        case .playport: "Playport"
        }
    }
}

/// One cell of a tab: a choice, or (bottom row) a modifier chip or a recent choice.
public struct ActionPickerCell: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A choice; nil is Nothing (unbound). A key's modifiers come from the chips.
        case action(InputAction?)
        case modifier(KeyModifiers)
        /// A recent choice, chosen as it was saved.
        case recent(InputAction)
    }

    /// The driver's and the view's id: `key:0x20`, `mouse:left`, `nothing`, `mod:shift`, `recent:0`.
    public var id: String
    public var label: String
    public var kind: Kind
    /// Its width in key units (a letter key is 1).
    public var width: Double
}

public struct ActionPicker: Sendable {
    public typealias Accepts = @Sendable (InputAction) -> Bool

    /// What it is choosing for (the title: "What A presses").
    public let title: String
    /// The action bound now (nil: nothing).
    public let current: InputAction?
    private let accepts: Accepts
    public private(set) var tab: ActionPickerTab
    public private(set) var modifiers: KeyModifiers
    public private(set) var recent: [InputAction]
    /// The cursor: a row of `rows`, a cell in it.
    public private(set) var row = 0
    public private(set) var column = 0
    /// "Press a real key" is waiting for a hardware key.
    public private(set) var listening = false
    /// Where a vertical move aims, in key units from the left (kept across up and down).
    private var aim: Double?

    /// For a controller input: what its table takes (ControllerInput.accepts).
    public init(for input: ControllerInput, title: String, current: InputAction?, recent: [InputAction] = []) {
        self.init(title: title, current: current, recent: recent) { input.accepts($0) }
    }

    public init(title: String, current: InputAction?, recent: [InputAction] = [], accepts: @escaping Accepts) {
        self.title = title
        self.current = current
        self.accepts = accepts
        self.recent = recent
        if case .key(_, let m)? = current { modifiers = m } else { modifiers = [] }
        tab = .keyboard
        let shown = tabs
        tab = current.map(Self.tab(of:)).flatMap { shown.contains($0) ? $0 : nil } ?? shown.first ?? .playport
        // The cursor on the current choice when the tab shows it.
        let id = current.map(Self.cellID) ?? "nothing"
        for (r, cells) in rows.enumerated() {
            if let c = cells.firstIndex(where: { $0.id == id && !$0.isBottom }) { row = r; column = c; break }
        }
    }

    // MARK: what it shows

    /// The tabs with a choice `accepts` takes, in order.
    public var tabs: [ActionPickerTab] { ActionPickerTab.allCases.filter { !Self.choices(for: $0, accepts).isEmpty } }

    /// The current tab's rows, then the bottom row (modifiers on Keyboard, the recent choices) when it has any.
    public var rows: [[ActionPickerCell]] {
        var out = Self.choices(for: tab, accepts)
        var bottom: [ActionPickerCell] = []
        if tab == .keyboard {
            bottom += KeyModifiers.names.map { ActionPickerCell(id: "mod:" + $0.1, label: ActionText.modifier($0.0), kind: .modifier($0.0), width: 1.5) }
        }
        bottom += recentShown.enumerated().map { i, a in
            ActionPickerCell(id: "recent:\(i)", label: ActionText.name(a), kind: .recent(a), width: 1.5)
        }
        if !bottom.isEmpty { out.append(bottom) }
        return out
    }

    /// The recent choices this input takes.
    public var recentShown: [InputAction] { recent.filter(accepts) }

    /// The cell under the cursor.
    public var cell: ActionPickerCell? {
        let r = rows
        guard r.indices.contains(row), r[row].indices.contains(column) else { return nil }
        return r[row][column]
    }

    /// The action a cell chooses with the chips as they are; nil for a chip.
    public func action(of cell: ActionPickerCell) -> InputAction?? {
        switch cell.kind {
        case .modifier: nil
        case .recent(let a): .some(a)
        case .action(.key(let vk, _)?): .some(.key(vk, modifiers.subtracting(KeyModifiers(ownOf: vk))))
        case .action(let a): .some(a)
        }
    }

    // MARK: presses

    public enum Outcome: Equatable, Sendable {
        /// Nothing chosen yet (the cursor moved, a chip changed, the tab changed).
        case none
        /// This action is chosen (nil: Nothing).
        case chosen(InputAction?)
    }

    /// LB (-1) and RB (+1): the tab beside, stopping at the ends; the cursor to its first cell.
    public mutating func switchTab(by: Int) {
        let shown = tabs
        guard let i = shown.firstIndex(of: tab) else { return }
        let next = shown[max(0, min(shown.count - 1, i + by))]
        guard next != tab else { return }
        select(next)
    }

    /// A tab chosen directly (a tap).
    public mutating func select(_ t: ActionPickerTab) {
        guard tabs.contains(t) else { return }
        tab = t
        row = 0
        column = 0
        aim = nil
    }

    /// The D-pad: along a row, stopping at its ends; up and down to the cell under the one left.
    public mutating func move(_ d: FocusDirection) {
        let r = rows
        guard r.indices.contains(row) else { return }
        switch d {
        case .left, .right:
            column = max(0, min(r[row].count - 1, column + (d == .right ? 1 : -1)))
            aim = nil
        case .up, .down:
            let target = row + (d == .down ? 1 : -1)
            guard r.indices.contains(target) else { return }
            let x = aim ?? Self.centre(r[row], column)
            aim = x
            row = target
            column = Self.column(at: x, in: r[target])
        }
    }

    /// The cursor onto a cell directly (a tap), then A.
    public mutating func tap(row: Int, column: Int) -> Outcome {
        let r = rows
        guard r.indices.contains(row), r[row].indices.contains(column) else { return .none }
        self.row = row
        self.column = column
        aim = nil
        return choose()
    }

    /// A: the cell's choice, or a chip on or off.
    public mutating func choose() -> Outcome {
        guard let c = cell else { return .none }
        if case .modifier(let m) = c.kind {
            toggle(m)
            return .none
        }
        guard let a = action(of: c) else { return .none }
        return .chosen(a)
    }

    public mutating func toggle(_ m: KeyModifiers) {
        if modifiers.contains(m) { modifiers.remove(m) } else { modifiers.insert(m) }
    }

    /// X: wait for a hardware key (again: stop waiting). Only while keys are taken.
    public mutating func listen(_ on: Bool) { listening = on && accepts(.key(0x41, [])) }

    /// A hardware key while listening: chosen with the chips' and the held modifiers.
    public mutating func realKey(_ action: InputAction) -> Outcome {
        guard listening, case .key(let vk, let held) = action else { return .none }
        let a = InputAction.key(vk, held.union(modifiers).subtracting(KeyModifiers(ownOf: vk)))
        guard accepts(a) else { return .none }
        listening = false
        return .chosen(a)
    }

    // MARK: the tabs' choices

    /// The keyboard (ActionPicker.dc.html, with an F-key row and `- =` added), by VK and width.
    static let keyboard: [[(UInt8, String, Double)]] = [
        [(0x1B, "Esc", 1.2)] + (0..<12).map { (UInt8(0x70 + $0), "F\($0 + 1)", 1) },
        [(0xC0, "`", 1)] + Array("1234567890").map { (UInt8($0.asciiValue!), String($0), 1) }
            + [(0xBD, "-", 1), (0xBB, "=", 1), (0x08, "⌫", 1.4)],
        [(0x09, "Tab", 1.4)] + Array("QWERTYUIOP").map { (UInt8($0.asciiValue!), String($0), 1) }
            + [(0xDB, "[", 1), (0xDD, "]", 1), (0xDC, "\\", 1)],
        [(0x14, "Caps", 1.6)] + Array("ASDFGHJKL").map { (UInt8($0.asciiValue!), String($0), 1) }
            + [(0xBA, ";", 1), (0xDE, "'", 1), (0x0D, "Enter", 1.6)],
        [(0xA0, "Shift", 2)] + Array("ZXCVBNM").map { (UInt8($0.asciiValue!), String($0), 1) }
            + [(0xBC, ",", 1), (0xBE, ".", 1), (0xBF, "/", 1), (0xA1, "Shift", 1.6)],
        [(0xA2, "Ctrl", 1.3), (0xA4, "Alt", 1.2), (0x20, "Space", 6), (0xA5, "Alt", 1.2),
         (0x25, "←", 1), (0x26, "↑", 1), (0x28, "↓", 1), (0x27, "→", 1)],
    ]

    static func choices(for tab: ActionPickerTab, _ accepts: Accepts) -> [[ActionPickerCell]] {
        func cell(_ a: InputAction?, _ label: String, _ width: Double = 1) -> ActionPickerCell {
            ActionPickerCell(id: a.map(cellID) ?? "nothing", label: label, kind: .action(a), width: width)
        }
        let all: [[ActionPickerCell]] = switch tab {
        case .keyboard:
            keyboard.map { $0.map { cell(.key($0.0, []), $0.1, $0.2) } }
        case .mouse:
            [[MouseAction.left, .right, .middle].map { cell(.mouse($0), ActionText.mouse($0), 2) },
             [MouseAction.wheelUp, .wheelDown, .move].map { cell(.mouse($0), ActionText.mouse($0), 2) }]
        case .controller:
            [[PadControl.a, .b, .x, .y, .lb, .rb, .lt, .rt], [.back, .start, .ls, .rs, .up, .down, .left, .right],
             [.leftStick, .rightStick]].map { $0.map { cell(.pad($0), ActionText.pad($0), $0.isStick ? 3 : 1.5) } }
        case .playport:
            [[cell(.playport(.menu), ActionText.name(.playport(.menu)), 3), cell(nil, ActionText.name(nil), 3)]]
        }
        return all.map { $0.filter { c in
            guard case .action(let a) = c.kind else { return true }
            return a.map(accepts) ?? true
        } }.filter { !$0.isEmpty }
    }

    /// The tab a choice is on.
    static func tab(of a: InputAction) -> ActionPickerTab {
        switch a {
        case .key: .keyboard
        case .mouse: .mouse
        case .pad: .controller
        case .playport: .playport
        }
    }

    /// A choice's cell id: its saved name, without a key's modifiers.
    static func cellID(_ a: InputAction) -> String {
        if case .key(let vk, _) = a { return InputAction.key(vk, []).name }
        return a.name
    }

    private static func centre(_ cells: [ActionPickerCell], _ i: Int) -> Double {
        let total = cells.reduce(0) { $0 + $1.width }
        return (cells[..<i].reduce(0) { $0 + $1.width } + cells[i].width / 2) / total
    }

    /// The cell at `x`, a fraction of the row's width (rows are drawn the same width).
    private static func column(at x: Double, in cells: [ActionPickerCell]) -> Int {
        let total = cells.reduce(0) { $0 + $1.width }
        var left = 0.0
        for (i, c) in cells.enumerated() {
            if x * total < left + c.width { return i }
            left += c.width
        }
        return cells.count - 1
    }
}

extension ActionPickerCell {
    /// A cell of the bottom row (a chip or a recent choice).
    var isBottom: Bool {
        if case .action = kind { return false }
        return true
    }
}

extension KeyModifiers {
    /// The modifier a modifier key is itself (Shift for either Shift key), else none.
    public init(ownOf vk: UInt8) {
        switch vk {
        case 0x10, 0xA0, 0xA1: self = .shift
        case 0x11, 0xA2, 0xA3: self = .control
        case 0x12, 0xA4, 0xA5: self = .alt
        default: self = []
        }
    }
}

/// The recent choices, newest first.
public enum ActionPickerRecent {
    public static let defaultsKey = "controls.recentActions"
    public static let limit = 8

    /// `a` first, each once, at most `limit`.
    public static func adding(_ a: InputAction, to list: [InputAction]) -> [InputAction] {
        Array(([a] + list.filter { $0 != a }).prefix(limit))
    }

    public static func load(_ defaults: UserDefaults) -> [InputAction] {
        (defaults.stringArray(forKey: defaultsKey) ?? []).compactMap(InputAction.init(name:)).prefix(limit).map { $0 }
    }

    public static func save(_ list: [InputAction], _ defaults: UserDefaults) {
        defaults.set(list.map(\.name), forKey: defaultsKey)
    }
}

/// "Press a real key": a hardware keyboard's presses (VKs from KeyMap) to the key chosen.
public struct RealKeyCapture: Equatable, Sendable {
    /// A modifier key down with nothing else pressed since.
    private var lone: UInt8?

    public init() {}

    /// A key goes down with `held` modifiers: a key that is not a modifier is chosen now.
    public mutating func down(_ vk: UInt8, held: KeyModifiers) -> InputAction? {
        if !KeyModifiers(ownOf: vk).isEmpty {
            lone = vk
            return nil
        }
        lone = nil
        return .key(vk, held.subtracting(KeyModifiers(ownOf: vk)))
    }

    /// A key goes up: a modifier let go with nothing pressed while it was down is chosen itself.
    public mutating func up(_ vk: UInt8) -> InputAction? {
        defer { if lone == vk { lone = nil } }
        return lone == vk ? .key(vk, []) : nil
    }
}

/// The words an action is shown with (the Controller page's rows, the ActionPicker).
public enum ActionText {
    /// `Space`, `Shift+1`, `Left button`, `Mouse look`, `Pad A`, `Playport menu`; nil is `Nothing`.
    public static func name(_ a: InputAction?) -> String {
        switch a {
        case nil: "Nothing"
        case .key(let vk, let m)?: KeyModifiers.names.filter { m.contains($0.0) }.map { modifier($0.0) + "+" }.joined() + key(vk)
        case .mouse(let m)?: mouse(m)
        case .pad(let c)?: "Pad " + pad(c)
        case .playport(.menu)?: "Playport menu"
        }
    }

    public static func modifier(_ m: KeyModifiers) -> String {
        m == .shift ? "Shift" : m == .control ? "Ctrl" : m == .alt ? "Alt" : "?"
    }

    public static func mouse(_ m: MouseAction) -> String {
        switch m {
        case .left: "Left button"
        case .right: "Right button"
        case .middle: "Middle button"
        case .wheelUp: "Wheel up"
        case .wheelDown: "Wheel down"
        case .move: "Mouse look"
        }
    }

    /// A pad control as the Xbox pad names it: `A`, `LB`, `Menu`, `View`, `L3`, `D-pad up`, `Left stick`.
    public static func pad(_ c: PadControl) -> String {
        switch c {
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

    /// A Windows virtual key on a US keyboard: `A`, `1`, `F5`, `Space`, `Esc`, `←`, `;`; else `VK 0x5F`.
    public static func key(_ vk: UInt8) -> String {
        switch vk {
        case 0x30...0x39, 0x41...0x5A: return String(UnicodeScalar(vk))
        case 0x70...0x87: return "F\(Int(vk) - 0x6F)"
        case 0x60...0x69: return "Num \(Int(vk) - 0x60)"
        default: return keys[vk] ?? String(format: "VK 0x%02X", vk)
        }
    }

    static let keys: [UInt8: String] = [
        0x08: "Backspace", 0x09: "Tab", 0x0D: "Enter", 0x13: "Pause", 0x14: "Caps", 0x1B: "Esc", 0x20: "Space",
        0x21: "Page Up", 0x22: "Page Down", 0x23: "End", 0x24: "Home", 0x25: "←", 0x26: "↑", 0x27: "→", 0x28: "↓",
        0x2C: "Print Screen", 0x2D: "Insert", 0x2E: "Delete", 0x5B: "Win", 0x5C: "Right Win", 0x5D: "App",
        0x6A: "Num *", 0x6B: "Num +", 0x6D: "Num -", 0x6E: "Num .", 0x6F: "Num /", 0x90: "Num Lock", 0x91: "Scroll Lock",
        0x10: "Shift", 0x11: "Ctrl", 0x12: "Alt",
        0xA0: "Shift", 0xA1: "Right Shift", 0xA2: "Ctrl", 0xA3: "Right Ctrl", 0xA4: "Alt", 0xA5: "Right Alt",
        0xBA: ";", 0xBB: "=", 0xBC: ",", 0xBD: "-", 0xBE: ".", 0xBF: "/", 0xC0: "`", 0xDB: "[", 0xDC: "\\", 0xDD: "]",
        0xDE: "'", 0xE2: "\\ (ISO)",
    ]
}
