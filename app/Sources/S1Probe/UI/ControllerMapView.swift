// SPDX-License-Identifier: GPL-3.0-or-later
// The Controller page (docs/design/2026-10-09-touch-controls/ControllerMapping.dc.html;
// PlayportKit ControllerMap.swift, ControllerMapPage.swift): what a physical
// controller does in a game, as a controller or as a keyboard and mouse.
//
// - Opened from Game options › Controls › Controller (AppRoutes.GamePanel.controller,
//   over the whole game page) for the game's own map, from Settings ›
//   Controls › Controller (AppRoutes.settingsControllerMap, in Settings' place)
//   for the default every game follows, and from the in-game menu's Controls
//   panel over the paused game (InGameControllerPage, UI/InGameMenuView.swift),
//   where the menu's presses drive it (ControllerMapRing.pagePress).
// - The ring (PlayportKit ControllerMapNav; owner, 2026-10-13, touch controls U,
//   replacing 3b's "press a controller's input to ring its row"): the D-pad and
//   the left stick move it through every item in every mode, LB and RB cycle
//   the mode from anywhere, A edits, Y resets, B goes back. No button press
//   rings or edits a row by itself.
// - The mode switch at the top right: As a controller, As keyboard & mouse,
//   Custom (LB and RB, A on it, or a tap). A game's own has the amber dot, and Y
//   puts it back to Settings' (asking first over an edited Custom table).
// - The pad's picture in the middle, its inputs' rows down both sides ("As the
//   controller" in As a controller); the ringed input is amber in the picture.
//   Home is Playport's, labelled, never a row.
// - A on an input: in Custom the ActionPicker (a stick's or the D-pad's list
//   first); as keyboard & mouse (read only) "Edit a copy?" first, as a
//   controller "Switch to Custom?" first, then the same in Custom
//   (ControllerMapConfirm.forEditing). Y in Custom puts the row back to the
//   preset; Edit a copy and Reset all ask first over the player's own table.
// - Look speed (Keyboard & mouse and Custom): how fast a stick bound to mouse
//   look turns the view (PlayportKit LookSpeed); a game's own has the dot, Y clears it.
//
// Every change is saved at once (ControlsStore, or Settings' keys) and applies
// in a running game at once (HostIO.updateControllerMap).

import Combine
import HostIOKit
import PlayportKit
import SwiftUI

/// Whose map the page shows: a game's own (over Settings'), or Settings' default.
enum ControllerMapTarget: Equatable {
    case game(String)
    case defaults
}

/// Reads and saves the target's map and look speed.
@MainActor
enum ControllerMapAccess {
    /// The map in use: the game's own, else Settings'.
    static func map(_ t: ControllerMapTarget) -> ControllerMap {
        let store = ControlsStore.shared
        switch t {
        case .game(let id): return store.game(id).controllerMap(over: store.defaults)
        case .defaults: return store.defaults.controllerMap
        }
    }

    /// The game sets its own map (the amber dot on the mode).
    static func isOwn(_ t: ControllerMapTarget) -> Bool {
        if case .game(let id) = t { return ControlsStore.shared.game(id).controllerMap != nil }
        return false
    }

    /// Saves `m` (nil: the game follows Settings' again).
    static func save(_ m: ControllerMap?, _ t: ControllerMapTarget) {
        switch t {
        case .game(let id):
            var c = ControlsStore.shared.game(id)
            c.controllerMap = m
            ControlsStore.shared.setGame(id, c)
        case .defaults:
            let m = m ?? ControllerMap()
            // A mode's name while the table is the preset (as `set:` writes it), else the map's JSON.
            let text = m.custom == ControllerMap.keyboardMouse ? m.mode.rawValue
                : (try? JSONEncoder().encode(m)).flatMap { String(data: $0, encoding: .utf8) } ?? m.mode.rawValue
            UserDefaults.standard.set(text, forKey: ControllerMap.defaultsKey)
        }
    }

    static func lookSpeed(_ t: ControllerMapTarget) -> Double {
        let store = ControlsStore.shared
        switch t {
        case .game(let id): return store.game(id).lookSpeed(over: store.defaults)
        case .defaults: return store.defaults.lookSpeed
        }
    }

    static func isOwnLookSpeed(_ t: ControllerMapTarget) -> Bool {
        if case .game(let id) = t { return ControlsStore.shared.game(id).lookSpeed != nil }
        return false
    }

    /// Y on a game's map (the mode row, Game options' Controller row): `reset`
    /// puts it back to Settings', asking first over an edited Custom table of the
    /// game's own (ControllerMapConfirm.useDefault); at once otherwise.
    static func resetToDefault(_ t: ControllerMapTarget, context: String?, reset: @escaping () -> Void) {
        guard case .game(let id) = t, ControllerMapConfirm.neededForDefault(own: ControlsStore.shared.game(id).controllerMap)
        else { return reset() }
        let c = ControllerMapConfirm.useDefault
        PadModal.shared.picker(title: c.title, context: (context ?? "Settings") + " · Controller", note: c.note,
                               options: c.options.map { PadOption(id: $0.id, label: $0.label) },
                               selected: c.defaultChoice) { choice in
            if c.outcome(choice, for: map(t)) == .useDefault { reset() }
        }
    }

    /// Saves the look speed (nil: the game follows Settings' again).
    static func saveLookSpeed(_ v: Double?, _ t: ControllerMapTarget) {
        switch t {
        case .game(let id):
            var c = ControlsStore.shared.game(id)
            c.lookSpeed = v
            ControlsStore.shared.setGame(id, c)
        case .defaults:
            UserDefaults.standard.set(v ?? LookSpeed.defaultValue, forKey: LookSpeed.defaultsKey)
        }
    }
}

struct ControllerMapView: View {
    static let modeID = "ctl:mode"
    static let lookSpeedID = "ctl:lookSpeed"
    static let resetAllID = "ctl:resetAll"
    static let copyID = "ctl:copy"
    /// The rows that open this page.
    static let gameRowID = "opt:controllerMap"
    static let settingsRowID = "set:controllerMap"

    let target: ControllerMapTarget
    /// The game's name, else nil (Settings).
    var context: String?
    @ObservedObject private var store = ControlsStore.shared
    @ObservedObject private var focus = PadFocus.shared
    @ObservedObject private var modal = PadModal.shared

    var body: some View {
        let map = ControllerMapAccess.map(target)
        let table = map.bindings ?? ControllerMap.keyboardMouse
        VStack(spacing: 0) {
            header(map)
            HStack(alignment: .top, spacing: 14) {
                column(ControllerMapRow.left, map, table)
                VStack(spacing: 8) {
                    PadPicture(lit: ringedRow, mode: map.mode)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if map.mode != .controller { lookSpeedRow }
                    Text(Self.hint(map.mode)).font(.system(size: 12)).foregroundStyle(PP.muted)
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("controller-page-hint")
                }
                .frame(maxHeight: .infinity, alignment: .top)
                column(ControllerMapRow.right, map, table)
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 44).padding(.top, 14).padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PP.background.ignoresSafeArea())
        .onReceive(ControllerMapRing.moves) { d in
            guard !modal.isUp else { return }
            move(d)
        }
        .onReceive(ControllerMapRing.modeSteps) { by in
            // The ring stays where it is (an item the new mode has not comes back to the page's first).
            guard !modal.isUp else { return }
            setMode(ControllerMapNav.cycle(ControllerMapAccess.map(target).mode, by: by))
        }
        .accessibilityIdentifier("controller-page")
    }

    /// The input under the ring, for the picture.
    private var ringedRow: ControllerMapRow? { focus.focused.flatMap(ControllerMapRow.init(itemID:)) }

    /// A direction: the ring's next item (ControllerMapNav); left and right on Look speed change it.
    private func move(_ d: FocusDirection) {
        let mode = ControllerMapAccess.map(target).mode
        if d == .left || d == .right, focus.focused == Self.lookSpeedID, mode != .controller {
            return stepLookSpeed(d == .left ? -1 : 1)
        }
        focus.ring(ControllerMapNav.next(from: focus.focused, d, mode: mode))
    }

    // MARK: the header: the title, the mode, Edit a copy or Reset all

    private func header(_ map: ControllerMap) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(((context.map { $0 + " · " } ?? "Settings · ") + "Controls").uppercased())
                    .font(.system(size: 11, weight: .semibold)).tracking(1.1).foregroundStyle(PP.muted).lineLimit(1)
                Text("Controller").font(PP.display(24)).foregroundStyle(PP.text)
            }
            Spacer(minLength: 8)
            switch map.mode {
            case .keyboardMouse:
                smallButton(Self.copyID, "Edit a copy", enabled: true) { editCopy() }
            case .custom:
                smallButton(Self.resetAllID, "Reset all", enabled: map.custom != ControllerMap.keyboardMouse) { resetAll() }
            case .controller:
                EmptyView()
            }
            modeSwitch(map)
        }
    }

    private func modeSwitch(_ map: ControllerMap) -> some View {
        let own = ControllerMapAccess.isOwn(target)
        let modes = ControllerMap.Mode.allCases
        let selected = focus.focused == Self.modeID
        return HStack(spacing: 6) {
            if own { Circle().fill(PP.accent).frame(width: 7, height: 7) }
            HStack(spacing: 2) {
                ForEach(modes, id: \.self) { m in
                    Text(m.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).fixedSize()
                        .foregroundStyle(m == map.mode ? PP.background : PP.muted)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(m == map.mode ? PP.text : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            focus.ring(Self.modeID)
                            setMode(m)
                        }
                        .accessibilityIdentifier("controller-mode-\(m.rawValue)")
                }
            }
            .padding(2)
            .background(PP.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? PP.accent : PP.line, lineWidth: selected ? 2 : 1))
        }
        .padItem(Self.modeID, hint: "Change", cornerRadius: 10,
                 reset: own ? {
                     ControllerMapAccess.resetToDefault(target, context: context) { ControllerMapAccess.save(nil, target) }
                 } : nil, ring: false) {
            setMode(modes[(modes.firstIndex(of: map.mode)! + 1) % modes.count])
        }
    }

    private func smallButton(_ id: String, _ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        let selected = focus.focused == id
        return Text(title).font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(selected ? PP.background : enabled ? PP.soft : PP.muted.opacity(0.6))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(selected ? PP.text : PP.surface, in: RoundedRectangle(cornerRadius: 10))
            .padItem(id, hint: enabled ? "Choose" : "", cornerRadius: 10, ring: false) { if enabled { action() } }
    }

    // MARK: the rows

    private func column(_ rows: [ControllerMapRow], _ map: ControllerMap, _ table: ControllerBindings) -> some View {
        VStack(spacing: 4) {
            ForEach(rows, id: \.self) { row in inputRow(row, map, table) }
            if rows.first?.isLeft == false {
                Text("HOME · PLAYPORT MENU").font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(PP.accent).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10).padding(.top, 2)
            }
        }
        .frame(width: 186)
    }

    @ViewBuilder
    private func inputRow(_ row: ControllerMapRow, _ map: ControllerMap, _ table: ControllerBindings) -> some View {
        let selected = focus.focused == row.itemID
        let custom = map.mode == .custom
        let changed = custom && ControllerMapEdit.differs(row, in: table)
        let content = HStack(spacing: 6) {
            Text(row.title).font(.system(size: 11.5)).foregroundStyle(selected ? Color(hex: 0x3A4452) : PP.muted)
                .frame(width: 44, alignment: .leading).lineLimit(1)
            if map.mode == .controller {
                // The game sees the pad as it is.
                Text("As the controller").font(.system(size: 11.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(selected ? PP.background : PP.muted)
            } else {
                ForEach(Array(row.caps(in: table).enumerated()), id: \.offset) { _, cap in
                    Text(cap).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                        .foregroundStyle(selected ? PP.background : PP.text)
                        .background(selected ? Color(hex: 0xD7DDE6) : PP.raised, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color(hex: 0x9AA5B4) : PP.line, lineWidth: 1))
                }
            }
            Spacer(minLength: 0)
            if changed { Circle().fill(PP.accent).frame(width: 7, height: 7) }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(selected ? PP.text : PP.surface, in: RoundedRectangle(cornerRadius: 9))
        .opacity(map.mode == .controller && !selected ? 0.6 : 1)
        content.padItem(row.itemID, hint: "Edit", cornerRadius: 9,
                        reset: changed ? { saveTable(ControllerMapEdit.reset(row, in: table)) } : nil, ring: false) {
            edit(row)
        }
    }

    private var lookSpeedRow: some View {
        let v = ControllerMapAccess.lookSpeed(target)
        let own = ControllerMapAccess.isOwnLookSpeed(target)
        let selected = focus.focused == Self.lookSpeedID
        let ends = (LookSpeed.step(v, by: -1) == v, LookSpeed.step(v, by: 1) == v)
        // Two lines, so it fits the narrow middle column whole (it was cut to "Look sp…" and
        // "Default…" on a phone: touch controls 3c): "Default" goes under the title.
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Look speed").font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("Mouse look" + (own || target == .defaults ? "" : " · Default")).font(.system(size: 10))
                    .foregroundStyle(selected ? Color(hex: 0x3A4452) : PP.muted).lineLimit(1)
            }
            .fixedSize()
            Spacer(minLength: 4)
            if own { Circle().fill(PP.accent).frame(width: 7, height: 7) }
            Text("‹").opacity(ends.0 ? 0.35 : 1).frame(minWidth: 18, minHeight: 30).contentShape(Rectangle())
                .onTapGesture { stepLookSpeed(-1) }
            Text(LookSpeed.label(v)).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                .accessibilityIdentifier("controller-look-speed-value")
            Text("›").opacity(ends.1 ? 0.35 : 1).frame(minWidth: 18, minHeight: 30).contentShape(Rectangle())
                .onTapGesture { stepLookSpeed(1) }
        }
        .foregroundStyle(selected ? PP.background : PP.text)
        .padding(.horizontal, 12).frame(height: 34)
        .background(selected ? PP.text : PP.surface, in: RoundedRectangle(cornerRadius: 9))
        .frame(maxWidth: 300)
        .padItem(Self.lookSpeedID, hint: "Change", cornerRadius: 9, adjust: stepLookSpeed,
                 reset: own ? { ControllerMapAccess.saveLookSpeed(nil, target) } : nil, ring: false) { pickLookSpeed() }
    }

    static func hint(_ mode: ControllerMap.Mode) -> String {
        switch mode {
        case .controller: "The game sees an Xbox controller. LB and RB change the mode; A on an input changes it in Custom."
        case .keyboardMouse: "Read only. A on an input edits it in a copy (Custom). LB and RB change the mode."
        case .custom: "A changes the ringed input, Y puts it back. LB and RB change the mode."
        }
    }

    // MARK: changes

    private func setMode(_ m: ControllerMap.Mode) {
        var map = ControllerMapAccess.map(target)
        guard m != map.mode else { return }
        map.mode = m
        ControllerMapAccess.save(map, target)
    }

    private func saveTable(_ t: ControllerBindings) {
        var map = ControllerMapAccess.map(target)
        map.mode = .custom
        map.custom = t
        ControllerMapAccess.save(map, target)
    }

    private func stepLookSpeed(_ by: Int) {
        let v = ControllerMapAccess.lookSpeed(target)
        let next = LookSpeed.step(v, by: by)
        if next != v { ControllerMapAccess.saveLookSpeed(next, target) }
    }

    private func pickLookSpeed() {
        let own = ControllerMapAccess.isOwnLookSpeed(target)
        let v = ControllerMapAccess.lookSpeed(target)
        let base: [PadOption] = target == .defaults ? []
            : [PadOption(id: "", label: "Default", detail: LookSpeed.label(store.defaults.lookSpeed) + ", from Settings")]
        PadModal.shared.picker(
            title: "Look speed", context: (context ?? "Settings") + " · Controller",
            note: "How fast a stick bound to mouse look turns the view. 1.0× is 2000 mouse counts a second.",
            options: base + LookSpeed.steps.map { PadOption(id: String($0), label: LookSpeed.label($0)) },
            selected: own || target == .defaults ? String(LookSpeed.steps[GyroSteps.nearest(v, in: LookSpeed.steps)]) : "") { id in
            ControllerMapAccess.saveLookSpeed(id.isEmpty ? nil : Double(id), target)
        }
    }

    /// Edit a copy (Keyboard & mouse): Custom with a copy of the preset, asking first over the player's own table.
    private func editCopy() {
        let map = ControllerMapAccess.map(target)
        guard ControllerMapConfirm.needed(for: map) else {
            return ControllerMapAccess.save(ControllerMapConfirm.copyPreset.apply("reset", to: map), target)
        }
        confirm(.copyPreset, map)
    }

    private func resetAll() {
        let map = ControllerMapAccess.map(target)
        guard ControllerMapConfirm.needed(for: map) else { return }
        confirm(.resetAll, map)
    }

    private func confirm(_ c: ControllerMapConfirm, _ map: ControllerMap) {
        PadModal.shared.picker(title: c.title, context: (context ?? "Settings") + " · Controller", note: c.note,
                               options: c.options.map { PadOption(id: $0.id, label: $0.label) },
                               selected: c.defaultChoice) { choice in
            switch c.outcome(choice, for: ControllerMapAccess.map(target)) {
            case .unchanged: break   // "Keep my changes": not even made the game's own
            case .save(let m): ControllerMapAccess.save(m, target)
            case .useDefault: ControllerMapAccess.save(nil, target)
            }
        }
    }

    /// A on an input row: in Custom its editor at once; else asked first (Edit a copy? Switch to
    /// Custom?), then its editor in Custom.
    private func edit(_ row: ControllerMapRow) {
        guard let c = ControllerMapConfirm.forEditing(ControllerMapAccess.map(target)) else { return change(row) }
        PadModal.shared.picker(title: c.title, context: (context ?? "Settings") + " · Controller · " + row.title, note: c.note,
                               options: c.options.map { PadOption(id: $0.id, label: $0.label) },
                               selected: c.defaultChoice) { choice in
            guard case .save(let m) = c.outcome(choice, for: ControllerMapAccess.map(target)) else { return }
            ControllerMapAccess.save(m, target)
            // Its editor once this list has closed.
            DispatchQueue.main.async { change(row) }
        }
    }

    /// In Custom: a stick's or the D-pad's list, else the ActionPicker at once.
    private func change(_ row: ControllerMapRow) {
        let table = ControllerMapAccess.map(target).custom
        guard let parts = ControllerMapEdit.parts(row, in: table) else { return pick(.control(row.pad!)) }
        PadModal.shared.picker(
            title: row.title, context: (context ?? "Settings") + " · Controller",
            note: row.stick == nil ? "Each direction does its own." : "Whole: the stick moves the mouse or a pad's stick. "
                + "Four directions: each presses a key or a button, past half way.",
            options: parts.map { PadOption(id: $0.id, label: $0.label, detail: $0.detail) },
            selected: Set(parts.filter(\.on).map(\.id))) { id in
            guard let part = parts.first(where: { $0.id == id }) else { return }
            let now = ControllerMapAccess.map(target).custom
            let (t, input) = ControllerMapEdit.choose(part, of: row, in: now)
            if let input { return pick(input) }
            saveTable(t)
            // The stick's list again, with its new parts.
            DispatchQueue.main.async { change(row) }
        }
    }

    private func pick(_ input: ControllerInput) {
        let table = ControllerMapAccess.map(target).custom
        let picker = ActionPicker(for: input, title: ControllerMapEdit.pickerTitle(input), current: table[input],
                                  recent: ActionPickerRecent.load(.standard))
        PadModal.shared.actionPicker(picker) { action in
            guard let t = ControllerMapEdit.setting(input, action, in: ControllerMapAccess.map(target).custom) else { return }
            saveTable(t)
            if let action { ActionPickerRecent.save(ActionPickerRecent.adding(action, to: ActionPickerRecent.load(.standard)), .standard) }
        }
    }
}

/// The presses on the Controller page, from the shell or (over a paused game) the in-game
/// menu: the directions move the ring (ControllerMapNav, through `moves`), LB and RB cycle
/// the mode (`modeSteps`), A edits the ringed item, Y resets it, B goes back. X, View and
/// Menu do nothing here.
@MainActor
enum ControllerMapRing {
    /// A direction for the page's ring.
    static let moves = PassthroughSubject<FocusDirection, Never>()
    /// LB (-1) or RB (+1): the mode before or after.
    static let modeSteps = PassthroughSubject<Int, Never>()

    /// Whether the page is up (over a game's page, or in Settings' place).
    static var isUp: Bool {
        let nav = AppNavigation.shared
        return (nav.settings && nav.settingsControllerMap && !nav.signIn) || (nav.onGamePage && nav.gamePanels.last == .controller)
    }

    /// The shell's press, when the page is up: true when it was the page's (every press is).
    static func press(_ b: NavButton) -> Bool {
        guard isUp else { return false }
        pagePress(b) { _ = AppNavigation.shared.back() }
        return true
    }

    /// A press on the page (no picker over it); B does `back`.
    static func pagePress(_ b: NavButton, back: () -> Void) {
        switch b {
        case .up: moves.send(.up)
        case .down: moves.send(.down)
        case .left: moves.send(.left)
        case .right: moves.send(.right)
        case .lb: modeSteps.send(-1)
        case .rb: modeSteps.send(1)
        case .a: PadFocus.shared.activate()
        case .y: PadFocus.shared.resetFocused()
        case .b: back()
        case .x, .view, .menu: break
        }
    }

    /// The footer: A on the ringed item, Y back to the default or the preset, B back.
    static var hints: [PadHint] { hints { _ = AppNavigation.shared.back() } }

    /// The same, with B doing `back` (over a paused game: back to the in-game menu's panel).
    static func hints(back: @escaping () -> Void) -> [PadHint] {
        let focus = PadFocus.shared
        var h: [PadHint] = []
        if let a = focus.hint, !a.isEmpty { h.append(PadHint(button: .a, label: a) { focus.activate() }) }
        h.append(PadHint(button: .lb, label: "Mode", action: { modeSteps.send(1) }, also: .rb))
        if focus.canReset {
            let row = focus.focused.flatMap(ControllerMapRow.init(itemID:)) != nil
            h.append(PadHint(button: .y, label: row ? "Reset row" : "Back to default") { focus.resetFocused() })
        }
        h.append(PadHint(button: .b, label: "Back", action: back))
        return h
    }
}

/// The controller's picture (ControllerMapping.dc.html), its ringed input amber.
struct PadPicture: View {
    let lit: ControllerMapRow?
    let mode: ControllerMap.Mode

    var body: some View {
        Canvas { ctx, size in
            // The board's drawing is 300 × 200 pt.
            let s = min(size.width / 304, size.height / 200)
            ctx.translateBy(x: (size.width - 304 * s) / 2 + 2 * s, y: (size.height - 200 * s) / 2)
            ctx.scaleBy(x: s, y: s)
            let line = Color(hex: 0x3A4452), fill = Color(hex: 0x1D242E), edge = Color(hex: 0x4A5566)
            func on(_ r: ControllerMapRow) -> Bool { lit == r }
            func rect(_ r: CGRect, _ row: ControllerMapRow, radius: CGFloat = 6) {
                let p = Path(roundedRect: r, cornerRadius: radius)
                ctx.fill(p, with: .color(on(row) ? PP.accent : fill))
                ctx.stroke(p, with: .color(on(row) ? PP.accent : line), lineWidth: 1.5)
            }
            rect(CGRect(x: 58, y: 2, width: 56, height: 16), .lt)
            rect(CGRect(x: 186, y: 2, width: 56, height: 16), .rt)
            rect(CGRect(x: 50, y: 16, width: 76, height: 14), .lb)
            rect(CGRect(x: 174, y: 16, width: 76, height: 14), .rb)
            var body = Path()
            body.move(to: CGPoint(x: 70, y: 30))
            body.addQuadCurve(to: CGPoint(x: 230, y: 30), control: CGPoint(x: 150, y: 20))
            body.addCurve(to: CGPoint(x: 292, y: 112), control1: CGPoint(x: 262, y: 34), control2: CGPoint(x: 282, y: 62))
            body.addCurve(to: CGPoint(x: 262, y: 194), control1: CGPoint(x: 302, y: 164), control2: CGPoint(x: 290, y: 196))
            body.addCurve(to: CGPoint(x: 210, y: 150), control1: CGPoint(x: 238, y: 192), control2: CGPoint(x: 226, y: 166))
            body.addLine(to: CGPoint(x: 90, y: 150))
            body.addCurve(to: CGPoint(x: 38, y: 194), control1: CGPoint(x: 74, y: 166), control2: CGPoint(x: 62, y: 192))
            body.addCurve(to: CGPoint(x: 8, y: 112), control1: CGPoint(x: 10, y: 196), control2: CGPoint(x: -2, y: 164))
            body.addCurve(to: CGPoint(x: 70, y: 30), control1: CGPoint(x: 18, y: 62), control2: CGPoint(x: 38, y: 34))
            body.closeSubpath()
            ctx.fill(body, with: .color(PP.surface))
            ctx.stroke(body, with: .color(line), lineWidth: 2)
            func stick(_ c: CGPoint, _ r: CGFloat, _ row: ControllerMapRow, thumb: ControllerMapRow) {
                let outer = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(outer, with: .color(PP.background))
                ctx.stroke(outer, with: .color(on(row) ? PP.accent : line), lineWidth: on(row) ? 2.5 : 1.5)
                let ir = r * 0.6
                let inner = Path(ellipseIn: CGRect(x: c.x - ir, y: c.y - ir, width: 2 * ir, height: 2 * ir))
                ctx.fill(inner, with: .color(on(thumb) ? PP.accent : fill))
                ctx.stroke(inner, with: .color(edge), lineWidth: 1)
            }
            stick(CGPoint(x: 84, y: 80), 23, .leftStick, thumb: .ls)
            stick(CGPoint(x: 190, y: 124), 21, .rightStick, thumb: .rs)
            var cross = Path()
            cross.move(to: CGPoint(x: 104, y: 116))
            for (dx, dy) in [(10, 0), (0, -10), (10, 0), (0, 10), (10, 0), (0, 10), (-10, 0), (0, 10), (-10, 0), (0, -10), (-10, 0)] {
                cross.addLine(to: CGPoint(x: (cross.currentPoint?.x ?? 0) + CGFloat(dx), y: (cross.currentPoint?.y ?? 0) + CGFloat(dy)))
            }
            cross.closeSubpath()
            ctx.fill(cross, with: .color(on(.dpad) ? PP.accent : fill))
            ctx.stroke(cross, with: .color(edge), lineWidth: 1.2)
            rect(CGRect(x: 126, y: 70, width: 14, height: 9), .back, radius: 3)
            rect(CGRect(x: 160, y: 70, width: 14, height: 9), .start, radius: 3)
            // Home: Playport's, always amber-edged.
            let home = Path(ellipseIn: CGRect(x: 141, y: 43, width: 18, height: 18))
            ctx.fill(home, with: .color(fill))
            ctx.stroke(home, with: .color(PP.accent), lineWidth: 1.2)
            for (row, c, colour) in [(ControllerMapRow.y, CGPoint(x: 222, y: 62), Color(hex: 0xF7D766)),
                                     (.x, CGPoint(x: 204, y: 80), Color(hex: 0x86B9FF)),
                                     (.b, CGPoint(x: 240, y: 80), Color(hex: 0xFF8E80)),
                                     (.a, CGPoint(x: 222, y: 98), Color(hex: 0x7FD08A))] {
                let p = Path(ellipseIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18))
                ctx.fill(p, with: .color(on(row) ? PP.accent : fill))
                ctx.stroke(p, with: .color(edge), lineWidth: 1)
                ctx.draw(Text(row.title).font(.system(size: 10, weight: .bold)).foregroundColor(on(row) ? PP.onAccent : colour),
                         at: c)
            }
        }
        .opacity(mode == .controller ? 0.7 : 1)
        .accessibilityIdentifier("controller-picture")
    }
}
