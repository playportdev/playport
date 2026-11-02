// SPDX-License-Identifier: GPL-3.0-or-later
// The performance overlay over a game: one pill at the top middle of the safe
// area, between the Gamepad layout's View and Menu, above the Gyro aim chip
// (the corners hold the shoulder buttons), with the frame rate and frame time
// of the frames the game's layer put on screen (PacedMetalLayer.presentRate,
// HostIOKit PresentRate) and the
// phone's thermal state (ProcessInfo.thermalState) as a dot, green, amber,
// orange or red, named once it is above Nominal. Read four times a second
// while it shows; it takes no touch. Settings › Graphics › Performance
// overlay and the in-game menu's row switch it, for every game, off unless
// turned on.

import QuartzCore
import UIKit

enum PerformanceOverlay {
    static let key = "performanceOverlay"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
}

final class PerformanceOverlayView: UIView {
    private let pill = UIView()
    private let label = UILabel()
    private var clock: Timer?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        pill.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        pill.layer.cornerCurve = .continuous
        addSubview(pill)
        pill.addSubview(label)
        accessibilityIdentifier = "performance-overlay"
    }

    required init?(coder: NSCoder) { fatalError("PerformanceOverlayView is created in code") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refresh()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.inset(by: gameSafeInsets)
        let size = label.sizeThatFits(CGSize(width: area.width, height: 20))
        let h = 22.0
        let w = ceil(size.width) + 20
        pill.frame = CGRect(x: area.midX - w / 2, y: area.minY + 2, width: w, height: h)
        pill.layer.cornerRadius = h / 2
        label.frame = pill.bounds.insetBy(dx: 10, dy: 0)
    }

    /// Shows it, reading four times a second, or hides it, as the setting is now.
    func refresh() {
        let on = PerformanceOverlay.enabled && window != nil
        isHidden = !on
        guard on else {
            clock?.invalidate()
            clock = nil
            return
        }
        guard clock == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func tick() {
        let rate = PacedMetalLayer.presentRate()
        let thermal = ProcessInfo.processInfo.thermalState
        let text = NSMutableAttributedString()
        let value: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
                                                    .foregroundColor: UIColor.white]
        let unit: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10, weight: .medium),
                                                   .foregroundColor: UIColor.white.withAlphaComponent(0.7)]
        text.append(NSAttributedString(string: "\(rate.fps)", attributes: value))
        text.append(NSAttributedString(string: " FPS   ", attributes: unit))
        text.append(NSAttributedString(string: rate.frameMS.map { String(format: "%.1f", $0) } ?? "–", attributes: value))
        text.append(NSAttributedString(string: " ms   ", attributes: unit))
        text.append(NSAttributedString(string: "●", attributes: [.font: UIFont.systemFont(ofSize: 11),
                                                                .foregroundColor: Self.color(thermal)]))
        if thermal != .nominal {
            text.append(NSAttributedString(string: " " + ThermalLog.name(thermal).capitalized,
                                           attributes: [.font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                                                        .foregroundColor: UIColor.white]))
        }
        label.attributedText = text
        setNeedsLayout()
    }

    private static func color(_ s: ProcessInfo.ThermalState) -> UIColor {
        switch s {
        case .nominal: .systemGreen
        case .fair: .systemYellow
        case .serious: .systemOrange
        case .critical: .systemRed
        @unknown default: .systemGray
        }
    }
}
