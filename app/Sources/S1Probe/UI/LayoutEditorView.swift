// SPDX-License-Identifier: GPL-3.0-or-later
// The layout editor (PLA-13, phase 5;
// docs/design/2026-10-09-touch-controls/LayoutEditor.dc.html): a game's
// on-screen layout edited where it is played, over the paused game.
//
// - Opened from the in-game menu's Controls panel (Edit layout…, or A on its
//   On-screen controls row: InGameMenu.openLayoutEditor) over the paused game,
//   whose input the menu already holds (HostIO.holdGuest: every key, button
//   and touch let go, Lifecycle), and from Game options › Controls (Edit
//   on-screen layout) with no game running, over the game's art as its page
//   draws it, dimmed (AppShell).
// - PlayportKit's LayoutEditor is the model: what it edits, the snapping,
//   undo and redo, Done's result (LayoutEditor.saved, the game's own copy in
//   GameControls.layouts, through ControlsStore: it applies at once, in the
//   paused game on Resume). LayoutEditorPad is what each controller press does.
// - The canvas (LayoutCanvasView) draws the layout at the game's size and safe
//   area as the game does (ControlView), dashed while editing, on the 16 pt
//   grid lines (two of the 8 pt steps), with the selection's box, its corner
//   handles and size, a floating stick's zone, and the snap guides while a drag
//   lasts. Touch: a tap selects, a drag moves, a pinch or a corner handle
//   resizes; each whole gesture is one undo step.
// - The bar at the top: Add, the preset to start from, the controls' opacity
//   (the game's GameControls.opacity, saved with Done), undo, redo, Reset, Done.
//   The inspector beside the selected control (on the other half of the
//   screen): what it presses (the ActionPicker, per slot), its label (the
//   controller keyboard), its size, a button's behaviour, Duplicate, Remove.
// - By controller: the ringed control is the selection (LB, RB), the
//   directions move it, A opens the bar and inspector to the focus ring
//   (PadFocus), B back, and B again is Done; X Add, Y Reset, View undo, ≡ redo.
//   Over the paused game the presses come from the in-game menu (InGameMenu.press),
//   in the shell from AppShell.press; a picker over the editor takes them first.

#if canImport(UIKit)
import HostIOKit
import PlayportKit
import SwiftUI
import UIKit

@MainActor
final class LayoutEditorSession: ObservableObject {
    static let shared = LayoutEditorSession()

    /// Where it was opened from, and goes back to.
    enum Host: String {
        case inGame = "in game"
        case gameOptions = "game options"
    }

    struct Opened: Equatable {
        let titleID: String
        let title: String
        let host: Host
    }

    @Published private(set) var opened: Opened?
    @Published private(set) var editor = LayoutEditor(preset: .gamepad, width: 0, height: 0)
    @Published private(set) var pad = LayoutEditorPad()
    /// The controls' opacity as the bar shows it; saved with Done when it changed.
    @Published private(set) var opacity = ControlsOpacity.defaultValue
    private var openedOpacity = ControlsOpacity.defaultValue

    /// Game options › Controls' row.
    static let gameRowID = "opt:editLayout"
    static let doneID = "edit:done"

    var isUp: Bool { opened != nil }
    func isUp(_ host: Host) -> Bool { opened?.host == host }

    private static func log(_ line: String) { HostIO.log("layout editor: " + line) }

    /// Opens the editor on what the game plays with (`state`, resolved as the game resolves it).
    func open(titleID: String, title: String, host: Host, state: ControlsState) {
        guard opened == nil else { return }
        let size = Self.windowSize, insets = Self.insets
        editor = LayoutEditor(game: ControlsStore.shared.game(titleID), state: state, width: Double(size.width),
                              height: Double(size.height), insets: insets)
        pad = LayoutEditorPad()
        opacity = state.opacity
        openedOpacity = state.opacity
        PadModal.shared.close()
        opened = Opened(titleID: titleID, title: title, host: host)
        PadFocus.shared.reset(start: Self.doneID)
        Self.log("open (\(host.rawValue)) for \(titleID): \(editor.preset.title)"
                 + (editor.isEdited ? " (the game's own copy)" : "") + ", \(editor.layout.controls.count) controls, "
                 + "view \(Int(size.width))x\(Int(size.height))")
    }

    /// Game options › Controls › Edit on-screen layout, no game running: the layout the game
    /// would start on (its compatibility default too, as OnScreenControls resolves it), over its art.
    func openOverArt(titleID: String, title: String) {
        let store = ControlsStore.shared
        open(titleID: titleID, title: title, host: .gameOptions,
             state: ControlsState.resolve(game: store.game(titleID), defaults: store.defaults, controllerConnected: false,
                                          compat: LaunchSettingsStore.compat.entry(for: titleID)?.controls))
    }

    /// Done: what changed saved (the layout and the game's own copy, none when it is the preset; the
    /// opacity), nothing when nothing did, and back.
    func done() {
        guard let o = opened else { return }
        var e = editor
        e.endGesture()
        let store = ControlsStore.shared
        let before = store.game(o.titleID)
        var g = e.saved(into: before)
        if opacity != openedOpacity { g.opacity = opacity }
        if g != before { store.setGame(o.titleID, g) }
        Self.log("done for \(o.titleID): "
                 + (!e.changed ? "layout unchanged" : e.preset.title
                    + (e.isEdited ? ", the game's own copy (\(e.layout.controls.count) controls)" : ", as the preset"))
                 + ", opacity \(ControlsOpacity.label(g.opacity ?? opacity))")
        close()
    }

    /// Closed without saving (the game ended under it), or after Done.
    func close() {
        guard let o = opened else { return }
        PadModal.shared.close()
        opened = nil
        switch o.host {
        case .inGame: InGameMenu.shared.layoutEditorClosed()
        case .gameOptions: PadFocus.shared.reset(start: Self.gameRowID)
        }
    }

    // MARK: the controller

    /// A press, as the shell or the in-game menu routes it: a picker's first, then the editor's.
    func press(_ b: NavButton) {
        guard isUp else { return }
        if PadModal.shared.isUp { return PadModal.shared.press(b) }
        var e = editor, p = pad
        let effect = p.press(b, editor: &e)
        editor = e
        pad = p
        switch effect {
        case .none: break
        case .openPanel: PadFocus.shared.ring(firstPanelItem)
        case .moveRing(let d): PadFocus.shared.move(d, within: { $0.hasPrefix("edit:") })
        case .activate: PadFocus.shared.activate()
        case .add: add()
        case .done: done()
        }
    }

    /// Where A from the canvas rings: the inspector's first row, else the bar's Add.
    private var firstPanelItem: String {
        guard let id = editor.selection, let d = editor.details(id) else { return "edit:add" }
        return d.slots.isEmpty ? "edit:label" : "edit:slot-0"
    }

    // MARK: touch and the panel

    func setView(_ size: CGSize) {
        let i = Self.insets
        guard Double(size.width) != editor.width || Double(size.height) != editor.height || i != editor.insets,
              size.width > 0, size.height > 0 else { return }
        editor.setView(width: Double(size.width), height: Double(size.height), insets: i)
    }

    /// A tap on the canvas: the control under it, or none; the canvas has the controller then.
    func select(at p: CGPoint) {
        editor.select(editor.control(atX: Double(p.x), y: Double(p.y)))
        pad.focus = .canvas
    }

    func select(_ id: String) {
        editor.select(id)
        pad.focus = .canvas
    }

    func drag(_ id: String, dx: CGFloat, dy: CGFloat) { editor.drag(id, dx: Double(dx), dy: Double(dy)) }
    func pinch(_ id: String, scale: Double) { editor.pinch(id, scale: scale) }
    func endGesture() { editor.endGesture() }
    func undo() { editor.undo() }
    func redo() { editor.redo() }
    func reset() { editor.reset() }

    func add() {
        PadModal.shared.picker(title: "Add", context: opened?.title, note: "Placed in the middle; drag it where it goes.",
                               options: editor.addable.map { PadOption(id: $0.rawValue, label: $0.title) },
                               selected: nil) { id in
            guard let n = NewControl(rawValue: id) else { return }
            LayoutEditorSession.shared.editor.add(n)
        }
    }

    /// The preset to start from: the game's own copy of it when it has one.
    func choosePreset() {
        let copies = opened.map { ControlsStore.shared.game($0.titleID).layouts } ?? [:]
        PadModal.shared.picker(title: "Start from", context: opened?.title,
                               note: "Your changes to this one stay until Done; undo brings them back.",
                               options: OnScreenLayout.allCases.filter { $0 != .off }.map {
                                   PadOption(id: $0.rawValue, label: $0.title, detail: copies[$0] == nil ? nil : "This game's own")
                               },
                               selected: editor.preset.rawValue) { id in
            guard let p = OnScreenLayout(rawValue: id) else { return }
            LayoutEditorSession.shared.editor.start(from: p)
        }
    }

    /// The bar's opacity: left and right step it, A and a tap go round.
    func stepOpacity(by: Int, wrapping: Bool = false) {
        let next = ControlsOpacity.step(opacity, by: by)
        opacity = wrapping && next == opacity ? ControlsOpacity.steps[0] : next
    }

    /// What a slot of the selected control presses, through the ActionPicker.
    func pick(slot: Int) {
        guard let id = editor.selection,
              let picker = editor.picker(id, slot: slot, recent: ActionPickerRecent.load(.standard)) else { return }
        PadModal.shared.actionPicker(picker) { action in
            LayoutEditorSession.shared.editor.setAction(id, slot: slot, action)
            if let action { ActionPickerRecent.save(ActionPickerRecent.adding(action, to: ActionPickerRecent.load(.standard)), .standard) }
        }
    }

    func editLabel() {
        guard let id = editor.selection, let d = editor.details(id) else { return }
        PadModal.shared.keyboard(title: "Label", text: d.label, maxLength: 16) { text in
            LayoutEditorSession.shared.editor.setLabel(id, text)
        }
    }

    func resize(by steps: Int) {
        guard let id = editor.selection else { return }
        editor.resize(id, by: steps)
    }

    func setBehaviour(_ b: TouchBehaviour) {
        guard let id = editor.selection else { return }
        editor.setBehaviour(id, b)
    }

    /// Hold, Toggle, Repeat in turn (left and right, A going round).
    func stepBehaviour(by: Int) {
        guard let id = editor.selection, let now = editor.details(id)?.behaviour else { return }
        let all = TouchBehaviour.allCases
        editor.setBehaviour(id, all[((all.firstIndex(of: now)! + by) % all.count + all.count) % all.count])
    }

    func duplicate() {
        guard let id = editor.selection else { return }
        editor.duplicate(id)
    }

    func remove() {
        guard let id = editor.selection else { return }
        editor.remove(id)
        pad.focus = .canvas
    }

    // MARK: the view's size

    /// The game's view fills the window (GameSurfaceView), and the shell's does too.
    private static var windowSize: CGSize {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .first { $0.isKeyWindow }?.bounds.size ?? .zero
    }

    /// The safe area the game's controls keep to (the window's: TouchControlsView's gameSafeInsets).
    private static var insets: ControlInsets {
        let i = WindowInsets.shared.insets
        return ControlInsets(top: Double(i.top), left: Double(i.leading), bottom: Double(i.bottom), right: Double(i.trailing))
    }

    #if !PLAYPORT_RELEASE
    /// The driver's log line (Dev/UIDriver.swift).
    var summary: String {
        guard let o = opened else { return "layout editor closed" }
        let selected = editor.selection.map { id in
            id + (editor.frame(of: id).map { " at \(Int($0.x)),\(Int($0.y)) \(Int($0.width))x\(Int($0.height))" } ?? "")
        } ?? "none"
        return "layout editor (\(o.host.rawValue)) for \(o.titleID): \(editor.preset.rawValue)" + (editor.isEdited ? " edited" : "")
            + ", \(editor.layout.controls.count) controls, selection \(selected), "
            + (pad.focus == .panel ? "panel ring \(PadFocus.shared.focused ?? "none")" : "canvas")
            + ", undo=\(editor.canUndo) redo=\(editor.canRedo), opacity \(ControlsOpacity.label(opacity))"
            + (PadModal.shared.summary.map { ", \($0)" } ?? "")
    }
    #endif
}

/// The editor's screen: the canvas, the bar, the inspector, the hint and the footer.
/// `inGame`: over the paused game, where the shell is not up, so it brings the focus
/// ring's root and the pickers (PadModalHost) itself, as InGameControllerPage does.
struct LayoutEditorView: View {
    let inGame: Bool
    @ObservedObject private var session = LayoutEditorSession.shared
    @ObservedObject private var focus = PadFocus.shared
    @ObservedObject private var modal = PadModal.shared
    @ObservedObject private var safe = WindowInsets.shared

    var body: some View {
        let lead = safe.side(44, safe.insets.leading), trail = safe.side(44, safe.insets.trailing)
        let editor = session.editor
        ZStack(alignment: .topLeading) {
            // The game (or its art) dimmed behind; nothing under it takes a touch.
            Color(red: 5 / 255, green: 7 / 255, blue: 10 / 255).opacity(0.5)
            GeometryReader { geo in
                LayoutCanvas(editor: editor, opacity: session.opacity).ignoresSafeArea()
                    .onChange(of: geo.size, initial: true) { _, s in session.setView(s) }
                    .onChange(of: safe.insets) { _, _ in session.setView(geo.size) }
            }
            .ignoresSafeArea()
            bar
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, max(8, safe.insets.top))
            if let id = editor.selection, let d = editor.details(id) {
                // On the half of the screen the control is not on.
                let left = (editor.frame(of: id).map { $0.x + $0.width / 2 } ?? 0) >= editor.width / 2
                inspector(d)
                    .padding(.top, max(54, safe.insets.top + 46))
                    .padding(.leading, left ? lead : 0).padding(.trailing, left ? 0 : trail)
                    .frame(maxWidth: .infinity, alignment: left ? .leading : .trailing)
            }
            VStack {
                Spacer()
                HStack(alignment: .bottom, spacing: 12) {
                    Text("Drag to move · pinch to resize · snaps to the grid and to other controls")
                        .font(.system(size: 11.5)).foregroundStyle(PP.soft).lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(PP.surface.opacity(0.86), in: Capsule())
                        .overlay(Capsule().stroke(PP.line, lineWidth: 1))
                        .allowsHitTesting(false)
                    Spacer(minLength: 0)
                    PadFooter(hints: hints, leading: true).fixedSize()
                }
                .opacity(modal.isUp ? 0 : 1)
                .padding(.leading, lead).padding(.trailing, trail)
                .padding(.bottom, AppShell.footerBottom)
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(PP.text)
        .modifier(EditorHost(inGame: inGame, insets: safe.insets, modalUp: modal.isUp))
        .accessibilityIdentifier("layout-editor")
    }

    // MARK: the bar

    private var bar: some View {
        let e = session.editor
        return HStack(spacing: 4) {
            barItem("edit:add", "＋ Add", hint: "Add") { session.add() }
            barItem("edit:preset", e.preset.title + " ▾", hint: "Start from") { session.choosePreset() }
            barItem("edit:opacity", "Opacity " + ControlsOpacity.label(session.opacity), hint: "Change",
                    adjust: { session.stepOpacity(by: $0) }) { session.stepOpacity(by: 1, wrapping: true) }
            barItem("edit:undo", "↶", hint: "Undo", enabled: e.canUndo) { session.undo() }
            barItem("edit:redo", "↷", hint: "Redo", enabled: e.canRedo) { session.redo() }
            barItem("edit:reset", "Reset", hint: "Reset", enabled: e.isEdited) { session.reset() }
            barItem(LayoutEditorSession.doneID, "Done", hint: "Save", accent: true) { session.done() }
        }
        .padding(4)
        .background(PP.surface.opacity(0.92), in: Capsule())
        .overlay(Capsule().stroke(PP.line, lineWidth: 1))
    }

    private func ringed(_ id: String) -> Bool { session.pad.focus == .panel && focus.focused == id }

    private func barItem(_ id: String, _ title: String, hint: String, enabled: Bool = true, accent: Bool = false,
                         adjust: ((Int) -> Void)? = nil, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 12.5, weight: accent ? .bold : .semibold))
            .foregroundStyle(accent ? PP.onAccent : PP.text)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, accent ? 14 : 11).padding(.vertical, 6)
            .background(accent ? PP.accent : .clear, in: Capsule())
            .overlay(Capsule().stroke(PP.accent, lineWidth: 2).opacity(ringed(id) ? 1 : 0))
            .opacity(enabled ? 1 : 0.4)
            .padItem(id, hint: hint, cornerRadius: 12, adjust: adjust, ring: false) { if enabled { action() } }
    }

    // MARK: the inspector

    private func inspector(_ d: ControlDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(String(d.label.prefix(3)))
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.5)
                    .frame(width: 36, height: 36)
                    .background(Color(red: 12 / 255, green: 16 / 255, blue: 24 / 255).opacity(0.3), in: Circle())
                    .overlay(Circle().stroke(PP.text.opacity(0.4), lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 0) {
                    Text(d.label).font(PP.display(18)).lineLimit(1)
                    Text(d.subtitle).font(.system(size: 11.5)).foregroundStyle(PP.muted).lineLimit(1)
                }
            }
            ForEach(d.slots.indices, id: \.self) { i in
                row("edit:slot-\(i)", d.slots[i], value: d.actions[i] + " ›", hint: "Change") { session.pick(slot: i) }
            }
            row("edit:label", "Label", value: d.label, hint: "Edit") { session.editLabel() }
            if d.movable {
                row("edit:size", "Size", value: "‹ " + d.size + " ›", hint: "Bigger", adjust: { session.resize(by: $0) }) {
                    session.resize(by: 1)
                }
            }
            if let b = d.behaviour { behaviour(b) }
            HStack(spacing: 6) {
                if d.duplicable { button("edit:duplicate", "Duplicate") { session.duplicate() } }
                button("edit:remove", "Remove", colour: Color(hex: 0xFF9A8A)) { session.remove() }
            }
        }
        .padding(14)
        .frame(width: 262, alignment: .leading)
        .background(PP.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(PP.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 12)
        .accessibilityIdentifier("layout-editor-inspector")
    }

    /// A row as the board's: light while the focus ring is on it.
    private func row(_ id: String, _ title: String, value: String, hint: String, adjust: ((Int) -> Void)? = nil,
                     action: @escaping () -> Void) -> some View {
        let on = ringed(id)
        return HStack(spacing: 12) {
            Text(title).font(.system(size: 15, weight: .medium))
            Spacer(minLength: 0)
            Text(value).font(.system(size: 13)).foregroundStyle(on ? PP.background.opacity(0.75) : PP.muted).lineLimit(1)
        }
        .foregroundStyle(on ? PP.background : PP.text)
        .padding(.horizontal, 14).frame(height: 34)
        .background(on ? PP.text : PP.raised, in: RoundedRectangle(cornerRadius: 10))
        .padItem(id, hint: hint, cornerRadius: 10, adjust: adjust, ring: false, action: action)
    }

    private func behaviour(_ now: TouchBehaviour) -> some View {
        HStack(spacing: 2) {
            ForEach(TouchBehaviour.allCases, id: \.self) { b in
                Text(b.rawValue.capitalized).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(b == now ? PP.background : PP.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(b == now ? PP.text : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                    .onTapGesture { session.setBehaviour(b) }
                    .accessibilityIdentifier("edit:behaviour-\(b.rawValue)")
            }
        }
        .padding(3)
        .background(PP.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ringed("edit:behaviour") ? PP.accent : PP.line,
                                                           lineWidth: ringed("edit:behaviour") ? 2 : 1))
        .padItem("edit:behaviour", hint: "Change", cornerRadius: 12, adjust: { session.stepBehaviour(by: $0) }, ring: false) {
            session.stepBehaviour(by: 1)
        }
    }

    private func button(_ id: String, _ title: String, colour: Color = PP.text, action: @escaping () -> Void) -> some View {
        Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(colour)
            .frame(maxWidth: .infinity).padding(7)
            .background(PP.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(PP.accent, lineWidth: 2).opacity(ringed(id) ? 1 : 0))
            .padItem(id, hint: title, cornerRadius: 10, ring: false, action: action)
    }

    // MARK: the footer

    private var hints: [PadHint] {
        let s = session
        var h: [PadHint] = []
        if s.pad.focus == .panel {
            if let a = focus.hint, !a.isEmpty { h.append(PadHint(button: .a, label: a) { s.press(.a) }) }
            h.append(PadHint(button: .lb, label: "Control", action: { s.press(.rb) }, also: .rb))
            h.append(PadHint(button: .b, label: "Back") { s.press(.b) })
            return h
        }
        h.append(PadHint(button: .a, label: s.editor.selection == nil ? "Choose" : "Edit") { s.press(.a) })
        h.append(PadHint(button: .lb, label: "Control", action: { s.press(.rb) }, also: .rb))
        h.append(PadHint(button: .x, label: "Add") { s.press(.x) })
        h.append(PadHint(button: .y, label: "Reset") { s.press(.y) })
        h.append(PadHint(button: .b, label: "Done") { s.press(.b) })
        return h
    }
}

/// Over the paused game: the focus ring's root and the pickers, as the shell gives them elsewhere.
private struct EditorHost: ViewModifier {
    let inGame: Bool
    let insets: EdgeInsets
    let modalUp: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if inGame {
            content
                .padFocusRoot()
                .overlay { PadModalHost().safeAreaPadding(insets).animation(.easeOut(duration: 0.15), value: modalUp) }
        } else {
            content
        }
    }
}

// MARK: the canvas

private struct LayoutCanvas: UIViewRepresentable {
    let editor: LayoutEditor
    let opacity: Double

    func makeUIView(context: Context) -> LayoutCanvasView { LayoutCanvasView() }
    func updateUIView(_ v: LayoutCanvasView, context: Context) { v.show(editor, opacity: opacity) }
}

/// The layout as the game draws it (ControlView), dashed, on the grid, with the selection,
/// its handles and size, a floating stick's zone and the drag's guides; and the touches.
private final class LayoutCanvasView: UIView, UIGestureRecognizerDelegate {
    private let grid = CAShapeLayer(), zone = CAShapeLayer(), guides = CAShapeLayer(), box = CAShapeLayer()
    private let controlsLayer = UIView()
    private var views: [String: (key: Control, view: UIView)] = [:]
    private var handles: [UIView] = []
    private let badge = UILabel()
    private var drawnGrid: (TouchRect, CGSize)?
    private var editor: LayoutEditor?

    private enum Gesture {
        case drag(String)
        case handle(String, centre: TouchPoint, from: TouchPoint)
    }
    private var pan: Gesture?
    /// A pinch took over this pan's touch: it does nothing more until it ends.
    private var panSpent = false
    private var pinchID: String?

    private static let amber = UIColor(red: 245 / 255, green: 181 / 255, blue: 68 / 255, alpha: 1)
    private static let onAmber = UIColor(red: 26 / 255, green: 18 / 255, blue: 4 / 255, alpha: 1)
    private static let edge = UIColor(red: 238 / 255, green: 241 / 255, blue: 245 / 255, alpha: 1)

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        grid.strokeColor = Self.edge.withAlphaComponent(0.05).cgColor
        grid.lineWidth = 1
        layer.addSublayer(grid)
        zone.strokeColor = Self.amber.withAlphaComponent(0.5).cgColor
        zone.fillColor = Self.amber.withAlphaComponent(0.05).cgColor
        zone.lineDashPattern = [6, 4]
        zone.lineWidth = 1.5
        layer.addSublayer(zone)
        controlsLayer.isUserInteractionEnabled = false
        addSubview(controlsLayer)
        box.strokeColor = Self.amber.cgColor
        box.fillColor = UIColor.clear.cgColor
        box.lineWidth = 2
        layer.addSublayer(box)
        for _ in 0..<4 {
            let h = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            h.backgroundColor = Self.amber
            h.layer.cornerRadius = 3
            h.layer.borderWidth = 1.5
            h.layer.borderColor = Self.onAmber.cgColor
            h.isUserInteractionEnabled = false
            addSubview(h)
            handles.append(h)
        }
        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.textColor = Self.onAmber
        badge.backgroundColor = Self.amber
        badge.textAlignment = .center
        badge.layer.cornerRadius = 8
        badge.layer.masksToBounds = true
        addSubview(badge)
        guides.strokeColor = Self.amber.cgColor
        guides.lineWidth = 1.5
        guides.lineDashPattern = [5, 4]
        layer.addSublayer(guides)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let drag = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        drag.maximumNumberOfTouches = 2
        drag.delegate = self
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        [tap, drag, pinch].forEach(addGestureRecognizer)
        accessibilityIdentifier = "layout-editor-canvas"
    }

    required init?(coder: NSCoder) { fatalError("LayoutCanvasView is created in code") }

    override func layoutSubviews() {
        super.layoutSubviews()
        controlsLayer.frame = bounds
        if let editor { show(editor, opacity: Double(controlsLayer.alpha)) }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer) || (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
    }

    // MARK: drawing

    func show(_ e: LayoutEditor, opacity: Double) {
        editor = e
        controlsLayer.alpha = CGFloat(opacity)
        let area = e.insets.area(width: e.width, height: e.height)
        if drawnGrid.map({ $0.0 != area || $0.1 != bounds.size }) ?? true {
            drawnGrid = (area, bounds.size)
            let p = UIBezierPath(), step = LayoutEditor.grid * 2
            var x = area.x.truncatingRemainder(dividingBy: step)
            while x <= Double(bounds.width) { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: bounds.height)); x += step }
            var y = area.y.truncatingRemainder(dividingBy: step)
            while y <= Double(bounds.height) { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: bounds.width, y: y)); y += step }
            grid.path = p.cgPath
        }
        place(e)
        // The selection: its box 6 pt outside it, the corner handles (a control that moves), its size.
        if let id = e.selection, let f = e.frame(of: id).map(CGRect.init(touch:)), let d = e.details(id) {
            let r = f.insetBy(dx: -6, dy: -6)
            box.path = UIBezierPath(roundedRect: r, cornerRadius: 10).cgPath
            box.isHidden = false
            for (h, c) in zip(handles, [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                        CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]) {
                h.center = c
                h.isHidden = !d.movable
            }
            badge.text = d.size
            badge.isHidden = !d.movable
            let w = badge.intrinsicContentSize.width + 14
            badge.frame = CGRect(x: r.minX + 10, y: max(0, r.minY - 22), width: w, height: 16)
            if let z = e.zone(of: id) {
                zone.path = UIBezierPath(roundedRect: CGRect(touch: z), cornerRadius: 12).cgPath
                zone.isHidden = false
            } else {
                zone.isHidden = true
            }
        } else {
            box.isHidden = true
            zone.isHidden = true
            badge.isHidden = true
            handles.forEach { $0.isHidden = true }
        }
        let g = UIBezierPath()
        for guide in e.guides {
            switch guide {
            case .vertical(let x): g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: Double(bounds.height)))
            case .horizontal(let y): g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: Double(bounds.width), y: y))
            }
        }
        guides.path = g.cgPath
    }

    /// One view per control, in the layout's order (the last on top); a control that only moved
    /// keeps its view.
    private func place(_ e: LayoutEditor) {
        var kept: [String: (key: Control, view: UIView)] = [:]
        for c in e.layout.controls {
            guard let f = e.frame(of: c.id).map(CGRect.init(touch:)) else { continue }
            var key = c
            key.anchor = .center; key.x = 0; key.y = 0; key.floatingZone = nil
            key.width = Double(f.width); key.height = Double(f.height)
            if let old = views.removeValue(forKey: c.id), old.key == key {
                old.view.frame = f
                kept[c.id] = old
            } else {
                kept[c.id] = (key, Self.container(c, frame: f))
            }
            controlsLayer.addSubview(kept[c.id]!.view)   // to the front, in order
        }
        views.values.forEach { $0.view.removeFromSuperview() }
        views = kept
    }

    /// The control as the game draws it, with the editor's dashed edge.
    private static func container(_ c: Control, frame f: CGRect) -> UIView {
        let v = UIView(frame: f)
        v.isUserInteractionEnabled = false
        v.addSubview(ControlView(control: c, frame: CGRect(origin: .zero, size: f.size)))
        let dash = CAShapeLayer()
        let surface = c.kind == .lookArea || c.kind == .pointer
        let round = (c.kind == .button && f.width == f.height) || c.kind == .stick
        let radius = surface ? 14 : round ? min(f.width, f.height) / 2 : min(12, min(f.width, f.height) / 2)
        dash.path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: f.size).insetBy(dx: 1, dy: 1), cornerRadius: radius).cgPath
        dash.fillColor = UIColor.clear.cgColor
        dash.strokeColor = edge.withAlphaComponent(surface ? 0.25 : 0.6).cgColor
        dash.lineWidth = 1.5
        dash.lineDashPattern = [5, 4]
        v.layer.addSublayer(dash)
        return v
    }

    // MARK: touches

    private var session: LayoutEditorSession { LayoutEditorSession.shared }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        session.select(at: g.location(in: self))
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self), t = g.translation(in: self)
        switch g.state {
        case .began:
            panSpent = false
            let start = CGPoint(x: p.x - t.x, y: p.y - t.y)
            let e = session.editor
            if let id = e.selection, let f = e.frame(of: id).map(CGRect.init(touch:)), e.details(id)?.movable == true,
               Self.grabsCorner(of: f.insetBy(dx: -6, dy: -6), at: start) {
                pan = .handle(id, centre: TouchPoint(x: Double(f.midX), y: Double(f.midY)),
                              from: TouchPoint(x: Double(start.x), y: Double(start.y)))
            } else if let id = e.control(atX: Double(start.x), y: Double(start.y)) {
                session.select(id)
                pan = .drag(id)
            } else {
                pan = nil
            }
        case .changed:
            guard !panSpent, g.numberOfTouches == 1, let pan else { return }
            switch pan {
            case .drag(let id): session.drag(id, dx: t.x, dy: t.y)
            case .handle(let id, let centre, let from):
                session.pinch(id, scale: LayoutEditorPad.handleScale(centre: centre, from: from,
                                                                     to: TouchPoint(x: Double(p.x), y: Double(p.y))))
            }
        default:
            if pan != nil, !panSpent { session.endGesture() }
            pan = nil
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            // A drag under way ends here; its finger does nothing more.
            if pan != nil, !panSpent {
                session.endGesture()
                panSpent = true
            }
            let p = g.location(in: self), e = session.editor
            if let id = e.selection, let f = e.frame(of: id).map(CGRect.init(touch:)), f.insetBy(dx: -24, dy: -24).contains(p) {
                pinchID = id
            } else {
                pinchID = e.control(atX: Double(p.x), y: Double(p.y))
            }
            if let id = pinchID { session.select(id) }
        case .changed:
            if let id = pinchID { session.pinch(id, scale: Double(g.scale)) }
        default:
            if pinchID != nil { session.endGesture() }
            pinchID = nil
        }
    }

    /// Whether `p` is within reach of a corner of `r` (a handle's grab).
    private static func grabsCorner(of r: CGRect, at p: CGPoint) -> Bool {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
            .contains { hypot($0.x - p.x, $0.y - p.y) <= 18 }
    }
}

private extension CGRect {
    init(touch r: TouchRect) { self.init(x: r.x, y: r.y, width: r.width, height: r.height) }
}
#endif
