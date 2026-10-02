// SPDX-License-Identifier: GPL-3.0-or-later
// Over the dimmed first-run checklist once every step is settled. Continue is
// always highlighted: touch or A leaves setup; B closes only this overlay.

import SwiftUI

struct SetupCompletionView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 38)).foregroundStyle(PP.ok)
                Text("You're all set").font(PP.display(30))
                Text("Choose a game and start playing.")
                    .font(.system(size: 15)).foregroundStyle(PP.muted)
                Button { PadModal.shared.press(.a) } label: {
                    HStack(spacing: 10) {
                        PadGlyph(button: .a, inverted: true)
                        Text("Continue").font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(PP.onAccent)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(PP.accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("setup-continue")
                PadModalHint(button: .b, label: "Back to steps") { PadModal.shared.press(.b) }
            }
            .padding(28)
            .frame(width: 370)
            .background(PP.surface, in: RoundedRectangle(cornerRadius: 18))
        }
        .foregroundStyle(PP.text)
        .accessibilityIdentifier("setup-complete")
    }
}
