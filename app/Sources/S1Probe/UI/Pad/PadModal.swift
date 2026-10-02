// SPDX-License-Identifier: GPL-3.0-or-later
// What sits over a screen and takes every press while it is up: the
// controller keyboard (PadKeyboardView.swift), a list picker
// (PadPicker.swift), the Cloud save conflict (CloudConflictView.swift) or a
// launch that failed at a step (LaunchViews.swift). The shell (AppShell.swift) draws `PadModalHost` over
// everything, the top bar and the footer too, and sends each press here
// first. A modal draws its own footer; each of its entries is a tap too.
//
// One modal at a time: opening one closes the one before it.

import Combine
import HostIOKit
import PlayportKit
import SwiftUI

@MainActor
final class PadModal: ObservableObject {
    static let shared = PadModal()

    enum Content {
        case keyboard(PadKeyboardSession)
        case picker(PadPickerSession)
        case cloud(CloudConflictSession)
        case launchFailure(LaunchFailureSession)
        case setupComplete
    }

    @Published private(set) var content: Content?

    var isUp: Bool { content != nil }

    /// The controller keyboard over the screen. `changed` sees every edit (a
    /// search filters as it types); `done` gets the text when the player
    /// leaves the keyboard, with Done, ≡, B on an empty text or a tap outside it.
    /// `privacy`: `.hidden` keeps the text out of the driver's log (an account
    /// name), `.secret` also draws it as dots (a password).
    func keyboard(title: String, text: String, placeholder: String = "", maxLength: Int = 256,
                  privacy: PadKeyboardSession.Privacy = .shown,
                  changed: ((String) -> Void)? = nil, done: @escaping (String) -> Void) {
        content = .keyboard(PadKeyboardSession(title: title, text: text, placeholder: placeholder, maxLength: maxLength,
                                               privacy: privacy, changed: changed, done: done))
    }

    /// A list of choices in a panel at the right (GameOptionsPicker.dc.html).
    /// `choose` gets the option picked with A or a tap; B or a tap outside closes it unchanged.
    func picker(title: String, context: String? = nil, note: String? = nil, options: [PadOption], selected: String?,
                choose: @escaping (String) -> Void) {
        picker(title: title, context: context, note: note, options: options, selected: Set([selected].compactMap { $0 }),
               choose: choose)
    }

    /// The same, with a current value in each of the options' sections (the Library's Show and Sort).
    func picker(title: String, context: String? = nil, note: String? = nil, options: [PadOption], selected: Set<String>,
                choose: @escaping (String) -> Void) {
        content = .picker(PadPickerSession(title: title, context: context, note: note, options: options,
                                           selected: selected, choose: choose))
    }

    /// Which save to keep, for a game whose saves changed on both sides (CloudConflict.dc.html).
    func cloudConflict(_ session: CloudConflictSession) { content = .cloud(session) }

    /// A launch that stopped at a step: the steps, and the fix.
    func launchFailure(_ message: LaunchMessage) { content = .launchFailure(LaunchFailureSession(message)) }

    /// The first-run checklist has settled every step. B closes just this modal.
    func setupComplete() { content = .setupComplete }

    func close() { content = nil }

    /// A press while a modal is up: the modal's, whatever it is.
    func press(_ b: NavButton) {
        switch content {
        case .keyboard(let k): k.press(b)
        case .picker(let p): p.press(b)
        case .cloud(let c): c.press(b)
        case .launchFailure(let f): f.press(b)
        case .setupComplete:
            switch b {
            case .a:
                close()
                _ = AppNavigation.shared.back()
            case .b: close()
            default: break
            }
        case nil: break
        }
    }

    /// What the driver's log names: the keyboard's text, or the picker's cursor.
    var summary: String? {
        switch content {
        // Private text, and the key under the cursor (which says what A types), stay out.
        case .keyboard(let k) where k.privacy != .shown: "keyboard \(k.title) (\(k.privacy), not logged)"
        case .keyboard(let k): "keyboard \"\(k.state.string)\" on \(k.keyName)"
        case .picker(let p): "picker \(p.title) on \(p.options.indices.contains(p.cursor) ? p.options[p.cursor].id : "none")"
        case .cloud(let c): "cloud conflict \(c.titleID): \(c.conflicts.count) file(s)" + (c.settling.map { ", keeping \($0.rawValue)" } ?? "")
        case .launchFailure(let f): "launch failed at \(f.message.step.map(LaunchProgress.stepName) ?? "?"): \(f.message.title)"
        case .setupComplete: "setup complete"
        case nil: nil
        }
    }
}

/// Draws the modal that is up over the whole shell.
struct PadModalHost: View {
    @ObservedObject private var modal = PadModal.shared

    var body: some View {
        switch modal.content {
        case .keyboard(let k): PadKeyboardView(session: k).transition(.move(edge: .bottom))
        case .picker(let p): PadPickerPanel(session: p).transition(.opacity)
        case .cloud(let c): CloudConflictView(session: c).transition(.opacity)
        case .launchFailure(let f): LaunchFailureView(session: f).transition(.opacity)
        case .setupComplete: SetupCompletionView().transition(.opacity)
        case nil: EmptyView()
        }
    }
}

/// A modal's own footer entry: its glyph and label, a tap runs it.
struct PadModalHint: View {
    let button: NavButton
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                PadGlyph(button: button)
                Text(label).font(.system(size: 13)).foregroundStyle(PP.soft)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hint-\(button.rawValue)")
    }
}
