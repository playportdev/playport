// SPDX-License-Identifier: GPL-3.0-or-later
// The layout editor's model (PLA-13, phase 5;
// LayoutEditor.dc.html): it edits a ControlLayout over the paused game, and its
// result is the game's own copy of a preset (GameControls.layouts). The view
// (S1Probe) draws `layout` at the view's size and passes gestures and taps in.
//
// - It edits one preset's layout (`preset`, never Off): the game's copy when it
//   has one, else the preset. `start(from:)` switches to another preset (its
//   copy, else the preset); `reset()` puts the bare preset back.
// - Add (`add`, `addable`), move (`drag`), resize (`pinch`, `resize(by:)`),
//   `duplicate` and `remove`. The look area and the pointer surface fill the
//   safe area under everything: they are added and removed, never moved or
//   resized, and a layout has at most one of them.
// - A drag snaps a control's left, centre or right (top, middle or bottom) to
//   another control's or to the safe area's within `snapDistance`, and shows a
//   guide there (`guides`, while the gesture lasts); an axis with nothing that
//   close snaps the control's top-left corner to the 8 pt grid (`grid`), from
//   the safe area's top-left. A pinch snaps the size to the grid. Either keeps
//   the control in the safe area. A moved control is anchored again to the
//   ninth of the safe area its centre is in, so it keeps its place on other
//   iPhones; a floating stick's zone moves with it.
// - Per control (`details`): what it presses (`picker`, then `setAction` with
//   the ActionPicker's choice: a button, a stick's or d-pad's four
//   directions, or a stick's whole-pad stick), its label, its size and a
//   button's behaviour (hold, toggle, repeat). A button whose label was its
//   action's name follows a new action's name.
// - Undo and redo: each operation, and each whole gesture, is one step; an
//   operation during a gesture ends the gesture first.
// - `saved(into:)` is what Done stores. Nothing changed since it opened
//   (`changed`: the same preset and layout, an edit undone too): the game as
//   it was, so Done neither picks a layout for a game following Off, Settings
//   or the suggestion nor ends that suggestion. Else the game's layout becomes
//   the preset, with this copy when it differs from the preset (none when it
//   does not, so Reset then Done drops the copy).

import Foundation
import HostIOKit

/// A line the view draws while a drag snaps to it, across the whole view.
public enum SnapGuide: Equatable, Sendable {
    case vertical(x: Double)
    case horizontal(y: Double)
}

/// What the editor's Add offers.
public enum NewControl: String, CaseIterable, Sendable {
    case button, stick, keyStick, dpad, keyboard, lookArea, pointer, rightClick, hover, scroll, trackpad

    public var title: String {
        switch self {
        case .button: "Button"
        case .stick: "Stick"
        case .keyStick: "W A S D"
        case .dpad: "D-pad"
        case .keyboard: "Touch keyboard"
        case .lookArea: "Look area"
        case .pointer: "Pointer"
        case .rightClick: "Right click"
        case .hover: "Hover"
        case .scroll: "Scroll"
        case .trackpad: "Trackpad"
        }
    }

    var tool: PointerTool? {
        switch self {
        case .rightClick: .rightClick
        case .hover: .hover
        case .scroll: .scroll
        case .trackpad: .trackpad
        default: nil
        }
    }
}

/// The inspector's view of the selected control (LayoutEditor.dc.html).
public struct ControlDetails: Equatable, Sendable {
    public var id: String
    public var label: String
    /// `Button · right side`.
    public var subtitle: String
    /// The rows of what it presses: `Presses`, or `Up`, `Down`, `Left`, `Right`; none for a surface or a tool.
    public var slots: [String]
    /// What each slot presses now (ActionText.name).
    public var actions: [String]
    /// `56 pt`, or `52 × 30 pt`.
    public var size: String
    /// A button: Hold, Toggle, Repeat.
    public var behaviour: TouchBehaviour?
    /// Not a surface: it can be moved and resized.
    public var movable: Bool
    /// Not one of what a layout has once (a surface, a pad stick, a pointer tool): it can be duplicated.
    public var duplicable: Bool
}

public struct LayoutEditor: Equatable, Sendable {
    /// The grid, in points.
    public static let grid = 8.0
    /// How close (points) a line must come to another to snap to it.
    public static let snapDistance = 6.0
    /// The smallest side a resize leaves.
    public static let minimumSide = 24.0
    /// Where a duplicate goes from the original, each way.
    public static let duplicateOffset = 16.0
    /// Undo steps kept.
    public static let undoLimit = 100

    /// The preset this layout is the game's copy of (never Off).
    public private(set) var preset: OnScreenLayout
    public private(set) var layout: ControlLayout
    public private(set) var selection: String?
    /// The guides of the drag going on now.
    public private(set) var guides: [SnapGuide] = []
    public private(set) var width: Double, height: Double, insets: ControlInsets

    /// The Gamepad preset's options (its d-pad and right stick).
    let dpad: OnScreenDpad, rightStick: OnScreenRightStick
    /// The game's copies when the editor opened, for `start(from:)`.
    var copies: [OnScreenLayout: ControlLayout]

    struct Snapshot: Equatable, Sendable {
        var preset: OnScreenLayout
        var layout: ControlLayout
    }
    var undoStack: [Snapshot] = []
    var redoStack: [Snapshot] = []

    struct Gesture: Equatable, Sendable {
        var id: String
        var before: Snapshot
        var frame: TouchRect
        var zone: TouchRect?
    }
    var gesture: Gesture?
    /// What it opened on, for `changed`.
    let opened: Snapshot

    /// Edits `preset` (Off edits Gamepad): the game's copy of it from `copies`, else the preset.
    public init(preset: OnScreenLayout, copies: [OnScreenLayout: ControlLayout] = [:], dpad: OnScreenDpad = .off,
                rightStick: OnScreenRightStick = .off, width: Double, height: Double, insets: ControlInsets = .zero) {
        let p = preset == .off ? OnScreenLayout.gamepad : preset
        self.preset = p
        self.copies = copies
        self.dpad = dpad; self.rightStick = rightStick
        self.width = width; self.height = height; self.insets = insets
        layout = copies[p] ?? p.layout(dpad: dpad, rightStick: rightStick) ?? .gamepad(dpad: dpad, rightStick: rightStick)
        opened = Snapshot(preset: p, layout: layout)
    }

    /// Edits what a game plays with: its layout (Off: Gamepad) and its copies, with its Gamepad options.
    public init(game: GameControls?, state: ControlsState, width: Double, height: Double, insets: ControlInsets = .zero) {
        self.init(preset: state.layout, copies: game?.layouts ?? [:], dpad: state.dpad, rightStick: state.rightStick,
                  width: width, height: height, insets: insets)
    }

    // MARK: what it shows

    var area: TouchRect { insets.area(width: width, height: height) }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// The layout is not the bare preset.
    public var isEdited: Bool { layout != presetLayout(preset) }

    /// Another preset or layout than it opened on (a gesture going on not counted until it ends).
    public var changed: Bool { snapshot != opened }

    /// Where a control is in the view.
    public func frame(of id: String) -> TouchRect? {
        layout.control(id)?.frame(width: width, height: height, insets: insets)
    }

    /// A floating stick's zone in the view.
    public func zone(of id: String) -> TouchRect? {
        layout.control(id)?.floatingZone?.frame(in: area)
    }

    /// The control a tap at x, y picks: the topmost (last) one there, a surface only where nothing else is.
    public func control(atX x: Double, y: Double) -> String? {
        let hit = layout.controls.reversed().filter { c in
            let f = c.frame(width: width, height: height, insets: insets)
            return x >= f.x && x < f.x + f.width && y >= f.y && y < f.y + f.height
        }
        return (hit.first { !$0.isSurface } ?? hit.first)?.id
    }

    /// What Add offers now: a layout has one surface at most, the pointer's tools only with a
    /// pointer and each once, and a pad stick only while one of the two is not there.
    public var addable: [NewControl] {
        let surface = layout.controls.contains(where: \.isSurface)
        let pointer = layout.controls.contains { $0.kind == .pointer }
        let tools = Set(layout.controls.compactMap(\.tool))
        return NewControl.allCases.filter { n in
            switch n {
            case .lookArea, .pointer: !surface
            case .rightClick, .hover, .scroll, .trackpad: pointer && !tools.contains(n.tool!)
            case .stick: newStick() != nil
            default: true
            }
        }
    }

    public func details(_ id: String) -> ControlDetails? {
        guard let c = layout.control(id) else { return nil }
        let slots: [String] = switch c.kind {
        case .button: ["Presses"]
        case .stick where c.actions.count == 1: ["Presses"]
        case .stick, .dpad: ["Up", "Down", "Left", "Right"]
        case .lookArea, .pointer, .tool: []
        }
        let f = frame(of: id) ?? TouchRect(x: 0, y: 0, width: 0, height: 0)
        func pt(_ v: Double) -> String { String(Int(v.rounded())) }
        return ControlDetails(id: id, label: c.label, subtitle: c.kind.title + " · " + c.anchor.side,
                              slots: slots, actions: slots.indices.map { ActionText.name(c.actions[$0]) },
                              size: f.width == f.height ? "\(pt(f.width)) pt" : "\(pt(f.width)) × \(pt(f.height)) pt",
                              behaviour: c.kind == .button ? c.behaviour : nil, movable: !c.isSurface,
                              duplicable: !c.isOnePerLayout)
    }

    /// The ActionPicker for a slot of `details(id).slots`, with what that slot takes.
    public func picker(_ id: String, slot: Int, recent: [InputAction] = []) -> ActionPicker? {
        guard let c = layout.control(id), let accepts = Self.accepts(c, slot: slot) else { return nil }
        let slots = details(id)?.slots ?? []
        let title = slots.count == 1 ? "What \(c.label) presses" : "What \(c.label) \(slots[slot].lowercased()) presses"
        return ActionPicker(title: title, current: c.actions[slot], recent: recent, accepts: accepts)
    }

    static func accepts(_ c: Control, slot: Int) -> ActionPicker.Accepts? {
        let stickAction: @Sendable (InputAction) -> Bool = { a in
            switch a {
            case .pad(let p): p.isStick
            case .mouse(.move): true
            default: false
            }
        }
        switch c.kind {
        case .button where slot == 0:
            return { !stickAction($0) }
        case .stick where c.actions.count == 1 && slot == 0:
            return { if case .pad(let p) = $0 { p.isStick } else { false } }
        case .stick, .dpad:
            guard c.actions.count == 4, (0..<4).contains(slot) else { return nil }
            return { !stickAction($0) }
        default:
            return nil
        }
    }

    // MARK: editing

    public mutating func select(_ id: String?) {
        selection = id.flatMap { layout.control($0) == nil ? nil : $0 }
    }

    /// The view's size changed (a rotation): the controls stay where their anchors put them.
    public mutating func setView(width: Double, height: Double, insets: ControlInsets = .zero) {
        endGesture()
        self.width = width; self.height = height; self.insets = insets
    }

    /// A drag on a control, `dx`, `dy` points since it began: moved, snapped and kept in the
    /// safe area, its guides shown. `endGesture()` ends it as one undo step.
    public mutating func drag(_ id: String, dx: Double, dy: Double) {
        guard let g = begin(id), let i = index(id) else { return }
        var f = g.frame
        f.x += dx; f.y += dy
        let others = layout.controls.filter { $0.id != id && !$0.isSurface }.map { $0.frame(width: width, height: height, insets: insets) }
        let a = area
        let (sx, gx) = Self.snap([f.x, f.x + f.width / 2, f.x + f.width],
                                 to: [a.x, a.x + a.width / 2, a.x + a.width] + others.flatMap { [$0.x, $0.x + $0.width / 2, $0.x + $0.width] },
                                 grid: a.x)
        let (sy, gy) = Self.snap([f.y, f.y + f.height / 2, f.y + f.height],
                                 to: [a.y, a.y + a.height / 2, a.y + a.height] + others.flatMap { [$0.y, $0.y + $0.height / 2, $0.y + $0.height] },
                                 grid: a.y)
        f.x += sx; f.y += sy
        f = f.kept(in: a)
        guides = []
        if let x = gx, [f.x, f.x + f.width / 2, f.x + f.width].contains(where: { abs($0 - x) < 0.001 }) { guides.append(.vertical(x: x)) }
        if let y = gy, [f.y, f.y + f.height / 2, f.y + f.height].contains(where: { abs($0 - y) < 0.001 }) { guides.append(.horizontal(y: y)) }
        var c = g.before.layout.controls.first { $0.id == id }!
        c.place(at: f, in: a)
        if let z = g.zone, c.floatingZone != nil {
            var moved = z
            moved.x += f.x - g.frame.x; moved.y += f.y - g.frame.y
            c.placeZone(at: moved.kept(in: a), in: a)
        }
        layout.controls[i] = c
    }

    /// A pinch on a control, `scale` times its size when it began, about its centre: the
    /// size snapped to the grid, at least `minimumSide`, at most the safe area.
    public mutating func pinch(_ id: String, scale: Double) {
        guard let g = begin(id), let i = index(id) else { return }
        let a = area
        func side(_ v: Double, _ most: Double) -> Double {
            min(max(Self.minimumSide, (v * scale / Self.grid).rounded() * Self.grid), most)
        }
        let w = side(g.frame.width, a.width), h = side(g.frame.height, a.height)
        let f = TouchRect(x: g.frame.x + (g.frame.width - w) / 2, y: g.frame.y + (g.frame.height - h) / 2, width: w, height: h)
        var c = g.before.layout.controls.first { $0.id == id }!
        c.place(at: f.kept(in: a), in: a, anchor: c.anchor)
        layout.controls[i] = c
    }

    /// The drag or pinch is over: one undo step, the guides gone.
    public mutating func endGesture() {
        guides = []
        guard let g = gesture else { return }
        gesture = nil
        record(g.before)
    }

    /// The inspector's size: `steps` grid steps more (fewer) each way, about the centre.
    public mutating func resize(_ id: String, by steps: Int) {
        guard let c = layout.control(id), !c.isSurface, let f = frame(of: id) else { return }
        let a = area
        let d = Double(steps) * Self.grid
        let w = min(max(Self.minimumSide, f.width + d), a.width), h = min(max(Self.minimumSide, f.height + d), a.height)
        let r = TouchRect(x: f.x + (f.width - w) / 2, y: f.y + (f.height - h) / 2, width: w, height: h).kept(in: a)
        edit(id) { $0.place(at: r, in: a, anchor: $0.anchor) }
    }

    /// Adds a control at the safe area's middle (a surface under everything) and selects it.
    @discardableResult
    public mutating func add(_ n: NewControl) -> String? {
        guard addable.contains(n) else { return nil }
        let gamepad = preset == .gamepad
        func key(_ vk: UInt8) -> InputAction { .key(vk, []) }
        var c: Control
        switch n {
        case .button:
            let a: InputAction = gamepad ? .pad(.a) : key(0x20)
            c = Control(id: "button", actions: [a], label: Self.label(a), anchor: .center, x: 0, y: 0, width: 56, height: 56)
        case .stick:
            let s = newStick()!
            c = Control(id: s == .leftStick ? "leftStick" : "rightStick", kind: .stick, actions: [.pad(s)], label: ActionText.pad(s),
                        anchor: .center, x: 0, y: 0, width: 104, height: 104)
        case .keyStick:
            c = Control(id: "wasd", kind: .stick, actions: [key(0x57), key(0x53), key(0x41), key(0x44)], label: "WASD",
                        anchor: .center, x: 0, y: 0, width: 104, height: 104)
        case .dpad:
            let a: [InputAction] = gamepad ? [.pad(.up), .pad(.down), .pad(.left), .pad(.right)] : [key(0x26), key(0x28), key(0x25), key(0x27)]
            c = Control(id: "dpad", kind: .dpad, actions: a, label: gamepad ? "D-pad" : "Arrows", anchor: .center, x: 0, y: 0,
                        width: 128, height: 128)
        case .keyboard:
            c = Control(id: "keyboard", actions: [.playport(.keyboard)], label: Self.label(.playport(.keyboard)), anchor: .center,
                        x: 0, y: 0, width: 56, height: 56)
        case .lookArea:
            c = Control(id: "look", kind: .lookArea, actions: [.mouse(.move)], label: "Look", anchor: .center, x: 0, y: 0,
                        width: ControlLayout.wholeArea, height: ControlLayout.wholeArea)
        case .pointer:
            c = Control(id: "pointer", kind: .pointer, actions: [.mouse(.left)], label: "Pointer", anchor: .center, x: 0, y: 0,
                        width: ControlLayout.wholeArea, height: ControlLayout.wholeArea)
        case .rightClick, .hover, .scroll, .trackpad:
            c = Control(id: n.rawValue, kind: .tool, actions: [], label: n.title, anchor: .center, x: 0, y: 0, width: 48, height: 48,
                        tool: n.tool)
        }
        c.id = unusedID(c.id)
        endGesture()
        let before = snapshot
        if c.isSurface {
            layout.controls.insert(c, at: 0)
        } else {
            layout.controls.append(c)
        }
        record(before)
        selection = c.id
        return c.id
    }

    /// A copy of a control (not one a layout has once), `duplicateOffset` down and right, selected.
    @discardableResult
    public mutating func duplicate(_ id: String) -> String? {
        guard var c = layout.control(id), !c.isOnePerLayout, var f = frame(of: id) else { return nil }
        let a = area
        let oldZone = zone(of: id)
        f.x += Self.duplicateOffset; f.y += Self.duplicateOffset
        f = f.kept(in: a)
        c.id = unusedID(id)
        c.place(at: f, in: a)
        if var z = oldZone {
            z.x += Self.duplicateOffset; z.y += Self.duplicateOffset
            c.placeZone(at: z.kept(in: a), in: a)
        }
        endGesture()
        let before = snapshot
        layout.controls.insert(c, at: index(id)! + 1)
        record(before)
        selection = c.id
        return c.id
    }

    public mutating func remove(_ id: String) {
        guard let i = index(id) else { return }
        endGesture()
        let before = snapshot
        layout.controls.remove(at: i)
        record(before)
        if selection == id { selection = nil }
    }

    public mutating func setLabel(_ id: String, _ label: String) {
        edit(id) { $0.label = label }
    }

    /// A button's behaviour; other kinds have none.
    public mutating func setBehaviour(_ id: String, _ b: TouchBehaviour) {
        guard layout.control(id)?.kind == .button else { return }
        edit(id) { $0.behaviour = b }
    }

    /// The ActionPicker's choice for a slot. Nothing (nil), or a choice the slot does not take, changes nothing.
    public mutating func setAction(_ id: String, slot: Int, _ action: InputAction?) {
        guard let c = layout.control(id), let a = action, let accepts = Self.accepts(c, slot: slot), accepts(a) else { return }
        edit(id) { c in
            if c.kind == .button, c.label == Self.label(c.actions[0]) { c.label = Self.label(a) }
            c.actions[slot] = a
        }
    }

    /// The bare preset back (one undo step).
    public mutating func reset() {
        endGesture()
        let before = snapshot
        layout = presetLayout(preset)
        record(before)
        selection = nil
    }

    /// Another preset as the starting point: the game's copy of it, else the preset (one undo step).
    public mutating func start(from p: OnScreenLayout) {
        guard p != .off, p != preset else { return }
        endGesture()
        let before = snapshot
        preset = p
        layout = copies[p] ?? presetLayout(p)
        record(before)
        selection = nil
    }

    public mutating func undo() {
        endGesture()
        guard let s = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(s)
    }

    public mutating func redo() {
        endGesture()
        guard let s = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(s)
    }

    /// Done: unchanged, the game as it was; else its controls with this preset chosen and this layout
    /// as its copy (no copy when it is the preset).
    public func saved(into game: GameControls?) -> GameControls {
        var g = game ?? GameControls()
        guard changed else { return g }
        g.layout = preset
        g.layouts[preset] = isEdited ? layout : nil
        return g
    }

    // MARK: inside

    func presetLayout(_ p: OnScreenLayout) -> ControlLayout {
        p.layout(dpad: dpad, rightStick: rightStick) ?? .gamepad(dpad: dpad, rightStick: rightStick)
    }

    var snapshot: Snapshot { Snapshot(preset: preset, layout: layout) }

    func index(_ id: String) -> Int? { layout.controls.firstIndex { $0.id == id } }

    /// Starts (or continues) a gesture on a control that can move; nil for a surface or no control.
    mutating func begin(_ id: String) -> Gesture? {
        if let g = gesture, g.id == id { return g }
        endGesture()
        guard let c = layout.control(id), !c.isSurface, let f = frame(of: id) else { return nil }
        let g = Gesture(id: id, before: snapshot, frame: f, zone: zone(of: id))
        gesture = g
        selection = id
        return g
    }

    mutating func edit(_ id: String, _ change: (inout Control) -> Void) {
        endGesture()
        guard let i = index(id) else { return }
        let before = snapshot
        change(&layout.controls[i])
        record(before)
    }

    /// One undo step back to `before`, when anything changed.
    mutating func record(_ before: Snapshot) {
        guard before != snapshot else { return }
        undoStack.append(before)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack = []
    }

    mutating func restore(_ s: Snapshot) {
        preset = s.preset
        layout = s.layout
        if let id = selection, layout.control(id) == nil { selection = nil }
    }

    /// The shift that puts the nearest of `lines` on one of `targets` within `snapDistance`
    /// (and that target, for a guide); else the shift that puts the first line on the grid from `grid`.
    static func snap(_ lines: [Double], to targets: [Double], grid origin: Double) -> (Double, Double?) {
        var best: (shift: Double, target: Double)?
        for l in lines {
            for t in targets where abs(t - l) <= snapDistance && abs(t - l) < abs(best?.shift ?? .infinity) {
                best = (t - l, t)
            }
        }
        if let b = best { return (b.shift, b.target) }
        let first = lines[0]
        return (origin + ((first - origin) / Self.grid).rounded() * Self.grid - first, nil)
    }

    /// A pad stick not in the layout yet (the left first), nil with both there.
    func newStick() -> PadControl? {
        let there = Set(layout.controls.compactMap(\.padStick))
        return [PadControl.leftStick, .rightStick].first { !there.contains($0) }
    }

    /// `id`, else `id-2`, `id-3`… (a trailing `-n` of `id` dropped first): the first no control has.
    func unusedID(_ id: String) -> String {
        var base = Substring(id)
        if let dash = id.lastIndex(of: "-"), let n = Int(id[id.index(after: dash)...]), n > 1 { base = id[..<dash] }
        let ids = Set(layout.controls.map(\.id))
        if !ids.contains(String(base)) { return String(base) }
        return (2...).lazy.map { "\(base)-\($0)" }.first { !ids.contains($0) }!
    }

    /// A button's label for an action: a pad control by its name on the pad (`A`), else ActionText's.
    static func label(_ a: InputAction) -> String {
        switch a {
        case .pad(let p): ActionText.pad(p)
        case .playport(.keyboard): "Keys"
        default: ActionText.name(a)
        }
    }
}

extension Control {
    /// The look area or the pointer surface: the whole safe area, under everything.
    var isSurface: Bool { kind == .lookArea || kind == .pointer }

    /// The pad stick it is (the left or right stick, whole), else nil.
    var padStick: PadControl? {
        guard kind == .stick, case .pad(let p) = actions.first, p == .leftStick || p == .rightStick else { return nil }
        return p
    }

    /// What a layout has once (`LayoutEditor.addable`): a surface, a pad stick, a pointer tool.
    var isOnePerLayout: Bool { isSurface || padStick != nil || tool != nil }

    /// Placed at `f` (in the view): its size, and its centre from `anchor` (nil: the
    /// anchor of the ninth of the safe area `area` the centre is in).
    mutating func place(at f: TouchRect, in area: TouchRect, anchor: ControlAnchor? = nil) {
        let cx = f.x + f.width / 2, cy = f.y + f.height / 2
        self.anchor = anchor ?? ControlAnchor.nearest(x: cx, y: cy, in: area)
        let p = self.anchor.point(in: area)
        x = cx - p.x; y = cy - p.y
        width = f.width; height = f.height
    }

    /// A floating stick's zone placed at `f` (in the view), anchored to the ninth of the safe area its centre is in.
    mutating func placeZone(at f: TouchRect, in area: TouchRect) {
        guard var z = floatingZone else { return }
        z.anchor = ControlAnchor.nearest(x: f.x + f.width / 2, y: f.y + f.height / 2, in: area)
        let r = z.anchor.rect(width: f.width, height: f.height, in: area)
        z.x = f.x - r.x; z.y = f.y - r.y
        z.width = f.width; z.height = f.height
        floatingZone = z
    }
}

extension ControlKind {
    /// The inspector's name for it.
    public var title: String {
        switch self {
        case .button: "Button"
        case .stick: "Stick"
        case .dpad: "D-pad"
        case .lookArea: "Look area"
        case .pointer: "Pointer"
        case .tool: "Tool"
        }
    }
}

extension ControlAnchor {
    /// The anchor of the ninth of `area` that x, y is in.
    static func nearest(x: Double, y: Double, in area: TouchRect) -> ControlAnchor {
        let col = min(2, max(0, Int(((x - area.x) / max(area.width, 1) * 3).rounded(.down))))
        let row = min(2, max(0, Int(((y - area.y) / max(area.height, 1) * 3).rounded(.down))))
        return [[.topLeading, .top, .topTrailing], [.leading, .center, .trailing], [.bottomLeading, .bottom, .bottomTrailing]][row][col]
    }

    /// The inspector's side of the screen: `left side`, `middle`, `right side`.
    public var side: String {
        switch self {
        case .topLeading, .leading, .bottomLeading: "left side"
        case .top, .center, .bottom: "middle"
        case .topTrailing, .trailing, .bottomTrailing: "right side"
        }
    }
}
