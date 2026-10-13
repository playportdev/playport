// SPDX-License-Identifier: GPL-3.0-or-later
// The controls' and gyro aim's settings screens (docs/design/2026-10-09-touch-controls:
// GameOptionsControls.dc.html, GyroAim.dc.html):
//
// - GameControlsOptionRows: Game options' Controls section, the game's own
//   on-screen controls (layout, d-pad, right stick, opacity) and the entries to
//   its Controller page (UI/ControllerMapView.swift) and its Gyro aim page. Each shows "Default · X" while it follows Settings ›
//   Controls, the amber dot while the game sets it, and Y puts it back.
// - GyroAimPanel: Game options › Controls › Gyro aim (AppRoutes.GamePanel.gyro),
//   the game's own gyro aim (PlayportKit GyroRow), over Game options.
// - GyroTestArea: beside it, the dot that follows the aim. While the page is
//   up and no game runs, GyroSensors runs the sensors for it (GyroRun.previewing)
//   through the same GyroAim, and the output reaches only the dot, never a guest
//   (GyroFeed.process in preview); the page going, or the app leaving the front,
//   stops them.
// - GyroDefaultsRows: Settings › Controls › Gyro aim, the `gyro.*` defaults.
//
// Every change applies at once (ControlsStore), in a running game too.

import HostIOKit
import PlayportKit
import SwiftUI

// MARK: Game options › Controls

struct GameControlsOptionRows: View {
    let titleID: String
    /// The game's name, the pickers' context.
    let context: String
    @ObservedObject private var store = ControlsStore.shared
    @ObservedObject private var navigation = AppNavigation.shared

    var body: some View {
        let own = store.game(titleID)
        let inherited = ControlsState.resolve(game: nil, defaults: store.defaults, controllerConnected: false)
        PadSectionHeader(text: "Controls").id("controls")
        choiceRow("opt:layout", "On-screen controls", \.layout, all: OnScreenLayout.allCases, inherited: inherited.layout,
                  name: \.title, detail: "Shown while no controller is connected")
        choiceRow("opt:dpad", "D-pad", \.dpad, all: OnScreenDpad.allCases, inherited: inherited.dpad, name: \.title,
                  detail: "Above the left stick")
        choiceRow("opt:rightStick", "Right stick", \.rightStick, all: OnScreenRightStick.allCases,
                  inherited: inherited.rightStick, name: \.title, detail: "Beside A/B/X/Y")
        let opacity = OptionValue.of(own: own.opacity, inherited: inherited.opacity, name: ControlsOpacity.label)
        PadRow(id: "opt:opacity", title: "Opacity", value: opacity.text, accessory: .chevron, changed: opacity.changed,
               style: .plain, reset: opacity.changed ? { set { $0.opacity = nil } } : nil) {
            PadModal.shared.picker(
                title: "Opacity", context: "\(context) · Controls", note: Self.note,
                options: [PadOption(id: "", label: "Default", detail: ControlsOpacity.label(inherited.opacity) + ", from Settings")]
                    + ControlsOpacity.steps.map { PadOption(id: String($0), label: ControlsOpacity.label($0)) },
                selected: own.opacity.map { String(ControlsOpacity.step($0, by: 0)) } ?? "") { id in set { $0.opacity = Double(id) } }
        }
        // The Controller page (UI/ControllerMapView.swift): the game's controller map and its look speed.
        // The dot and Y for its own map or look speed; "Default ·" while the mode is Settings'.
        let ownMap = own.controllerMap != nil || own.lookSpeed != nil
        PadRow(id: ControllerMapView.gameRowID, title: "Controller", subtitle: nil,
               value: (own.controllerMap == nil ? "Default · " : "") + own.controllerMap(over: store.defaults).mode.title,
               accessory: .chevron, changed: ownMap, style: .plain, hint: "Open",
               reset: ownMap ? {
                   ControllerMapAccess.resetToDefault(.game(titleID), context: context) {
                       set { $0.controllerMap = nil; $0.lookSpeed = nil }
                   }
               } : nil) {
            navigation.gamePanels.append(.controller)
        }
        let gyro = store.gyro(titleID)
        PadRow(id: "opt:gyro", title: "Gyro aim", value: GyroText.summary(gyro), accessory: .chevron, changed: own.gyro != nil,
               style: .plain, hint: "Open", reset: own.gyro == nil ? nil : { set { $0.gyro = nil } }) {
            navigation.gamePanels.append(.gyro)
        }
    }

    static let note = "For this game, at once, in a game too."

    private func set(_ change: (inout GameControls) -> Void) {
        var c = store.game(titleID)
        change(&c)
        store.setGame(titleID, c)
    }

    private func choiceRow<T: RawRepresentable & CaseIterable & Equatable>(
        _ id: String, _ title: String, _ key: WritableKeyPath<GameControls, T?>, all: [T], inherited: T,
        name: KeyPath<T, String>, detail: String
    ) -> some View where T.RawValue == String {
        let own = store.game(titleID)[keyPath: key]
        let v = OptionValue.of(own: own, inherited: inherited, name: { $0[keyPath: name] })
        return PadRow(id: id, title: title, value: v.text, accessory: .chevron, changed: v.changed, style: .plain,
                      reset: v.changed ? { set { $0[keyPath: key] = nil } } : nil) {
            PadModal.shared.picker(
                title: title, context: "\(context) · Controls", note: detail + ". " + Self.note,
                options: [PadOption(id: "", label: "Default", detail: inherited[keyPath: name] + ", from Settings")]
                    + all.map { PadOption(id: $0.rawValue, label: $0[keyPath: name]) },
                selected: own?.rawValue ?? "") { choice in set { $0[keyPath: key] = T(rawValue: choice) } }
        }
    }
}

// MARK: Game options › Controls › Gyro aim

/// The page's rows, at the right where Game options was (GyroAim.dc.html).
struct GyroAimPanel: View {
    let titleID: String
    let context: String
    @ObservedObject private var store = ControlsStore.shared
    @ObservedObject private var sensors = GyroSensors.shared
    @ObservedObject private var focus = PadFocus.shared

    var body: some View {
        let own = store.game(titleID).gyro
        let now = store.gyro(titleID)
        let defaults = store.gyroDefaults
        VStack(alignment: .leading, spacing: 2) {
            Text("\(context) · Controls").font(.system(size: 12)).foregroundStyle(PP.muted)
                .padding(.horizontal, 14)
            Text("Gyro aim").font(PP.display(22)).foregroundStyle(PP.text)
                .padding(.horizontal, 14).padding(.bottom, 2)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(GyroRow.allCases.filter { $0.isShown(in: now) }, id: \.self) { row in
                            gyroRow(row, own: own, now: now, defaults: defaults)
                        }
                        PadRow(id: "gyro:calibration", title: "Calibration", value: "Automatic · when still", style: .plain,
                               hint: "") {}
                    }
                    .padding(.bottom, 18)
                }
                .onChange(of: focus.focused) { _, id in
                    guard let id, id.hasPrefix("gyro:"), id != GyroTestArea.itemID else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
            }
        }
        .padding(.top, 18).padding(.leading, 20).padding(.trailing, 28)
    }

    @ViewBuilder
    private func gyroRow(_ row: GyroRow, own: GameGyro?, now: GyroSettings, defaults: GyroSettings) -> some View {
        let id = "gyro:" + row.rawValue
        let changed = row.isSet(in: own)
        let reset: (() -> Void)? = changed ? { save(row.cleared(own)) } : nil
        if row.isSwitch {
            let on = row.id(in: now) == "true"
            PadRow(id: id, title: row.title, accessory: .toggle(on), changed: changed, style: .plain,
                   hint: on ? "Turn off" : "Turn on", reset: reset) {
                // Back to following the default when that is what it becomes.
                let next = String(!on)
                save(next == row.id(in: defaults) ? row.cleared(own) : row.setting(next, in: own))
            }
        } else {
            let text: (value: String, why: String?) = row == .source ? GyroText.sourceInUse(now.source, device: sensors.device(for: now)) : (row.text(now), nil)
            PadRow(id: id, title: row.title, subtitle: text.why ?? Self.subtitle(row),
                   value: changed ? text.value : "Default · " + text.value, accessory: .chevron, changed: changed,
                   style: .plain, reset: reset,
                   adjust: row.isNumber ? { by in save(row.setting(row.step(now, by: by), in: own)) } : nil) {
                PadModal.shared.picker(
                    title: row.title, context: "\(context) · Gyro aim", note: GameControlsOptionRows.note,
                    options: [PadOption(id: "", label: "Default", detail: row.text(defaults) + ", from Settings")]
                        + row.choices.map { PadOption(id: $0.id, label: $0.label, detail: Self.detail(row, $0.id)) },
                    selected: changed ? row.choices[row.index(in: now)].id : "") { choice in
                    save(row.setting(choice.isEmpty ? nil : choice, in: own))
                }
            }
        }
    }

    private func save(_ gyro: GameGyro?) {
        var c = store.game(titleID)
        c.gyro = gyro
        store.setGame(titleID, c)
    }

    /// The grey line under a row.
    static func subtitle(_ row: GyroRow) -> String? {
        switch row {
        case .output: "Always on while chosen: no button to hold"
        case .pauseButton: "Held, the aim stops (to recentre)"
        case .sensitivity: "Left and right change it"
        case .antiDeadZone: "Where the stick starts: past the game's own dead zone"
        case .turnAxis: "Player space works however you hold it"
        default: nil
        }
    }

    /// A choice's grey text in the picker.
    static func detail(_ row: GyroRow, _ id: String) -> String? {
        switch (row, id) {
        case (.output, "mouse"): "For games that aim with the mouse"
        case (.output, "rightStick"): "For games that read only a controller"
        case (.antiDeadZone, "0.0"): "The stick starts at rest"
        case (.antiDeadZone, "0.27"): "XInput's dead zone: most games"
        case (.source, "auto"): "A controller's gyro when it has one, else the iPhone's"
        case (.source, "controller"): "DualSense, DualShock 4 and others with a gyro"
        case (.turnAxis, "playerSpace"): "Turns about the world's up, however you hold it"
        case (.turnAxis, "yaw"): "Turns about the device's own up"
        case (.turnAxis, "roll"): "Turns like a steering wheel"
        default: nil
        }
    }
}

/// The dot that follows the aim (GyroAim.dc.html's "Try it"): runs the sensors
/// for itself while it is on screen and no game runs, with `target`'s settings.
struct GyroTestArea: View {
    static let itemID = "gyro:test"
    let target: GyroPreviewTarget
    @ObservedObject private var sensors = GyroSensors.shared
    @ObservedObject private var store = ControlsStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let settings: GyroSettings = switch target {
        case .game(let id): store.gyro(id)
        case .defaults: store.gyroDefaults
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("TRY IT · THE DOT IS YOUR AIM").font(.system(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(PP.muted)
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(PP.background)
                RoundedRectangle(cornerRadius: 14).stroke(PP.line, lineWidth: 1)
                // The middle: where the dot starts, and where a tap brings it back.
                Circle().stroke(PP.text.opacity(0.4), lineWidth: 1.5).frame(width: 40, height: 40)
                Circle().stroke(PP.text.opacity(0.6), lineWidth: 1.5).frame(width: 10, height: 10)
                if case .previewing = sensors.run {
                    TimelineView(.animation) { _ in
                        let p = sensors.feed.preview
                        GeometryReader { geo in
                            let w = geo.size.width / 2 - 12, h = geo.size.height / 2 - 12
                            Circle().fill(PP.accent).frame(width: 14, height: 14).shadow(color: PP.accent, radius: 7)
                                .position(x: geo.size.width / 2 + p.dot.x * w, y: geo.size.height / 2 - p.dot.y * h)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            // The bias learnt while still (GyroAim's calibration).
                            Text(p.calibrated ? "● Calibrated" : "Hold still a moment to calibrate")
                                .font(.system(size: 10)).foregroundStyle(p.calibrated ? PP.ok : PP.muted)
                                .padding(8)
                        }
                    }
                } else {
                    Text(status(settings)).font(.system(size: 13)).foregroundStyle(PP.soft).multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .frame(maxHeight: .infinity)
            .padItem(Self.itemID, hint: "Centre", cornerRadius: 14) { sensors.feed.centreDot() }
            .accessibilityIdentifier("gyro-test-area")
            Text(hint(settings)).font(.system(size: 12)).foregroundStyle(PP.muted).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(PP.raised, lineWidth: 1))
        .onAppear { sensors.preview(target, active: scenePhase == .active) }
        .onDisappear { sensors.preview(nil, active: true) }
        .onChange(of: scenePhase) { _, phase in sensors.preview(target, active: phase == .active) }
    }

    /// Why the dot is not shown.
    private func status(_ s: GyroSettings) -> String {
        if s.output == .off { return "Gyro aim is off. Choose Mouse or Right stick to try it." }
        if let why = GyroText.sourceInUse(s.source, device: sensors.device(for: s)).why { return why + "." }
        return "Starting…"
    }

    private func hint(_ s: GyroSettings) -> String {
        switch s.output {
        case .rightStick: "Turn to push the stick: the dot comes back to the middle when you stop. Tap to centre."
        default: "Turn to move across, tilt to move up and down. Tap to centre. It calibrates itself while you hold still."
        }
    }
}

// MARK: Settings › Controls › Gyro aim

/// What every game's gyro aim follows unless its Game options change it.
struct GyroDefaultsRows: View {
    @ObservedObject private var store = ControlsStore.shared
    @ObservedObject private var sensors = GyroSensors.shared

    var body: some View {
        let d = store.gyroDefaults
        PadSectionHeader(text: "Gyro aim").id("set:gyro")
        ForEach(GyroRow.allCases.filter { $0.isShown(in: d) }, id: \.self) { row in
            if row.isSwitch {
                SettingsSwitchRow(id: Self.id(row), title: row.title, subtitle: nil,
                                  on: Binding(get: { row.id(in: store.gyroDefaults) == "true" },
                                              set: { UserDefaults.standard.set($0, forKey: row.key) }))
            } else {
                let choices = row.choices
                let i = row.index(in: d)
                // A number between the steps (from the driver's set:) shows as itself.
                let labels = choices.indices.map { $0 == i ? row.text(d) : choices[$0].label }
                let source = GyroText.sourceInUse(d.source, device: sensors.device(for: d))
                PadValueRow(id: "set:" + Self.id(row), title: row.title,
                            subtitle: row == .source ? source.why ?? "Now: " + source.value : GyroAimPanel.subtitle(row),
                            values: labels, index: i) {
                    UserDefaults.standard.set(row.stored(choices[$0].id), forKey: row.key)
                }
            }
        }
        SettingsNote(text: "Gyro aim turns the view as you turn the phone or a controller with a gyro, and is always on "
                     + "while chosen. Each game can change these in its Game options › Controls › Gyro aim, which has "
                     + "a test area, or turn it on and change its sensitivity in the in-game menu's Controls.")
    }

    /// `gyroOutput`, `gyroInvertX`: the row's driver id after `set:`.
    static func id(_ row: GyroRow) -> String {
        "gyro" + row.rawValue.prefix(1).uppercased() + row.rawValue.dropFirst()
    }
}
