// SPDX-License-Identifier: GPL-3.0-or-later
// The focus ring: the one selection cue of the gamepad UI. A focusable view
// (`padItem`) reports its frame on screen; a direction moves the ring to the
// nearest item that way (PlayportKit.FocusMove), A runs the ringed item's
// action, and the footer's A names it (the item's hint). A tap on an item
// rings it and runs it too, so touch works everywhere. An adjustable item (a
// value picker, PadPicker.swift) takes left and right itself: they change its
// value instead of moving the ring. A resettable item (a game's option, set
// for that game) takes Y: `resetFocused()` puts it back to its default.
//
// One screen's items are on screen at a time (AppShell shows one page), so
// one focus serves the app. A lazy grid (the Library) reports the frames of
// the tiles it has not drawn yet itself (`padFrames`), so the ring moves to
// them and the grid scrolls there. When a screen's items leave (a game page opened
// over them) the ring stays on the item it had, and comes back there.

import Combine
import PlayportKit
import SwiftUI

@MainActor
final class PadFocus: ObservableObject {
    static let shared = PadFocus()

    struct Item: Equatable, Sendable {
        var frame: CGRect
        var hint: String
        /// Left and right change this item's value (`adjustments`) rather than move the ring.
        var adjustable = false
        /// Y puts this item back to its default (`resets`).
        var resettable = false
    }

    @Published var focused: String?
    /// What A does on the ringed item, for the footer.
    @Published private(set) var hint: String?
    /// The ringed item takes Y (Back to default), for the footer.
    @Published private(set) var canReset = false
    private(set) var items: [String: Item] = [:]
    let activations = PassthroughSubject<String, Never>()
    /// Left (-1) or right (+1) on an adjustable item.
    let adjustments = PassthroughSubject<(id: String, by: Int), Never>()
    /// Y on a resettable item.
    let resets = PassthroughSubject<String, Never>()
    /// Where the ring starts on this screen when that item is on it (the Library's first tile), else top left.
    private var start: String?

    /// The items on screen now (PadItemsKey).
    func update(_ new: [String: Item]) {
        items = new
        if !new.isEmpty, focused.map({ new[$0] == nil }) ?? true {
            focused = start.flatMap { new[$0] == nil ? nil : $0 } ?? FocusMove.first(among: new.mapValues(\.frame))
        }
        refreshHint()
    }

    /// `within` keeps the ring among some of the items (Settings' rows, apart from its list).
    func move(_ direction: FocusDirection, within: ((String) -> Bool)? = nil) {
        let among = (within.map { keep in items.filter { keep($0.key) } } ?? items).mapValues(\.frame)
        guard let ringed = focused, let from = items[ringed]?.frame else {
            focused = FocusMove.first(among: among)
            return refreshHint()
        }
        if direction == .left || direction == .right, items[ringed]?.adjustable == true {
            return adjustments.send((ringed, direction == .left ? -1 : 1))
        }
        if let next = FocusMove.next(from: from, direction, among: among) {
            focused = next
            refreshHint()
        }
    }

    func activate() {
        if let ringed = focused, items[ringed] != nil { activations.send(ringed) }
    }

    /// Y: the ringed item back to its default, when it has one.
    func resetFocused() {
        if let ringed = focused, items[ringed]?.resettable == true { resets.send(ringed) }
    }

    /// Another screen: the ring starts at `start` when it comes, else at its top left.
    func reset(start: String? = nil) {
        self.start = start
        focused = start.flatMap { items[$0] == nil ? nil : $0 }
        refreshHint()
    }

    func ring(_ id: String) {
        focused = id
        refreshHint()
    }

    private func refreshHint() {
        let now = focused.flatMap { items[$0]?.hint }
        if now != hint { hint = now }
        let reset = focused.flatMap { items[$0]?.resettable } ?? false
        if reset != canReset { canReset = reset }
    }
}

struct PadItemsKey: PreferenceKey {
    static let defaultValue: [String: PadFocus.Item] = [:]
    static func reduce(value: inout [String: PadFocus.Item], nextValue: () -> [String: PadFocus.Item]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// A focusable item: `hint` is what A does on it (the footer's A), `action` what A and a tap do.
    /// `adjust`, when given, makes left and right change the item's value (-1, +1) instead of moving the ring.
    /// `reset`, when given, is what Y does on it (Back to default). `ring: false` leaves the
    /// cue to the item itself (a panel's row fills light, as the list picker's does).
    func padItem(_ id: String, hint: String, cornerRadius: CGFloat = 12, adjust: ((Int) -> Void)? = nil,
                 reset: (() -> Void)? = nil, ring: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(PadItemModifier(id: id, hint: hint, cornerRadius: cornerRadius, adjust: adjust, reset: reset, ring: ring,
                                 action: action))
    }

    /// Items the view below does not draw yet (a lazy grid's tiles off screen), by frame on screen.
    func padFrames(_ frames: [String: CGRect], hint: String) -> some View {
        background(Color.clear.preference(key: PadItemsKey.self, value: frames.mapValues { .init(frame: $0, hint: hint) }))
    }

    /// Collects the items below into PadFocus (once, at the shell).
    func padFocusRoot() -> some View {
        onPreferenceChange(PadItemsKey.self) { items in
            MainActor.assumeIsolated { PadFocus.shared.update(items) }
        }
    }
}

private struct PadItemModifier: ViewModifier {
    let id: String
    let hint: String
    let cornerRadius: CGFloat
    let adjust: ((Int) -> Void)?
    let reset: (() -> Void)?
    let ring: Bool
    let action: () -> Void
    @ObservedObject private var focus = PadFocus.shared

    func body(content: Content) -> some View {
        Button {
            focus.ring(id)
            action()
        } label: {
            content.contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .buttonStyle(PadPressStyle())
        // The design's ring: 3 pt of amber, 3 pt outside the item.
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius + 5)
                .strokeBorder(PP.accent, lineWidth: 3)
                .padding(-6)
                .opacity(ring && focus.focused == id ? 1 : 0)
                .allowsHitTesting(false)
        }
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: PadItemsKey.self, value: [id: .init(frame: geo.frame(in: .global), hint: hint,
                                                                             adjustable: adjust != nil,
                                                                             resettable: reset != nil)])
            }
        }
        .onReceive(focus.activations) { if $0 == id { action() } }
        .onReceive(focus.adjustments) { if $0.id == id { adjust?($0.by) } }
        .onReceive(focus.resets) { if $0 == id { reset?() } }
        .id(id)
        .accessibilityIdentifier("item-\(id)")
    }
}

/// A touch press dims the item a little; the ring is the controller's cue.
private struct PadPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}
