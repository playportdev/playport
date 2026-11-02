// SPDX-License-Identifier: GPL-3.0-or-later
// The suggested starting layout's toast (PLA-13, phase 4
// item 3). PlayportKit LayoutSuggestion decides; SuggestedLayout samples it once a second on
// the main queue with the game's XInput state reads (HostIO host_pad_state_reads, reported by
// win32u through patches/madeira-unix 0247 and 0273) and the on-screen controls' state:
//
// - play counts while the controls are drawn (after the first frame, no menu, guest dialog or
//   web page over the game) and the app is active;
// - the offer, once per game (marked as it shows), is a toast at the top of the game:
//   "Use Keyboard & mouse" saves that layout as the game's own (ControlsStore), which applies
//   at once; "Not now", or 15 s untouched, leaves the game on Gamepad;
// - the toast goes when the controls do (the menu opens): the offer is not made again.
//
// A dev build logs `controls: suggested layout …` lines, and `controls: the game read XInput
// state` at the game's first read; the UI driver's suggest:accept and
// suggest:dismiss press its buttons (Dev/UIDriver.swift).

#if canImport(UIKit)
import HostIO
import PlayportKit
import QuartzCore
import UIKit

@MainActor
final class SuggestedLayout {
    static let shared = SuggestedLayout()

    /// How long the toast stays untouched.
    static let seconds: TimeInterval = 15

    private var suggestion: LayoutSuggestion?
    private var id: String?
    private var timer: Timer?
    private var hide: DispatchWorkItem?
    weak var view: LayoutSuggestionToast?
    /// The toast is up.
    private(set) var showing = false
    #if !PLAYPORT_RELEASE
    /// Why the game will not be offered, once that is known (the driver's refusal).
    private(set) var outcome: String?
    /// Until the game's first XInput state read, which a dev build logs whatever the offer did
    /// (one made before ends the sampling at once): a pad check reads it from s1-host.log.
    private var readTimer: Timer?
    #endif

    private static func log(_ line: String) {
        #if !PLAYPORT_RELEASE
        HostIO.log("controls: suggested layout " + line)
        #endif
    }

    /// OnScreenControls.start: sampling starts.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { SuggestedLayout.shared.sample() }
        }
        #if !PLAYPORT_RELEASE
        readTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            let reads = host_pad_state_reads()
            guard reads > 0 else { return }
            t.invalidate()
            HostIO.log("controls: the game read XInput state (\(reads) reads by now)")
        }
        #endif
    }

    private func sample() {
        let launch = TitleLaunch.shared
        guard launch.running, let id = launch.titleID else { return }
        let controls = OnScreenControls.shared
        if showing, !controls.drawn {
            Self.log("toast gone with the controls (\(id))")
            close()
        }
        if suggestion == nil {
            self.id = id
            let offered = LayoutSuggestion.offered(id, in: .standard)
            suggestion = LayoutSuggestion(offered: offered)
            if offered { finish("offered before") }
        }
        guard var s = suggestion, !s.done else { return }
        let reads = host_pad_state_reads()
        let store = ControlsStore.shared
        let chosen = LayoutSuggestion.chosen(store.game(id), defaults: store.defaults)
        let state = controls.state
        let running = controls.drawn && UIApplication.shared.applicationState == .active
        let offer = s.sample(at: CACurrentMediaTime(), reads: reads, running: running, state: state, chosen: chosen)
        suggestion = s
        if offer {
            LayoutSuggestion.markOffered(id, in: .standard)
            Self.log("offered for \(id): no XInput state read in \(Int(LayoutSuggestion.window)) s of play")
            show()
        } else if s.done {
            finish(reads > 0 ? "the game read XInput state (\(reads) reads)"
                   : chosen ? "its layout was chosen (\(state.layout.title), the game's own or Settings' Starting layout)"
                   : "the game starts on \(state.layout.title)")
        }
    }

    /// Ruled out: no more sampling; a dev build logs why and keeps it for the driver.
    private func finish(_ why: @autoclosure () -> String) {
        #if !PLAYPORT_RELEASE
        outcome = why()
        Self.log("not offered for \(id ?? "?"): \(outcome ?? "")")
        #endif
        timer?.invalidate()
    }

    private func show() {
        showing = true
        view?.show()
        hide?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { SuggestedLayout.shared.answer(accept: false, by: "15 s untouched") } }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seconds, execute: work)
    }

    /// The toast gone: nothing more to do for this game.
    private func close() {
        hide?.cancel()
        hide = nil
        showing = false
        timer?.invalidate()
        view?.hide()
    }

    /// The toast's buttons (and the driver's suggest:): Keyboard & mouse saved for the game, or not.
    func answer(accept: Bool, by: String) {
        guard showing, let id else { return }
        close()
        guard accept else {
            Self.log("turned down for \(id) (\(by))")
            return
        }
        ControlsStore.shared.setGame(id, LayoutSuggestion.accepted(ControlsStore.shared.game(id)))
        Self.log("accepted for \(id) (\(by)): \(LayoutSuggestion.layout.title) saved for the game")
    }
}

/// The toast's own view over the game (GameSurfaceView, above the controls): it takes touches
/// only on its card, and only while it shows.
final class LayoutSuggestionToast: UIView {
    private let card = UIView()
    private let label = UILabel()
    private let use = UIButton(type: .system)
    private let notNow = UIButton(type: .system)

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        card.backgroundColor = UIColor(red: 21 / 255, green: 26 / 255, blue: 33 / 255, alpha: 0.92)
        card.layer.cornerRadius = 16
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(red: 42 / 255, green: 51 / 255, blue: 64 / 255, alpha: 1).cgColor
        card.alpha = 0
        card.isHidden = true
        label.text = "This game doesn't seem to read a controller."
        label.font = .systemFont(ofSize: 13)
        label.textColor = UIColor(red: 201 / 255, green: 209 / 255, blue: 220 / 255, alpha: 1)
        style(use, "Use Keyboard & mouse", fill: UIColor(red: 245 / 255, green: 181 / 255, blue: 68 / 255, alpha: 0.95),
              text: UIColor(red: 26 / 255, green: 18 / 255, blue: 4 / 255, alpha: 1))
        style(notNow, "Not now", fill: UIColor(white: 1, alpha: 0.10), text: UIColor(red: 238 / 255, green: 241 / 255, blue: 245 / 255, alpha: 0.94))
        use.addAction(UIAction { _ in MainActor.assumeIsolated { SuggestedLayout.shared.answer(accept: true, by: "tap") } }, for: .touchUpInside)
        notNow.addAction(UIAction { _ in MainActor.assumeIsolated { SuggestedLayout.shared.answer(accept: false, by: "tap") } }, for: .touchUpInside)
        card.addSubview(label)
        card.addSubview(use)
        card.addSubview(notNow)
        addSubview(card)
        SuggestedLayout.shared.view = self
        if SuggestedLayout.shared.showing { show() }
    }

    required init?(coder: NSCoder) { fatalError("LayoutSuggestionToast is created in code") }

    private func style(_ b: UIButton, _ title: String, fill: UIColor, text: UIColor) {
        b.setTitle(title, for: .normal)
        b.setTitleColor(text, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        b.backgroundColor = fill
        b.layer.cornerRadius = 15
    }

    /// A button's width: its title and 14 pt each side.
    private func width(_ b: UIButton) -> CGFloat {
        guard let label = b.titleLabel, let text = label.text, let font = label.font else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 28
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !card.isHidden && card.frame.contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.inset(by: gameSafeInsets)
        let text = label.sizeThatFits(CGSize(width: 400, height: 20))
        let u = width(use), n = width(notNow)
        let buttons = u + 8 + n
        let width = min(max(text.width, buttons) + 28, area.width - 24)
        card.frame = CGRect(x: area.midX - width / 2, y: area.minY + 8, width: width, height: 84)
        label.frame = CGRect(x: 14, y: 10, width: width - 28, height: 20)
        label.textAlignment = .center
        let x = (width - buttons) / 2
        use.frame = CGRect(x: x, y: 42, width: u, height: 30)
        notNow.frame = CGRect(x: x + u + 8, y: 42, width: n, height: 30)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    func show() {
        card.isHidden = false
        setNeedsLayout()
        UIView.animate(withDuration: 0.25) { self.card.alpha = 1 }
    }

    func hide() {
        UIView.animate(withDuration: 0.25, animations: { self.card.alpha = 0 }) { _ in
            MainActor.assumeIsolated { if !SuggestedLayout.shared.showing { self.card.isHidden = true } }
        }
    }
}
#endif
