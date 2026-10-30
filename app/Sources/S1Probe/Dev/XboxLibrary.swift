// SPDX-License-Identifier: GPL-3.0-or-later
// The Xbox store's Library surfaces (decision 0166): the dev app only. Release is built
// without Dev/, and `pp verify --variant release` fails an executable naming a Swift
// `Xbox…` type or carrying `emptyText` (build/verify-ipa.py, XBOX_STRINGS), so an Xbox
// surface that slips out of Dev/ or `#if !PLAYPORT_RELEASE` is caught there.

import ContentKit

enum XboxLibrary {
    /// The Library's chips name the Xbox store: before its sign-in exists (PLA-491), always.
    static func addChip(to stores: inout Set<Store>) {
        stores.insert(.xbox)
    }

    /// The Xbox chip's empty Library. Its last sentence is verify-ipa.py's release marker.
    static let emptyText = "Games you own on Xbox and PC Game Pass titles appear here. Xbox is in the dev app only."
}
