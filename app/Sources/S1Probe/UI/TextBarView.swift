// SPDX-License-Identifier: GPL-3.0-or-later
// The text bar over a running game (PLA-267; PLA-616,
// "Signing in on the phone"): a field across the bottom of the screen, above the
// iOS keyboard, whose typing, paste and AutoFill reach the focused guest window
// as characters (WM_CHAR), with Tab, Enter and Backspace as keys. HostIOKit
// TextBar decides what each edit sends; HostIO.text posts it in TextBarPacing's
// batches, so a key after characters (Enter after a password) waits for them.
//
// The in-game menu's Type text row opens it (back to the game, the bar and the
// keyboard up), so it is in reach with a controller connected, when no
// on-screen controls are drawn. Its lock button turns the password mode on: the
// field draws dots and iOS offers a saved password. The close button, a game's
// end or the menu opening close it. A touch above it reaches the game, so a
// launcher's field can be clicked while it is open.
//
// Nothing typed is logged: the log has `textbar: open, plain (not logged)`,
// `secret on`, `closed` and the keys' names, never a character or a length.

import HostIOKit
import SwiftUI
import UIKit

@MainActor
final class GameTextBar: ObservableObject {
    static let shared = GameTextBar()

    @Published private(set) var isOpen = false
    @Published private(set) var bar = TextBar()

    private static func log(_ line: String) { HostIO.log("textbar: " + line) }

    /// Type text in the in-game menu (it has resumed the game). Opens empty, in the mode it had.
    func open() {
        guard TitleLaunch.shared.running else { return }
        bar = TextBar(secure: bar.secure)
        isOpen = true
        Self.log("open, \(bar.summary)")
    }

    /// The close button, the menu opening, the game's end.
    func close() {
        guard isOpen else { return }
        isOpen = false
        bar = TextBar(secure: bar.secure)
        Self.log("closed")
    }

    /// The lock button: the password mode on or off. What is in the field stays the guest's.
    func setSecure(_ on: Bool) {
        guard bar.secure != on else { return }
        bar.secure = on
        Self.log(on ? "secret on (not logged)" : "secret off")
    }

    /// The field's text changed (a key, a paste, AutoFill, a correction).
    func change(to text: String) { send(bar.change(to: text)) }

    /// Text typed at the end of the field as the keyboard types it (a dev build's driver).
    func type(_ text: String) { send(bar.type(text)) }

    /// The bar's Tab and Enter buttons, the keyboard's return, Backspace on an empty field.
    func press(_ key: TextBar.Key) {
        send(bar.press(key))
        Self.log("\(key)")
    }

    /// What the bar sent that is still going out: one chain, so its input leaves in its order.
    /// Its value: whether every batch went once the ring was empty (none waited out `ringWait`).
    private var sending: Task<Bool, Never>?
    /// How long a batch waits for the input ring to empty before it goes anyway.
    private static let ringWait: Duration = .seconds(5)

    /// In HostIOKit TextBarPacing's batches: a key that follows characters (Enter after a
    /// password) goes once they are in the server's queue, and long text never overflows the ring.
    private func send(_ inputs: [TextBar.Input]) {
        guard isOpen, !inputs.isEmpty else { return }
        let before = sending
        sending = Task {
            var posted = await before?.value ?? true
            for batch in TextBarPacing.batches(inputs) {
                posted = await Self.ringEmptied() && posted
                HostIO.shared.text(batch)
            }
            return posted
        }
    }

    /// Whether all the bar sent so far is in the server's queue: what is going out has gone, each
    /// batch after an empty ring, and the ring is empty again. False after `ringWait` without a
    /// guest thread draining it (a game that pumps no messages: hung, or still loading).
    func delivered() async -> Bool {
        let posted = await sending?.value ?? true
        return await Self.ringEmptied() && posted
    }

    private static func ringEmptied() async -> Bool {
        let deadline = ContinuousClock.now + ringWait
        while !HostIO.shared.inputPosted {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

struct TextBarView: View {
    @ObservedObject private var model = GameTextBar.shared

    var body: some View {
        VStack {
            Spacer(minLength: 0).allowsHitTesting(false)
            HStack(spacing: 8) {
                button("xmark", label: "Close") { model.close() }
                button(model.bar.secure ? "lock.fill" : "lock.open", label: model.bar.secure ? "Password mode on" : "Password mode off",
                       lit: model.bar.secure) { model.setSecure(!model.bar.secure) }
                TextBarField(model: model)
                    .frame(height: 36)
                    .padding(.horizontal, 10)
                    .background(PP.raised, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(PP.line))
                text("Tab") { model.press(.tab) }
                text("Enter") { model.press(.enter) }
            }
            .padding(8)
            .background(PP.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 8).padding(.bottom, 4)
        }
        .foregroundStyle(PP.text)
        .accessibilityIdentifier("text-bar")
    }

    private func button(_ symbol: String, label: String, lit: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(lit ? PP.onAccent : PP.text)
                .frame(width: 36, height: 36)
                .background(lit ? PP.accent : PP.raised, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func text(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 12).frame(height: 36)
                .background(PP.raised, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

/// The bar's UITextField: secure in password mode, no autocorrection or capitals (an
/// email, a password), first responder while the bar is up; its edits go to the model.
private struct TextBarField: UIViewRepresentable {
    let model: GameTextBar

    final class Field: UITextField {
        /// Backspace with nothing in the field: UIKit sends no change, but the guest's field may hold text.
        var emptyBackspace: @MainActor () -> Void = {}

        override func deleteBackward() {
            if (text ?? "").isEmpty { emptyBackspace() }
            super.deleteBackward()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        let model: GameTextBar
        init(model: GameTextBar) { self.model = model }

        @objc func changed(_ f: UITextField) {
            // An input method's text still being composed is not typed yet.
            guard f.markedTextRange == nil else { return }
            model.change(to: f.text ?? "")
        }

        func textFieldShouldReturn(_ f: UITextField) -> Bool {
            model.press(.enter)
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> Field {
        let f = Field()
        f.delegate = context.coordinator
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        f.emptyBackspace = { [model] in model.press(.backspace) }
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.spellCheckingType = .no
        f.smartQuotesType = .no
        f.smartDashesType = .no
        f.smartInsertDeleteType = .no
        f.returnKeyType = .send
        f.textColor = UIColor(PP.text)
        f.tintColor = UIColor(PP.accent)
        f.font = .systemFont(ofSize: 16)
        f.attributedPlaceholder = NSAttributedString(string: "Type into the game", attributes: [.foregroundColor: UIColor(PP.muted)])
        f.textContentType = .username
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(f)
        DispatchQueue.main.async { f.becomeFirstResponder() }
        return f
    }

    func updateUIView(_ f: Field, context: Context) { apply(f) }

    static func dismantleUIView(_ f: Field, coordinator: Coordinator) {
        f.resignFirstResponder()
        // The hardware keyboard's keys go back to the game.
        GameSurfaceView.current?.becomeFirstResponder()
    }

    /// The model's mode and text: Tab and Enter empty the field, the driver types into it.
    private func apply(_ f: Field) {
        let secure = model.bar.secure
        if f.isSecureTextEntry != secure {
            // Password mode offers a saved password; plain offers the account's name.
            f.isSecureTextEntry = secure
            f.textContentType = secure ? .password : .username
            f.reloadInputViews()
        }
        if f.markedTextRange == nil, f.text != model.bar.text { f.text = model.bar.text }
    }
}
