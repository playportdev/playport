// SPDX-License-Identifier: GPL-3.0-or-later
// A web page a running game opened (decision 0064), in a panel over the game.
//
// UrlOpenerHost hands it a checked request (PlayportKit UrlOpenRequest). The
// game keeps running behind it, with its input held (HostIO.holdGuest: its
// pads rest, keys, touches and the mouse stop, its audio pauses) but its
// threads not paused: a game polls its own sign-in, and sees it done without
// waiting for the panel to close. Close (or B) gives it its input back.
//
// - Epic's sign-in page (`www.epicgames.com/activate?userCode=…`) on an Epic
//   game's play opens at once, signed in to Epic: a fresh exchange code from the
//   host's Epic session goes, in the first request only, to Epic's
//   `/id/exchange?exchangeCode=…&redirectUrl=<the page>`, so the player has only
//   the game's consent to give. The panel stays on https epicgames.com;
//   any other top-level navigation is cancelled. Without the code (Epic signed
//   out, no network) the page opens as it is, and Epic asks the player to sign in.
//   Epic's pages get desktop Safari's user agent: with a phone's, Epic's consent page
//   drops the session and asks for a password again (measured with WebKit on the
//   workstation, the same device flow: authorize, then /id/login/switch-account).
// - Any other page asks first ("<game> wants to open <host>": Open or Not now)
//   and opens with no sign-in.
//
// Each panel has its own non-persistent website data store: its cookies live
// in WebKit's network process and end with the panel; the host's Epic tokens
// never enter it. The bar shows the page's host only. Nothing opens Safari:
// Playport would go to the background mid-game.

import ContentKit
import EpicClientKit
import HostIOKit
import PlayportKit
import SwiftUI
import UIKit
import WebKit

@MainActor
final class GameWebSheet: ObservableObject {
    static let shared = GameWebSheet()

    struct Shown: Equatable {
        let request: UrlOpenRequest
        let title: String
        /// Epic's sign-in page on an Epic game's play: opened signed in to Epic.
        let epicSignIn: Bool
        /// The player chose Open (an Epic sign-in page needs no choice).
        var confirmed: Bool
    }

    /// What is up; nil when nothing is.
    @Published private(set) var shown: Shown?
    /// The page's host as the web view has it now.
    @Published private(set) var host = ""
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    /// "Signed in to Epic", or why not, for the bar.
    @Published private(set) var signInNote: String?
    /// The first request, once known: the page, or Epic's exchange sign-in that leads to it.
    /// Taken (set to nil) by the web view that loads it.
    private(set) var firstLoad: Secret<URL>?
    @Published private(set) var loadSerial = 0
    /// Top-level navigations stay on https epicgames.com (a signed-in panel).
    private(set) var lockedToEpic = false
    /// The panel's web view, while it is up (Back, and a dev build's driver).
    weak var webView: WKWebView?
    /// Pages finished loading since the panel opened, and the last one's address (never logged
    /// with its query). The dev driver waits on them.
    private(set) var finishedLoads = 0
    private(set) var lastPage: URL?
    private var nav = PadNavigation()
    private var shownAt = Date.distantPast

    var isUp: Bool { shown != nil }

    /// Desktop Safari's user agent, for Epic's sign-in pages (see the top of the file).
    nonisolated static let desktopAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"

    func log(_ line: String) { UrlOpenerHost.log.info("sheet", line) }

    /// A request from UrlOpenerHost, on the main actor.
    func present(_ request: UrlOpenRequest, _ play: UrlOpenerHost.Play) {
        let launch = TitleLaunch.shared
        guard launch.running, !InGameMenu.shared.isOpen, shown == nil else {
            log("not shown: \(launch.running ? "the in-game menu or another page is up" : "no game is running")")
            UrlOpenerHost.sheetClosed()
            return
        }
        let epic = request.kind == .epicActivation && play.epicSignIn
        shown = Shown(request: request, title: play.title, epicSignIn: epic, confirmed: request.kind == .epicActivation)
        host = request.host
        loading = false
        canGoBack = false
        signInNote = nil
        firstLoad = nil
        lockedToEpic = false
        finishedLoads = 0
        lastPage = nil
        nav.reset()
        shownAt = Date()
        HostIO.shared.holdGuest()
        log("up over \(play.title): \(request.host) (\(request.kind.rawValue)\(epic ? ", Epic sign-in" : ""))")
        if shown?.confirmed == true { start() }
    }

    /// Open on the confirm card.
    func confirm() {
        guard var s = shown, !s.confirmed else { return }
        s.confirmed = true
        shown = s
        log("opened by the player")
        start()
    }

    /// Close, B, Not now, or the game's end: the game gets its input back.
    func close(_ why: String) {
        guard shown != nil else { return }
        shown = nil
        firstLoad = nil
        webView = nil
        HostIO.shared.releaseGuest()
        UrlOpenerHost.sheetClosed()
        log("closed (\(why)) after \(finishedLoads) page(s)")
    }

    /// The launch ended (TitleLaunch.end).
    func gameEnded() { close("the game ended") }

    /// A pad's snapshot while the panel is up (HostIO.menuInput): A opens from the
    /// confirm card, B closes. The buttons held as it came up are not presses.
    func padInput(_ p: PadInput) {
        let presses = nav.update(p, at: ProcessInfo.processInfo.systemUptime)
        guard Date().timeIntervalSince(shownAt) > 0.3 else { return }
        for b in presses { press(b) }
    }

    func press(_ b: NavButton) {
        guard let s = shown else { return }
        switch b {
        case .a where !s.confirmed: confirm()
        case .b: close(s.confirmed ? "B" : "not now")
        default: break
        }
    }

    // MARK: the web view's reports (GameWebView)

    func taken() { firstLoad = nil }

    func pageChanged(_ view: WKWebView) {
        host = view.url?.host ?? host
        canGoBack = view.canGoBack
        loading = view.isLoading
    }

    func finished(_ view: WKWebView) {
        finishedLoads += 1
        lastPage = view.url
        pageChanged(view)
        #if !PLAYPORT_RELEASE
        if let u = view.url { log("page \(u.host ?? "?")\(u.path)") }
        #endif
    }

    /// Whether a top-level navigation may go ahead.
    func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if url.absoluteString == "about:blank" { return true }
        guard lockedToEpic else { return scheme == "http" || scheme == "https" }
        let host = url.host?.lowercased() ?? ""
        return scheme == "https" && (host == "epicgames.com" || host.hasSuffix(".epicgames.com"))
    }

    func refused(_ url: URL) {
        log("navigation to \(url.host ?? url.scheme ?? "?") cancelled" + (lockedToEpic ? " (outside epicgames.com)" : ""))
    }

    // MARK: the first request

    private func start() {
        guard let s = shown else { return }
        guard s.epicSignIn else {
            load(s.request.url, locked: false)
            return
        }
        signInNote = "Signing in to Epic…"
        Task { @MainActor in
            let code = await Self.exchangeCode()
            guard self.shown?.request == s.request else { return }
            if let code, let url = s.request.epicSignInURL(exchangeCode: code.value) {
                signInNote = "Signed in to Epic"
                log("signed in to Epic for the page (exchange code fetched)")
                load(url, locked: true)
            } else {
                signInNote = "Not signed in to Epic"
                log("opened without Epic's sign-in: no exchange code")
                load(s.request.url, locked: false)
            }
        }
    }

    private func load(_ url: URL, locked: Bool) {
        lockedToEpic = locked
        firstLoad = Secret(url)
        loadSerial += 1
    }

    /// A fresh exchange code from the host's Epic session: 10 s, one retry; nil when
    /// Epic is signed out or cannot be reached.
    private static func exchangeCode() async -> Secret<String>? {
        let session = EpicAccount.shared.session
        guard await session.state == .signedIn else { return nil }
        for _ in 0..<2 {
            let code = await withTaskGroup(of: Secret<String>?.self) { group in
                group.addTask { try? await session.exchangeCode() }
                group.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if let code { return code }
        }
        return nil
    }

}

// MARK: the panel

struct GameWebSheetView: View {
    @ObservedObject private var sheet = GameWebSheet.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // The game shows dimmed around the panel; touches stop here.
                Color.black.opacity(0.6).ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
                if let s = sheet.shown {
                    VStack(spacing: 0) {
                        bar(s)
                        Divider()
                        if s.confirmed {
                            ZStack {
                                GameWebView(serial: sheet.loadSerial)
                                if sheet.firstLoad == nil && sheet.finishedLoads == 0 {
                                    ProgressView(sheet.signInNote ?? "Loading…").tint(.white).foregroundStyle(.white)
                                }
                            }
                        } else {
                            confirmCard(s)
                        }
                    }
                    .frame(width: geo.size.width * 0.9, height: geo.size.height * 0.92)
                    .background(Color(white: 0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private func bar(_ s: GameWebSheet.Shown) -> some View {
        HStack(spacing: 12) {
            Button {
                sheet.webView?.goBack()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!sheet.canGoBack)
            Image(systemName: "lock.fill").font(.footnote).foregroundStyle(.secondary)
            Text(sheet.host).font(.subheadline.monospaced()).lineLimit(1).truncationMode(.middle)
            if sheet.loading { ProgressView().controlSize(.small) }
            Spacer()
            if let note = sheet.signInNote {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            Button("Close") { sheet.close("Close") }
                .font(.body.weight(.semibold))
            Text("Ⓑ").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
        .tint(.white)
    }

    private func confirmCard(_ s: GameWebSheet.Shown) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "safari").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("\(s.title) wants to open a web page").font(.title3.weight(.semibold))
            Text(s.request.host).font(.body.monospaced()).foregroundStyle(.secondary)
            Text("It opens here, over the game, signed in to nothing.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button("Not now  Ⓑ") { sheet.press(.b) }
                    .buttonStyle(.bordered)
                Button("Open  Ⓐ") { sheet.confirm() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .tint(.white)
        .frame(maxWidth: .infinity)
    }
}

/// The panel's WKWebView: its own non-persistent data store, the first request
/// as GameWebSheet gives it, and the navigation rules it keeps.
struct GameWebView: UIViewRepresentable {
    /// Bumped when the sheet has a first request to load.
    let serial: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        if GameWebSheet.shared.shown?.request.kind == .epicActivation { view.customUserAgent = GameWebSheet.desktopAgent }
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .black
        context.coordinator.observe(view)
        GameWebSheet.shared.webView = view
        loadIfNeeded(view, context)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) { loadIfNeeded(view, context) }

    private func loadIfNeeded(_ view: WKWebView, _ context: Context) {
        let sheet = GameWebSheet.shared
        guard context.coordinator.loaded != serial, let first = sheet.firstLoad else { return }
        context.coordinator.loaded = serial
        sheet.taken()
        view.load(URLRequest(url: first.value))
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        coordinator.observations = []
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loaded = 0
        var observations: [NSKeyValueObservation] = []

        func observe(_ view: WKWebView) {
            let changed: (WKWebView) -> Void = { v in
                DispatchQueue.main.async { MainActor.assumeIsolated { GameWebSheet.shared.pageChanged(v) } }
            }
            observations = [
                view.observe(\.url) { v, _ in changed(v) },
                view.observe(\.isLoading) { v, _ in changed(v) },
                view.observe(\.canGoBack) { v, _ in changed(v) },
            ]
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            let sheet = GameWebSheet.shared
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            // Subresources and frames are the page's own; the rules are for what the panel shows.
            if let frame = action.targetFrame, !frame.isMainFrame { return decisionHandler(.allow) }
            #if !PLAYPORT_RELEASE
            sheet.log("navigation to \(url.host ?? url.scheme ?? "?")\(url.path)")
            #endif
            if sheet.allows(url) { return decisionHandler(.allow) }
            sheet.refused(url)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            GameWebSheet.shared.finished(webView)
        }

        /// A link that opens a new window opens in the panel, under the same rules.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, GameWebSheet.shared.allows(url) { webView.load(action.request) }
            return nil
        }
    }
}
