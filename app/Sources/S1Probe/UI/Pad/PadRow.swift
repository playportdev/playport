// SPDX-License-Identifier: GPL-3.0-or-later
// The list row of Settings, Game options and Downloads
// (Settings.dc.html, SettingsGraphics.dc.html, GameOptions.dc.html): a title,
// an optional grey line under it, and at the right a value or detail and an
// accessory (a chevron, a switch). A dot before the value marks a setting
// changed for this game. The row is a focus item: A and a tap run it.
//
// Two looks: `.card`, a filled row with room for the grey line (Settings),
// and `.plain`, a 38 pt line in a panel (Game options), which fills light
// when the focus is on it (GameOptions.dc.html) instead of taking the ring.
// PadSectionHeader is the small capitals above a group of plain rows.

import SwiftUI

enum PadRowStyle {
    case card
    case plain
}

enum PadRowAccessory: Equatable {
    case none
    /// ›, a row that opens something (a picker, a page).
    case chevron
    /// A switch, on or off.
    case toggle(Bool)
}

struct PadRow: View {
    let id: String
    let title: String
    var subtitle: String?
    /// The value or detail at the right ("Default · 720p", "Frees 9.2 GB").
    var value: String?
    var accessory = PadRowAccessory.none
    /// Changed for this game: the amber dot before the value.
    var changed = false
    /// A row that removes something (Uninstall): its title in red.
    var destructive = false
    var style = PadRowStyle.card
    /// What A does on it, for the footer.
    var hint = "Choose"
    /// Y on the row: its value back to the default (a game's option set for it).
    var reset: (() -> Void)?
    let action: () -> Void
    @ObservedObject private var focus = PadFocus.shared

    var body: some View {
        let selected = style == .plain && focus.focused == id
        PadRowBody(title: title, subtitle: subtitle, style: style, destructive: destructive, selected: selected) {
            HStack(spacing: 6) {
                if changed { Circle().fill(PP.accent).frame(width: 7, height: 7) }
                if let value {
                    Text(value).lineLimit(1)
                }
                switch accessory {
                case .none: EmptyView()
                case .chevron: Text("›")
                case .toggle(let on): PadSwitch(on: on)
                }
            }
            .font(.system(size: 13)).foregroundStyle(selected ? Color(hex: 0x3A4452) : PP.muted)
        }
        .padItem(id, hint: hint, cornerRadius: 10, reset: reset, ring: style != .plain, action: action)
    }
}

/// A row's frame and title; `trailing` is its right side.
struct PadRowBody<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var style = PadRowStyle.card
    var destructive = false
    /// A plain row with the focus on it: filled light, its text dark.
    var selected = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? (destructive ? Color(hex: 0xB0301E) : PP.background)
                                     : destructive ? Color(hex: 0xFF9A8A) : PP.text)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(selected ? Color(hex: 0x3A4452) : PP.muted)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, style == .card ? 6 : 0)
        .frame(minHeight: style == .card ? 46 : 38)
        .frame(maxWidth: .infinity)
        .background(selected ? PP.text : style == .card ? PP.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The small grey capitals over a group of rows ("GRAPHICS").
struct PadSectionHeader: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold)).tracking(1.1)
            .foregroundStyle(PP.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
    }
}

/// The design's switch: amber with a dark knob at the right when on, grey at the left when off.
struct PadSwitch: View {
    let on: Bool

    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? PP.accent : PP.line)
            Circle().fill(on ? PP.onAccent : PP.muted).frame(width: 16, height: 16).padding(3)
        }
        .frame(width: 40, height: 22)
        .animation(.easeOut(duration: 0.12), value: on)
    }
}
