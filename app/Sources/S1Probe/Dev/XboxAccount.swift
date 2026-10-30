// SPDX-License-Identifier: GPL-3.0-only
// Xodus 514dd56f360a4bdf12f4acde5148bac5ce5f957f webview.rs and login.rs;
// translated to Swift by the Playport authors, 2026-10-30. Modified: 0058's
// non-persistent WKWebView, origin-checked main-frame script messages, dev only.
import Combine
import ContentKit
import Foundation
import SwiftUI
import UIKit
import WebKit
import XboxClientKit

enum XboxAccountState { case unknown, signedOut, signedIn }

@MainActor
final class XboxAccount: ObservableObject {
    static let shared = XboxAccount()
    @Published private(set) var state = XboxAccountState.unknown
    @Published private(set) var error: String?
    @Published var signingIn = false
    @Published private(set) var page: XboxLoginPage?
    @Published private(set) var step = 0
    @Published private(set) var exchanging = false
    let session: XboxSession
    private var exchange: Task<Void, Never>?

    private init() {
        #if canImport(Security)
        let store = KeychainSecretStore(service: XboxSession.keychainService)
        #else
        let store = MemorySecretStore()
        #endif
        session = XboxSession(store: store, log: ContentKit.Logger { AppLog.append("xbox: " + $0) })
        Task { await restore() }
    }
    func restore() async {
        state = await session.state == .signedIn ? .signedIn : .signedOut
        guard state == .signedIn else { return }
        do { try await session.renew(); error = nil }
        catch XboxSessionError.signInRequired { state = .signedOut; error = XboxSessionError.signInRequired.description }
        catch { self.error = Self.message(error) }
    }
    func beginSignIn() { page = nil; error = nil; signingIn = true }
    func prepare() async {
        do {
            let page = try await session.prepareSignIn()
            guard signingIn, !Task.isCancelled else { return }
            self.page = page; step += 1; error = nil
        } catch { if signingIn, !Task.isCancelled { self.error = Self.message(error) } }
    }
    func received(_ token: XboxSignInToken) {
        guard exchange == nil else { return }
        exchanging = true
        exchange = Task {
            defer { exchanging = false; exchange = nil }
            do {
                let result = try await session.signIn(token)
                guard signingIn, !Task.isCancelled else { return }
                switch result {
                case .signedIn: state = .signedIn; error = nil; signingIn = false; page = nil
                case let .continueAt(next): page = next; step += 1
                }
            } catch { if signingIn, !Task.isCancelled { self.error = Self.message(error) } }
        }
    }
    func closeSignIn() { exchange?.cancel(); page = nil }
    func signOut() async {
        exchange?.cancel()
        do { try await session.signOut(); state = .signedOut; error = nil; signingIn = false; page = nil }
        catch { self.error = Self.message(error) }
    }
    func resetDevice() async {
        exchange?.cancel()
        do { try await session.resetDevice(); state = .signedOut; error = nil; signingIn = false; page = nil }
        catch { self.error = Self.message(error) }
    }
    private static func message(_ error: Error) -> String {
        if let error = error as? XboxSessionError { return error.description }
        if let error = error as? XboxLicenseFailure { return error.description }
        if let error = error as? ClientError { return error.description }
        return "Xbox couldn't be reached. Try again."
    }
}

struct XboxAccountSettings: View {
    @ObservedObject private var account = XboxAccount.shared
    var body: some View {
        PadSectionHeader(text: "Xbox")
        switch account.state {
        case .unknown: SettingsInfoRow(id: "xbox:status", title: "Checking…", subtitle: nil)
        case .signedOut:
            SettingsInfoRow(id: "xbox:status", title: "Not signed in", subtitle: account.error ?? "Your Microsoft account. Xbox is in the dev app only.")
            PadRow(id: "set:xbox:signin", title: "Sign in to Xbox", subtitle: "On Microsoft's own sign-in page", accessory: .chevron,
                   hint: "Sign in") { account.beginSignIn() }
        case .signedIn:
            SettingsInfoRow(id: "xbox:status", title: "Signed in", subtitle: account.error ?? "Microsoft sign-in is kept in the Keychain on this phone only.")
            PadRow(id: "set:xbox:signout", title: "Sign out", subtitle: "Deletes Playport's Xbox session, not its synthetic Windows device.",
                   destructive: true, hint: "Sign out") {
                PadModal.shared.picker(title: "Sign out of Xbox?", context: "Settings · Accounts",
                    note: "Playport deletes its session secrets and stops issuing tickets. A game already signed in can keep its tickets until they expire. To end every session, use your Microsoft account's security page. The synthetic Windows device stays, so signing in again doesn't use another of the 10 Store devices.",
                    options: [PadOption(id: "keep", label: "Stay signed in"), PadOption(id: "out", label: "Sign out")], selected: "keep") {
                    if $0 == "out" { Task { await account.signOut() } }
                }
            }
        }
    }
}

struct XboxResetDeviceSettings: View {
    @ObservedObject private var account = XboxAccount.shared
    var body: some View {
        PadSectionHeader(text: "Xbox")
        PadRow(id: "set:xbox:resetDevice", title: "Reset Xbox device", subtitle: "Replaces the synthetic Windows device and signs out. The old device is not unlinked at Microsoft.",
               destructive: true, hint: "Reset") {
            PadModal.shared.picker(title: "Reset Xbox device?", context: "Settings · Developer",
                note: "This signs out of Xbox and creates a different synthetic Windows device. Microsoft Store allows 10 linked devices. Unlink the old one at account.microsoft.com/devices/content so it doesn't keep a slot.",
                options: [PadOption(id: "keep", label: "Keep device"), PadOption(id: "reset", label: "Reset device")], selected: "keep") {
                if $0 == "reset" { Task { await account.resetDevice() } }
            }
        }
    }
}

struct XboxSignInSheet: View {
    @ObservedObject private var account = XboxAccount.shared
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text(XboxSignIn.passkeyNote).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                if let error = account.error { Text(error).font(.footnote).foregroundStyle(.orange).padding(.horizontal) }
                if account.exchanging { ProgressView("Completing sign-in…") }
                if let page = account.page {
                    XboxLoginWebView(page: page, step: account.step, done: account.received)
                } else if account.error == nil { ProgressView("Preparing Xbox sign-in…").frame(maxHeight: .infinity) }
                else { Spacer() }
            }
            .navigationTitle("Sign in to Xbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { account.signingIn = false } }
                if account.error != nil { ToolbarItem(placement: .primaryAction) { Button("Try again") { Task { await account.prepare() } } } }
            }
            .task { await account.prepare() }
            .onAppear { AppDelegate.allowsPortrait = true }
            .onDisappear { AppDelegate.allowsPortrait = false; account.closeSignIn() }
        }
    }
}

struct XboxLoginWebView: UIViewRepresentable {
    let page: XboxLoginPage
    let step: Int
    let done: (XboxSignInToken) -> Void
    func makeCoordinator() -> XboxWebCoordinator { XboxWebCoordinator(done: done) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent() // 0058: same cookies for both hosted legs, none after dismissal.
        config.userContentController.add(context.coordinator, name: "xbox")
        config.userContentController.addUserScript(WKUserScript(source: XboxSignIn.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = XboxSignIn.userAgent
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        load(view, context.coordinator)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { if context.coordinator.loaded != step { load(view, context.coordinator) } }
    static func dismantleUIView(_ view: WKWebView, coordinator: XboxWebCoordinator) {
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "xbox")
        view.configuration.userContentController.removeAllUserScripts(); view.navigationDelegate = nil
    }
    private func load(_ view: WKWebView, _ coordinator: XboxWebCoordinator) {
        coordinator.loaded = step; coordinator.finished = false
        var request = URLRequest(url: page.url)
        for (name, value) in page.headers { request.setValue(value, forHTTPHeaderField: name) }
        view.load(request)
    }
}

@MainActor
final class XboxWebCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let done: (XboxSignInToken) -> Void
    weak var view: WKWebView?
    var loaded = 0
    var finished = false
    init(done: @escaping (XboxSignInToken) -> Void) { self.done = done }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let url = message.frameInfo.request.url, let text = message.body as? String,
              !finished, let result = try? XboxSignIn.receive(Secret(text), from: url) else { return }
        switch result {
        case .ignored: break
        case let .script(script): view?.evaluateJavaScript(script, completionHandler: nil)
        case let .token(token):
            finished = true
            view?.loadHTMLString("", baseURL: nil) // Don't leave ServerData/tickets visible while exchanging.
            done(token)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished, let url = webView.url, XboxSignIn.isHandoff(url) else { return }
        webView.evaluateJavaScript(XboxSignIn.handoffScript, completionHandler: nil)
    }
}

/// A dev-only sheet presenter on AppShell's overlay. No Xbox reference or
/// dependency is compiled into the release shell.
struct XboxSignInPresenter: View {
    @ObservedObject private var account = XboxAccount.shared
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: $account.signingIn) { XboxSignInSheet() }
    }
}
