// SPDX-License-Identifier: GPL-3.0-or-later
// The virtual gamepad's layouts (VirtualGamepad.swift, PlayportKit PadLayout):
// Settings › Virtual gamepad lists them, and the editor changes one, opened
// from there or from a game's in-game menu. The editor is touch only: a control
// dragged moves, the one touched last gets a size and can be hidden (not Home,
// the way to the menu). Held upright, the canvas is where the pad is during a
// game, so a layout is edited in place; sideways it sits beside the tools.
// A layout changed from a game's menu changes for every game that uses it;
// Save as new keeps the old one and gives the game the copy.

import PlayportKit
import SwiftUI

@MainActor
final class PadLayoutEditor: ObservableObject {
    static let shared = PadLayoutEditor()

    /// The layout as edited; nil while the editor is closed.
    @Published var draft: PadLayout?
    @Published var selected: PadControl?
    /// A layout not saved yet (Settings' New layout).
    @Published private(set) var isNew = false
    /// Opened from a game's in-game menu: Save as new gives the game the copy.
    private var fromGame = false

    var isOpen: Bool { draft != nil }

    func open(_ id: String, fromGame: Bool) {
        draft = PadLayoutStore.shared.all.layout(id)
        selected = nil
        isNew = false
        self.fromGame = fromGame
    }

    /// A new layout, Xbox's to start from.
    func create() {
        let all = PadLayoutStore.shared.all
        draft = PadLayout(id: UUID().uuidString, name: all.freeName("My layout"), preset: .xbox)
        selected = nil
        isNew = true
        fromGame = false
    }

    func save() {
        guard var d = draft else { return }
        d.name = d.name.trimmingCharacters(in: .whitespaces)
        if d.name.isEmpty { d.name = PadLayoutStore.shared.all.freeName("My layout") }
        PadLayoutStore.shared.all.save(d)
        close()
    }

    /// The draft as a copy, the layout it came from as it was.
    func saveAsNew() {
        guard let d = draft else { return }
        let copy = PadLayoutStore.shared.all.duplicate(d)
        if fromGame { VirtualGamepad.shared.choose(copy.id) }
        close()
    }

    /// The layout gone; a game that used it gets the default.
    func delete() {
        guard let d = draft else { return }
        PadLayoutStore.shared.all.remove(d.id)
        close()
    }

    func close() {
        draft = nil
        selected = nil
    }
}

/// The editor over the whole screen (RootView).
struct PadLayoutEditorView: View {
    @ObservedObject private var editor = PadLayoutEditor.shared
    @ObservedObject private var store = PadLayoutStore.shared

    var body: some View {
        GeometryReader { g in
            if g.size.height > g.size.width {
                // Where GameArea puts the pad: the bottom half.
                let top = (g.size.height * 0.5).rounded()
                VStack(spacing: 0) {
                    tools.padding(.top, 20).frame(height: top)
                    canvas.frame(maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    tools.frame(width: min(340, g.size.width * 0.42))
                    canvas.aspectRatio(670.0 / 475.0, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.vertical, 12)
            }
        }
        .background(PP.background)
        .ignoresSafeArea()
        .foregroundStyle(PP.text)
        .statusBarHidden()
    }

    private var draft: Binding<PadLayout> {
        Binding(get: { editor.draft ?? store.all.defaultLayout }, set: { editor.draft = $0 })
    }

    private var canvas: some View {
        VirtualPadControls(layout: draft.wrappedValue, editing: true, selected: editor.selected,
                           onEdit: { editor.draft = $0 }, onSelect: { editor.selected = $0 })
    }

    private var tools: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button("Cancel") { editor.close() }
                    Spacer()
                    Text(editor.isNew ? "New layout" : "Edit layout").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button("Save") { editor.save() }.fontWeight(.semibold)
                }
                .tint(PP.accent)
                TextField("Name", text: draft.name)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).frame(height: 40)
                    .background(PP.surface, in: RoundedRectangle(cornerRadius: 10))
                Toggle("Vibrate on press", isOn: draft.haptics).tint(PP.accent)
                let isDefault = !editor.isNew && store.all.defaultID == draft.wrappedValue.id
                Toggle("Default for games", isOn: Binding(get: { isDefault }, set: { on in
                    if on, !editor.isNew { store.all.makeDefault(draft.wrappedValue.id) }
                }))
                .tint(PP.accent)
                .disabled(editor.isNew || isDefault)
                HStack(spacing: 10) {
                    Menu("Reset to…") {
                        ForEach(PadLayout.Preset.allCases, id: \.self) { p in
                            Button(p.title) { draft.wrappedValue.reset(to: p) }
                        }
                    }
                    if !editor.isNew {
                        Button("Save as new") { editor.saveAsNew() }
                        Spacer()
                        Button("Delete", role: .destructive) { editor.delete() }
                            .disabled(store.all.layouts.count < 2)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .lineLimit(1)
                .tint(PP.soft)
                Rectangle().fill(PP.line).frame(height: 1)
                if let c = editor.selected {
                    selectedTools(c)
                } else {
                    Text("Drag a control to move it. Touch one to change its size or hide it.")
                        .font(.system(size: 14)).foregroundStyle(PP.muted)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func selectedTools(_ c: PadControl) -> some View {
        let place = Binding(get: { draft.wrappedValue[c] }, set: { draft.wrappedValue[c] = $0 })
        Text(c.title).font(.system(size: 15, weight: .semibold))
        HStack {
            Text("Size")
            Slider(value: place.scale, in: PadLayout.scales).tint(PP.accent)
            Text("\(Int((place.wrappedValue.scale * 100).rounded()))%").monospacedDigit().foregroundStyle(PP.muted)
                .frame(width: 48, alignment: .trailing)
        }
        if c.canHide {
            Toggle("Hidden", isOn: place.hidden).tint(PP.accent)
        } else {
            Text("Home stays: held, it opens the game's menu.").font(.system(size: 13)).foregroundStyle(PP.muted)
        }
    }
}

/// Settings › Virtual gamepad (a foldable's only): the layouts, each opening the editor.
struct VirtualPadSettings: View {
    @ObservedObject private var store = PadLayoutStore.shared

    var body: some View {
        SettingsNote(text: "A game's Game options › Virtual gamepad puts this controller under the game while the "
                     + "phone is open and upright. A game starts with the default layout; hold ⌂ in the game to "
                     + "change or edit its own.")
        ForEach(store.all.layouts) { l in
            let isDefault = l.id == store.all.defaultID
            PadRow(id: "set:padLayout:\(l.id)", title: l.name, subtitle: l.haptics ? "Vibrates on press" : "No vibration",
                   value: isDefault ? "Default" : nil, accessory: .chevron, hint: "Edit") {
                PadLayoutEditor.shared.open(l.id, fromGame: false)
            }
        }
        PadRow(id: "set:padLayout:new", title: "New layout", accessory: .chevron, hint: "Create") {
            PadLayoutEditor.shared.create()
        }
    }
}
