// SPDX-License-Identifier: GPL-3.0-or-later
// The touch keyboard's drawing (docs/design/2026-10-09-touch-controls/TouchKeyboard.dc.html):
// the panel across the bottom of the safe area, its keys, and the chip above its
// right end with the close key and, while a modifier is sticky, what it does.
// HostIOKit TouchKeyboard places it and TouchControls holds its keys; this view
// only draws them (OnScreenControls, TouchControlsView.rebuild/refresh) and takes
// no touch itself: TouchControlsView takes them, as it does the layout's.
// A key is amber while held; a sticky modifier is amber while it is down, with
// a bar under its label while locked. Flat fills, no blur (TouchControlsView's note).

#if canImport(UIKit)
import HostIOKit
import UIKit

final class TouchKeyboardPanelView: UIView {
    private enum Look {
        static let panel = UIColor(red: 12 / 255, green: 16 / 255, blue: 24 / 255, alpha: 0.62)
        static let panelEdge = UIColor(red: 238 / 255, green: 241 / 255, blue: 245 / 255, alpha: 0.22)
        static let key = UIColor(red: 238 / 255, green: 241 / 255, blue: 245 / 255, alpha: 0.10)
        static let keyEdge = UIColor(red: 238 / 255, green: 241 / 255, blue: 245 / 255, alpha: 0.20)
        static let text = UIColor(red: 238 / 255, green: 241 / 255, blue: 245 / 255, alpha: 1)
        static let amber = UIColor(red: 245 / 255, green: 181 / 255, blue: 68 / 255, alpha: 0.92)
        static let amberEdge = UIColor(red: 1, green: 208 / 255, blue: 138 / 255, alpha: 1)
        static let onAmber = UIColor(red: 26 / 255, green: 18 / 255, blue: 4 / 255, alpha: 1)
        static let chip = UIColor(red: 12 / 255, green: 16 / 255, blue: 24 / 255, alpha: 0.6)
        static let chipEdge = UIColor(red: 238 / 255, green: 241 / 255, blue: 245 / 255, alpha: 0.25)
        static let chipText = UIColor(red: 201 / 255, green: 209 / 255, blue: 220 / 255, alpha: 1)
    }

    /// One key: a rounded face and its label; the bar shows a locked modifier.
    private final class KeyCap: UIView {
        let label = UILabel()
        let bar = UIView()

        init(frame: CGRect, text: String, size: CGFloat) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.cornerRadius = 7
            layer.borderWidth = 1
            label.frame = bounds
            label.text = text
            label.font = .systemFont(ofSize: size, weight: .semibold)
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            addSubview(label)
            bar.frame = CGRect(x: bounds.midX - 7, y: bounds.maxY - 5, width: 14, height: 2)
            bar.layer.cornerRadius = 1
            bar.backgroundColor = Look.onAmber
            addSubview(bar)
            lit(false, locked: false)
        }

        required init?(coder: NSCoder) { fatalError("KeyCap is created in code") }

        func lit(_ on: Bool, locked: Bool) {
            backgroundColor = on ? Look.amber : Look.key
            layer.borderColor = (on ? Look.amberEdge : Look.keyEdge).cgColor
            label.textColor = on ? Look.onAmber : Look.text
            bar.isHidden = !locked
        }
    }

    private var caps: [String: KeyCap] = [:]
    private let close = UILabel()
    private let hint = UILabel()
    private let hintBox = UIView()

    init(layout k: TouchKeyboard.Layout, frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "touch-keyboard"
        let panel = UIView(frame: Self.rect(k.panel))
        panel.backgroundColor = Look.panel
        panel.layer.cornerRadius = 18
        panel.layer.borderWidth = 1
        panel.layer.borderColor = Look.panelEdge.cgColor
        addSubview(panel)
        let fRow = Set(TouchKeyboard.rows[0].map(\.id))
        for p in k.keys {
            let cap = KeyCap(frame: Self.rect(p.face), text: p.key.label, size: fRow.contains(p.key.id) ? 10 : 12.5)
            addSubview(cap)
            caps[p.key.id] = cap
        }
        // The close key: a chip at its target's place.
        let c = Self.rect(k.close.frame).insetBy(dx: 0, dy: 2)
        close.frame = c
        close.text = "✕ Close"
        close.textAlignment = .center
        close.font = .systemFont(ofSize: 11, weight: .semibold)
        close.layer.cornerRadius = c.height / 2
        close.layer.borderWidth = 1
        close.clipsToBounds = true
        close.accessibilityIdentifier = TouchKeyboard.closeID
        addSubview(close)
        // What a sticky modifier does, beside it.
        hintBox.backgroundColor = Look.chip
        hintBox.layer.borderWidth = 1
        hintBox.layer.borderColor = Look.chipEdge.cgColor
        hintBox.layer.cornerRadius = c.height / 2
        hint.font = .systemFont(ofSize: 11, weight: .semibold)
        hint.textColor = Look.chipText
        hint.textAlignment = .center
        hintBox.addSubview(hint)
        hintBox.isHidden = true
        addSubview(hintBox)
        show(held: [], sticky: [:])
    }

    required init?(coder: NSCoder) { fatalError("TouchKeyboardPanelView is created in code") }

    private static func rect(_ r: TouchRect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.width, height: r.height) }

    /// What is held now (TouchControls.held) and which modifiers are sticky.
    func show(held: Set<String>, sticky: [String: TouchControls.Sticky]) {
        for (id, cap) in caps { cap.lit(held.contains(id), locked: sticky[id] == .locked) }
        let closing = held.contains(TouchKeyboard.closeID)
        close.backgroundColor = closing ? Look.amber : Look.chip
        close.layer.borderColor = (closing ? Look.amberEdge : Look.chipEdge).cgColor
        close.textColor = closing ? Look.onAmber : Look.chipText
        guard let text = TouchKeyboard.hint(sticky) else {
            hintBox.isHidden = true
            return
        }
        hint.text = text
        let w = hint.sizeThatFits(CGSize(width: 600, height: close.frame.height)).width + 20
        hintBox.frame = CGRect(x: close.frame.minX - 6 - w, y: close.frame.minY, width: w, height: close.frame.height)
        hint.frame = hintBox.bounds
        hintBox.isHidden = false
    }
}
#endif
