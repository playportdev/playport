// SPDX-License-Identifier: GPL-3.0-or-later
// The controller keyboard: an on-screen keyboard across the bottom of the
// screen, for search and launch arguments, typed with the pad or by touch.
// Its keys, cursor and text are PlayportKit.PadKeyboard; this file draws
// them and maps the buttons:
//
//   D-pad   move between keys (sideways wraps)     A   type the key
//   B       delete (close when there is nothing)   X   space
//   Y       Shift                                   LB/RB  move the caret
//   ≡       Done
//
// Every close keeps the text: the modal's `done` gets it. A password's
// keyboard draws dots and keeps its text out of the driver's log
// (`Privacy.secret`); an account name's keeps it out of the log only.

import HostIOKit
import PlayportKit
import SwiftUI

@MainActor
final class PadKeyboardSession: ObservableObject {
    /// Who sees the text: the screen and the driver's log, the screen only,
    /// or neither (dots on the screen: a password).
    enum Privacy: String { case shown, hidden, secret }

    let title: String
    let placeholder: String
    let privacy: Privacy
    @Published private(set) var state: PadKeyboard
    private let changed: ((String) -> Void)?
    private let done: (String) -> Void

    init(title: String, text: String, placeholder: String, maxLength: Int, privacy: Privacy = .shown,
         changed: ((String) -> Void)?, done: @escaping (String) -> Void) {
        self.title = title
        self.placeholder = placeholder
        self.privacy = privacy
        state = PadKeyboard(text: text, maxLength: maxLength)
        self.changed = changed
        self.done = done
    }

    var keyName: String { Self.label(state.key) }

    func press(_ b: NavButton) {
        switch b {
        case .up: state.move(.up)
        case .down: state.move(.down)
        case .left: state.move(.left)
        case .right: state.move(.right)
        case .a: key(state.key)
        case .b: if state.text.isEmpty { finish() } else { edit { $0.backspace() } }
        case .x: key(.space)
        case .y: key(.shift)
        case .lb: state.moveCaret(by: -1)
        case .rb: state.moveCaret(by: 1)
        case .menu: finish()
        case .view: break
        }
    }

    /// A key pressed, with A or by a tap.
    func key(_ k: PadKey) {
        if state.press(k) == .done { return finish() }
        report()
    }

    func tap(row: Int, column: Int) {
        state.focus(row: row, column: column)
        key(state.key)
    }

    func finish() {
        let text = state.string
        PadModal.shared.close()
        done(text)
    }

    private func edit(_ f: (inout PadKeyboard) -> Void) {
        f(&state)
        report()
    }

    /// The text `changed` last saw; a Shift or a caret move does not call it.
    private lazy var last = state.string
    private func report() {
        let now = state.string
        guard now != last else { return }
        last = now
        changed?(now)
    }

    static func label(_ k: PadKey) -> String {
        switch k {
        case .char(let c): String(c)
        case .shift: "⇧"
        case .symbols: "?123"
        case .backspace: "⌫"
        case .space: "space"
        case .done: "Done"
        }
    }
}

struct PadKeyboardView: View {
    @ObservedObject var session: PadKeyboardSession

    private static let keyHeight: CGFloat = 28
    private static let gap: CGFloat = 5
    private static let maxUnit: CGFloat = 60

    var body: some View {
        ZStack(alignment: .bottom) {
            // Outside the keyboard: dimmed a little, and a tap there is Done.
            Color.black.opacity(0.35).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { session.finish() }
            VStack(spacing: 0) {
                field.padding(.top, 8).padding(.bottom, 6)
                keys
                footer
            }
            .frame(maxWidth: .infinity)
            .background {
                PP.surface
                    .overlay(alignment: .top) { Rectangle().fill(PP.line).frame(height: 1) }
                    .ignoresSafeArea(edges: [.horizontal, .bottom])
            }
        }
        .accessibilityIdentifier("pad-keyboard")
    }

    // MARK: the text

    private var field: some View {
        let s = session.state
        return HStack(spacing: 8) {
            Text(session.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(PP.muted)
            HStack(spacing: 0) {
                if s.text.isEmpty {
                    Caret()
                    Text(session.placeholder).foregroundStyle(PP.muted)
                } else if session.privacy == .secret {
                    Text(String(repeating: "•", count: s.caret)).foregroundStyle(PP.text)
                    Caret()
                    Text(String(repeating: "•", count: s.text.count - s.caret)).foregroundStyle(PP.text)
                } else {
                    Text(String(s.text[..<s.caret])).foregroundStyle(PP.text)
                    Caret()
                    Text(String(s.text[s.caret...])).foregroundStyle(PP.text)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 15))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(PP.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PP.accent, lineWidth: 1))
        }
        .frame(maxWidth: 10 * Self.maxUnit + 9 * Self.gap)
        .padding(.horizontal, 20)
    }

    // MARK: the keys

    private var keys: some View {
        let s = session.state
        let rows = PadKeyboard.layout(s.layer)
        return GeometryReader { geo in
            let unit = min(Self.maxUnit, (geo.size.width - 9 * Self.gap) / 10)
            VStack(spacing: Self.gap) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: Self.gap) {
                        ForEach(rows[r].indices, id: \.self) { c in
                            let cell = rows[r][c]
                            key(cell.key, on: s.row == r && s.column == c, shifted: cell.key == .shift && s.layer == .upper
                                || cell.key == .symbols && s.layer == .symbols)
                                .frame(width: unit * cell.width + Self.gap * (cell.width - 1), height: Self.keyHeight)
                                .onTapGesture { session.tap(row: r, column: c) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 5 * Self.keyHeight + 4 * Self.gap)
        .padding(.horizontal, 20)
    }

    private func key(_ k: PadKey, on: Bool, shifted: Bool) -> some View {
        let special: Bool = if case .char = k { false } else { k != .space }
        let fill = k == .done ? PP.accent : shifted ? PP.text : special ? PP.line : PP.raised
        let ink = k == .done ? PP.onAccent : shifted ? PP.background : PP.text
        return Text(PadKeyboardSession.label(k))
            .font(.system(size: special || k == .space ? 13 : 16, weight: special ? .semibold : .regular))
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                // The focus ring, as PadFocus draws it: amber, outside the key.
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(PP.accent, lineWidth: 3)
                    .padding(-4)
                    .opacity(on ? 1 : 0)
            }
            .contentShape(Rectangle())
    }

    // MARK: the buttons

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            PadModalHint(button: .a, label: "Type") { session.press(.a) }
            PadModalHint(button: .b, label: session.state.text.isEmpty ? "Close" : "Delete") { session.press(.b) }
            PadModalHint(button: .x, label: "Space") { session.press(.x) }
            PadModalHint(button: .y, label: "Shift") { session.press(.y) }
            PadModalHint(button: .menu, label: "Done") { session.press(.menu) }
        }
        .padding(.horizontal, 20)
        .frame(height: 36)
    }
}

private struct Caret: View {
    @State private var on = true

    var body: some View {
        Rectangle().fill(PP.accent).frame(width: 2, height: 17)
            .opacity(on ? 1 : 0)
            .onAppear { withAnimation(.easeInOut(duration: 0.5).repeatForever()) { on = false } }
    }
}
