// SPDX-License-Identifier: GPL-3.0-or-later
// The pickers of the gamepad UI:
//
// - PadValueRow: a list row whose value left and right step through its
//   choices (SettingsGraphics.dc.html: "‹ 720p ›"). A steps forward too,
//   and the arrows take taps.
// - The list picker: a panel at the right over the dimmed screen with one
//   row per choice, a radio on the current one
//   (GameOptionsPicker.dc.html). Up and down move, A chooses, B goes back;
//   a screen opens it with PadModal.shared.picker(...).
//
// Stepping is PlayportKit.PickerIndex: a value picker stops at its ends
// unless it wraps, the list's cursor stops at the first and last rows.

import HostIOKit
import PlayportKit
import SwiftUI

/// One choice in a picker.
struct PadOption: Identifiable, Equatable {
    let id: String
    let label: String
    /// The grey text at the row's right ("720p, from Settings").
    var detail: String?
    /// A heading drawn above this row when it differs from the row before's (the Library's Show, Sort).
    var section: String?
}

// MARK: the list picker

@MainActor
final class PadPickerSession: ObservableObject {
    let title: String
    let context: String?
    let note: String?
    let options: [PadOption]
    /// The current values, their radios on: one, or one per section.
    let selected: Set<String>
    @Published private(set) var cursor: Int
    private let choose: (String) -> Void

    init(title: String, context: String?, note: String?, options: [PadOption], selected: Set<String>,
         choose: @escaping (String) -> Void) {
        self.title = title
        self.context = context
        self.note = note
        self.options = options
        self.selected = selected
        self.choose = choose
        cursor = options.firstIndex { selected.contains($0.id) } ?? 0
    }

    func press(_ b: NavButton) {
        switch b {
        case .up, .down: cursor = PickerIndex.step(cursor, by: b == .up ? -1 : 1, count: options.count, wrap: false)
        case .a: pick(cursor)
        case .b: PadModal.shared.close()
        default: break
        }
    }

    func pick(_ i: Int) {
        guard options.indices.contains(i) else { return }
        cursor = i
        PadModal.shared.close()
        choose(options[i].id)
    }
}

struct PadPickerPanel: View {
    @ObservedObject var session: PadPickerSession

    var body: some View {
        ZStack {
            // The design's scrim; a tap on it goes back.
            Color(hex: 0x05070A).opacity(0.72).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { session.press(.b) }
            HStack(spacing: 0) {
                VStack {
                    Spacer()
                    HStack(spacing: 18) {
                        PadModalHint(button: .a, label: "Choose") { session.press(.a) }
                        PadModalHint(button: .b, label: "Back") { session.press(.b) }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 36)
                    .frame(height: 36)
                }
                panel.frame(width: 410)
            }
        }
        .accessibilityIdentifier("pad-picker")
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let context = session.context {
                Text(context).font(.system(size: 12)).foregroundStyle(PP.muted).padding(.horizontal, 14)
            }
            Text(session.title).font(PP.display(22)).foregroundStyle(PP.text)
                .padding(.horizontal, 14).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(session.options.indices, id: \.self) { i in
                            if let section = session.options[i].section, i == 0 || session.options[i - 1].section != section {
                                Text(section).font(.system(size: 12, weight: .semibold)).foregroundStyle(PP.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14).padding(.top, i == 0 ? 0 : 10).padding(.bottom, 2)
                            }
                            row(session.options[i], on: session.cursor == i).id(i)
                                .onTapGesture { session.pick(i) }
                        }
                        if let note = session.note {
                            Text(note).font(.system(size: 12)).foregroundStyle(PP.muted).lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.top, 10)
                        }
                    }
                    .padding(.bottom, 18)
                }
                .onChange(of: session.cursor) { _, i in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(i) } }
                .onAppear { proxy.scrollTo(session.cursor) }
            }
        }
        .padding(.top, 18).padding(.leading, 20).padding(.trailing, 28)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PP.surface.ignoresSafeArea())
        .overlay(alignment: .leading) { Rectangle().fill(PP.line).frame(width: 1).ignoresSafeArea() }
    }

    /// One choice: the cursor's row is filled light, the current value has its radio on.
    private func row(_ o: PadOption, on: Bool) -> some View {
        let current = session.selected.contains(o.id)
        return HStack(spacing: 12) {
            Circle()
                .strokeBorder(on ? (current ? PP.background : Color(hex: 0x3A4452)) : (current ? PP.accent : Color(hex: 0x4A5667)),
                              lineWidth: current ? 5 : 2)
                .frame(width: 16, height: 16)
            Text(o.label).font(.system(size: 15, weight: .medium))
            Spacer(minLength: 8)
            if let d = o.detail {
                Text(d).font(.system(size: 12)).foregroundStyle(on ? Color(hex: 0x3A4452) : PP.muted).lineLimit(1)
            }
        }
        .foregroundStyle(on ? PP.background : PP.text)
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(on ? PP.text : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .accessibilityIdentifier("option-\(o.id)")
    }
}

// MARK: the value picker

/// A row whose value left and right change: "Title … ‹ value ›".
struct PadValueRow: View {
    let id: String
    let title: String
    var subtitle: String?
    let values: [String]
    let index: Int
    var wrap = false
    let changed: (Int) -> Void

    var body: some View {
        PadRowBody(title: title, subtitle: subtitle, style: .card) {
            HStack(spacing: 8) {
                arrow("‹", by: -1)
                Text(values.indices.contains(index) ? values[index] : "–")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(PP.text)
                arrow("›", by: 1)
            }
        }
        .padItem(id, hint: "Change", cornerRadius: 10, adjust: step) { step(1, wrapping: true) }
    }

    private func arrow(_ s: String, by: Int) -> some View {
        let end = !wrap && PickerIndex.step(index, by: by, count: values.count, wrap: false) == index
        return Text(s).font(.system(size: 16)).foregroundStyle(PP.muted).opacity(end ? 0.35 : 1)
            .frame(minWidth: 18, minHeight: 30)
            .contentShape(Rectangle())
            .onTapGesture { step(by) }
    }

    private func step(_ by: Int) { step(by, wrapping: wrap) }

    private func step(_ by: Int, wrapping: Bool) {
        let next = PickerIndex.step(index, by: by, count: values.count, wrap: wrapping)
        if next != index { changed(next) }
    }
}
