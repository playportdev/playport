// SPDX-License-Identifier: GPL-3.0-or-later
// The ActionPicker over a screen (docs/design/2026-10-09-touch-controls/ActionPicker.dc.html;
// PlayportKit ActionPicker.swift): what one input does. A PadModal: it takes
// every press while it is up and draws its own footer.
//
// - LB and RB switch the tabs (Keyboard, Mouse, Controller, Playport), the
//   D-pad moves over the cells, A chooses (or turns a modifier chip on or
//   off), B goes back unchanged. Every cell, chip and tab is a tap too.
// - X, Press a real key: the next key of a hardware keyboard is chosen, with
//   the modifiers held (and the chips on). A UIKit view takes the keyboard's
//   presses (pressesBegan) only while it waits, and maps them through KeyMap.
// - The Controller page opens it (UI/ControllerMapView.swift); phase 5's
//   layout editor will open it for an on-screen control.

import HostIOKit
import PlayportKit
import SwiftUI
import UIKit

@MainActor
final class ActionPickerSession: ObservableObject {
    @Published private(set) var model: ActionPicker
    private let choose: (InputAction?) -> Void

    init(_ model: ActionPicker, choose: @escaping (InputAction?) -> Void) {
        self.model = model
        self.choose = choose
    }

    func press(_ b: NavButton) {
        switch b {
        case .up: model.move(.up)
        case .down: model.move(.down)
        case .left: model.move(.left)
        case .right: model.move(.right)
        case .lb: model.switchTab(by: -1)
        case .rb: model.switchTab(by: 1)
        case .a: finish(model.choose())
        case .x: model.listen(!model.listening)
        case .b:
            if model.listening { model.listen(false) } else { PadModal.shared.close() }
        default: break
        }
    }

    func tap(row: Int, column: Int) { finish(model.tap(row: row, column: column)) }

    func select(_ tab: ActionPickerTab) { model.select(tab) }

    /// A hardware key (while listening).
    func realKey(_ action: InputAction) { finish(model.realKey(action)) }

    private func finish(_ o: ActionPicker.Outcome) {
        guard case .chosen(let a) = o else { return }
        PadModal.shared.close()
        choose(a)
    }
}

struct ActionPickerView: View {
    @ObservedObject var session: ActionPickerSession

    var body: some View {
        let m = session.model
        ZStack {
            Color(hex: 0x05070A).opacity(0.78).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { session.press(.b) }
            VStack(spacing: 8) {
                panel(m).frame(maxWidth: 660)
                HStack(spacing: 18) {
                    Spacer(minLength: 0)
                    PadModalHint(button: .a, label: "Choose") { session.press(.a) }
                    if m.tabs.contains(.keyboard) {
                        PadModalHint(button: .x, label: m.listening ? "Stop waiting" : "Press a real key") { session.press(.x) }
                    }
                    PadModalHint(button: .b, label: "Back") { session.press(.b) }
                }
                .frame(height: 36)
            }
            .padding(.horizontal, 44).padding(.top, 10)
            // The hardware keyboard, only while it waits for a key.
            RealKeyCaptureView(listening: m.listening) { session.realKey($0) }
                .frame(width: 1, height: 1).allowsHitTesting(false)
        }
        .accessibilityIdentifier("action-picker")
    }

    private func panel(_ m: ActionPicker) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.title).font(PP.display(20)).foregroundStyle(PP.text).lineLimit(1)
                Spacer(minLength: 8)
                Text("Now:").font(.system(size: 12)).foregroundStyle(PP.muted)
                cap(ActionText.name(m.current), on: false)
            }
            HStack(spacing: 10) {
                Button { session.press(.lb) } label: { PadGlyph(button: .lb) }.buttonStyle(.plain)
                HStack(spacing: 2) {
                    ForEach(m.tabs, id: \.self) { t in
                        Text(t.title).font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(t == m.tab ? PP.background : PP.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(t == m.tab ? PP.text : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                            .onTapGesture { session.select(t) }
                            .accessibilityIdentifier("action-tab-\(t.rawValue)")
                    }
                }
                .padding(2)
                .background(PP.background, in: RoundedRectangle(cornerRadius: 10))
                Button { session.press(.rb) } label: { PadGlyph(button: .rb) }.buttonStyle(.plain)
            }
            if m.listening {
                Text("Press a key on the keyboard…").font(.system(size: 15, weight: .medium)).foregroundStyle(PP.accent)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(PP.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("action-listening")
            } else {
                grid(m)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(PP.line, lineWidth: 1))
    }

    private func grid(_ m: ActionPicker) -> some View {
        let rows = m.rows
        let bottom = rows.last?.contains { $0.id.hasPrefix("mod:") || $0.id.hasPrefix("recent:") } ?? false
        return VStack(spacing: 4) {
            ForEach(rows.indices, id: \.self) { r in
                if bottom && r == rows.count - 1 {
                    bottomRow(m, rows[r], row: r)
                } else {
                    GeometryReader { geo in
                        let total = rows[r].reduce(0) { $0 + $1.width }
                        let unit = (geo.size.width - 4 * CGFloat(rows[r].count - 1)) / total
                        HStack(spacing: 4) {
                            ForEach(rows[r].indices, id: \.self) { c in
                                key(rows[r][c], on: m.row == r && m.column == c, chip: false)
                                    .frame(width: unit * rows[r][c].width)
                                    .onTapGesture { session.tap(row: r, column: c) }
                            }
                        }
                    }
                    .frame(height: 25)
                }
            }
        }
    }

    /// The modifier chips and the recent choices (ActionPicker.dc.html's last line).
    private func bottomRow(_ m: ActionPicker, _ cells: [ActionPickerCell], row r: Int) -> some View {
        HStack(spacing: 6) {
            if cells.contains(where: { $0.id.hasPrefix("mod:") }) { Text("With").font(.system(size: 12.5)).foregroundStyle(PP.muted) }
            ForEach(cells.indices, id: \.self) { c in
                if cells[c].id == "recent:0" {
                    Spacer(minLength: 8)
                    Text("Recent").font(.system(size: 12.5)).foregroundStyle(PP.muted)
                }
                key(cells[c], on: m.row == r && m.column == c, chip: true, lit: Self.isOn(cells[c], m))
                    .fixedSize()
                    .onTapGesture { session.tap(row: r, column: c) }
            }
            if !cells.contains(where: { $0.id.hasPrefix("recent:") }) { Spacer(minLength: 0) }
        }
        .frame(height: 26)
    }

    private static func isOn(_ c: ActionPickerCell, _ m: ActionPicker) -> Bool {
        if case .modifier(let mod) = c.kind { return m.modifiers.contains(mod) }
        return false
    }

    private func key(_ c: ActionPickerCell, on: Bool, chip: Bool, lit: Bool = false) -> some View {
        Text(c.label).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
            .foregroundStyle(on ? PP.background : lit ? PP.onAccent : PP.soft)
            .padding(.horizontal, chip ? 10 : 2)
            .frame(maxWidth: chip ? nil : .infinity, maxHeight: .infinity)
            .background(on ? PP.text : lit ? PP.accent : PP.raised, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? PP.accent : PP.line, lineWidth: on ? 2.5 : 1))
            .contentShape(Rectangle())
            .accessibilityIdentifier("action-\(c.id)")
    }

    private func cap(_ s: String, on: Bool) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold)).foregroundStyle(PP.text)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(PP.raised, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(PP.line, lineWidth: 1))
    }
}

/// Takes a hardware keyboard's presses while `listening`: first responder then,
/// every key through KeyMap with the modifiers held (RealKeyCapture).
struct RealKeyCaptureView: UIViewRepresentable {
    let listening: Bool
    let chosen: (InputAction) -> Void

    func makeUIView(context: Context) -> KeyCaptureView {
        let v = KeyCaptureView()
        v.chosen = chosen
        return v
    }

    func updateUIView(_ v: KeyCaptureView, context: Context) {
        v.chosen = chosen
        v.listening = listening
    }

    final class KeyCaptureView: UIView {
        var chosen: ((InputAction) -> Void)?
        private var capture = RealKeyCapture()
        var listening = false {
            didSet {
                guard listening != oldValue else { return }
                capture = RealKeyCapture()
                // On the next turn: the view may not be in a window yet.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.listening { _ = self.becomeFirstResponder() } else if self.isFirstResponder { _ = self.resignFirstResponder() }
                }
            }
        }

        override var canBecomeFirstResponder: Bool { listening }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard listening else { return super.pressesBegan(presses, with: event) }
            for p in presses {
                guard let k = p.key, let vk = KeyMap.virtualKey(hidUsage: k.keyCode.rawValue) else { continue }
                var held: KeyModifiers = []
                if k.modifierFlags.contains(.shift) { held.insert(.shift) }
                if k.modifierFlags.contains(.control) { held.insert(.control) }
                if k.modifierFlags.contains(.alternate) { held.insert(.alt) }
                if let a = capture.down(vk, held: held) { chosen?(a) }
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard listening else { return super.pressesEnded(presses, with: event) }
            for p in presses {
                guard let k = p.key, let vk = KeyMap.virtualKey(hidUsage: k.keyCode.rawValue) else { continue }
                if let a = capture.up(vk) { chosen?(a) }
            }
        }
    }
}
