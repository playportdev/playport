// SPDX-License-Identifier: GPL-3.0-or-later
// The product UI's frame (docs/design/2026-09-28-gamepad-ui/), landscape and
// driven by a controller: a top bar with Home, Library and Downloads (LB and
// RB), the Downloads badge, the controller's battery and the gear for
// Settings (≡); the page; and a footer naming what each button does, each
// entry also a tap. Presses come from PadRouter; directions and A go to the
// focus ring (PadFocus), the rest to the footer's entries. Touch works
// everywhere. A title's landscape screen replaces all of it (TitleLaunch).
//
// Settings (SettingsView.swift) replaces the whole frame: its list and a
// section, B back to the list and out. Downloads (DownloadsView.swift) names
// its own Y and X for the ringed job, and Download mode covers the whole
// frame, woken by any press. The game page (GameDetailView.swift) names its
// own buttons: A on the ringed control, X Game options, B back; in the
// options panel Y puts the ringed setting back to its default. The first-run
// checklist (SetupView.swift) replaces the pages on a first run or from
// Settings › Setup check. Sign in to Steam (SignInView.swift) covers
// whichever of them opened it.

import HostIOKit
import PlayportKit
import SwiftUI
import UniformTypeIdentifiers

struct AppShell: View {
    typealias Page = AppNavigation.Page

    @StateObject private var model = SteamAccountModel()
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var nav = AppNavigation.shared
    @ObservedObject private var focus = PadFocus.shared
    @ObservedObject private var setup = JitSetup.shared
    @ObservedObject private var grid = LibraryGrid.shared
    @ObservedObject private var modal = PadModal.shared
    @ObservedObject private var gamePage = GamePageState.shared
    @ObservedObject private var setupState = SetupState.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            if !nav.settings && !nav.setup && !nav.signIn && !nav.onGamePage { TopBar(installs: model.installs) }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !panelUp {
                PadFooter(hints: hints).overlay(alignment: .leading) {
                    // The checklist's grey note at the left (Setup.dc.html).
                    if onSetup, !modal.isUp { Text(SetupView.footerNote).font(.system(size: 12)).foregroundStyle(PP.muted).padding(.leading, 44) }
                    if nav.signIn, !modal.isUp { Text(SignInView.footerNote).font(.system(size: 12)).foregroundStyle(PP.muted).padding(.leading, 44) }
                }
                // A picker or the keyboard draws its own footer; this one would show
                // through its scrim beside it. Hidden, not removed, so the page keeps its height.
                .opacity(modal.isUp ? 0 : 1)
                .padding(.bottom, Self.footerBottom)
            }
        }
        // The footer sits low, in the home indicator's inset, on every page.
        .ignoresSafeArea(.container, edges: .bottom)
        // Under a game page's panel the footer sits at the left, beside it (GameOptions.dc.html).
        .overlay(alignment: .bottomLeading) {
            // A picker over it draws its own there.
            if panelUp, !modal.isUp {
                PadFooter(hints: hints, leading: true).frame(maxWidth: .infinity).padding(.trailing, 410)
                    .padding(.bottom, Self.footerBottom)
            }
        }
        .background(PP.background.ignoresSafeArea())
        // The controller keyboard or a picker, over everything with its own footer.
        .overlay { PadModalHost().animation(.easeOut(duration: 0.15), value: modal.isUp) }
        // Download mode: black, over everything, until a button or a tap (DownloadsView.swift).
        .overlay { DownloadModeView(installs: model.installs) }
        .padFocusRoot()
        .onReceive(PadRouter.shared.presses) { press($0) }
        // Choosing a pairing file (the checklist's step on iOS 26, Setup check's import): touch only, as Files is.
        .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .xml, .data]) {
            BuiltInJitStatus.shared.importPairingFile($0)
        }
        .onReceive(SettingsImport.requests) { importing = true }
        .environmentObject(model)
        .preferredColorScheme(.dark)
        .tint(PP.accent)
        .onAppear {
            PadRouter.shared.start()
            DownloadDimmer.shared.start(installs: model.installs)
            if scenePhase == .active { model.sceneBecameActive() }
            library.refresh()
            // Built-in JIT's readiness check, once per launch, so Play rarely waits for the DDI mount.
            BuiltInJitStatus.shared.checkOnce()
            // A first run: the checklist (UI/SetupView.swift).
            SetupState.shared.showAtStartIfFirstRun()
            #if !PLAYPORT_RELEASE
            UIDriver.startIfRequested()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.sceneBecameActive()
                library.refresh()
            } else {
                model.sceneLeftActive()
                DownloadDimmer.shared.sceneLeftActive()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if nav.signIn {
            SignInView()
        } else if nav.settings {
            SettingsView()
        } else if nav.setup {
            SetupView()
        } else {
            switch nav.page {
            case .home: HomeView(installs: model.installs)
            case .library: LibraryView(installs: model.installs)
            case .downloads: DownloadsPage(installs: model.installs)
            }
        }
    }

    /// The footer's distance from the screen's bottom edge, inside the home indicator's inset.
    static let footerBottom: CGFloat = 9

    /// Game options or the achievements over a game page: the panel runs to the bottom.
    private var panelUp: Bool { nav.onGamePage && !nav.gamePanels.isEmpty }

    /// The first-run checklist is the screen (not Settings over it).
    private var onSetup: Bool { nav.setup && !nav.settings && !nav.signIn }

    // MARK: buttons

    /// The footer: what each button does here.
    private var hints: [PadHint] {
        if nav.signIn { return SignInState.shared.hints(model) }
        if nav.onGamePage { return gamePageHints }
        if onSetup { return SetupView.hints() }
        var h: [PadHint] = []
        if let a = focus.hint, !a.isEmpty {
            h.append(PadHint(button: .a, label: a) { focus.activate() })
        }
        if nav.settings {
            // Settings.dc.html: A on the ringed row, B back to the list, then out.
            return h + [PadHint(button: .b, label: SettingsRing.backLabel) { _ = SettingsRing.press(.b) }]
        }
        if nav.page == .downloads {
            h += DownloadsPage.hints(model.installs, focused: focus.focused)
            // Main sections switch with LB/RB; B never leaves this page.
            return h + [PadHint(button: .menu, label: "Settings") { _ = nav.open("settings") }]
        }
        if !nav.settings, nav.page == .library {
            let grid = LibraryGrid.shared
            h.append(PadHint(button: .view, label: "Filter & sort") { grid.openFilterSort() })
            h.append(PadHint(button: .y, label: "Search") { grid.openSearch() })
            if !grid.search.isEmpty {
                h.append(PadHint(button: .b, label: "Clear search") { grid.clearSearch() })
                return h + [PadHint(button: .menu, label: "Settings") { _ = nav.open("settings") }]
            }
        }
        if nav.canGoBack {
            h.append(PadHint(button: .b, label: "Back") { _ = nav.back() })
        }
        if !nav.settings {
            h.append(PadHint(button: .menu, label: "Settings") { _ = nav.open("settings") })
        }
        return h
    }

    /// The game page's footer (Game.dc.html, GameOptions.dc.html): A on the ringed control, X
    /// its Game options (or the version, for a game not installed), B its origin; in the
    /// options panel Y puts the ringed setting back to its default and B closes it.
    private var gamePageHints: [PadHint] {
        var h: [PadHint] = []
        if nav.gamePanels.last != .achievements, let a = focus.hint, !a.isEmpty {
            h.append(PadHint(button: .a, label: a) { focus.activate() })
        }
        switch nav.gamePanels.last {
        case .options?:
            if focus.canReset { h.append(PadHint(button: .y, label: "Back to default") { focus.resetFocused() }) }
            h.append(PadHint(button: .b, label: "Close") { _ = nav.back() })
        case .achievements?:
            h.append(PadHint(button: .b, label: nav.gamePanels.count > 1 ? "Game options" : "Close") { _ = nav.back() })
        case nil:
            if let x = gamePage.x { h.append(PadHint(button: .x, label: x.label, action: x.action)) }
            h.append(PadHint(button: .b, label: nav.gameBackLabel) { _ = nav.back() })
        }
        return h
    }

    private func press(_ b: NavButton) {
        // Download mode: any button wakes it, and does nothing else.
        let dimmer = DownloadDimmer.shared
        if dimmer.dimmed { return dimmer.wake() }
        dimmer.input()
        // A sheet over the shell (JIT setup) has the screen; alerts take touch only.
        guard !setup.presented else { return }
        // The system share sheet (Report a problem, a dev build's logs): B closes it.
        if ProblemReport.sheetUp { return ProblemReport.sheetPress(b) }
        // The controller keyboard or a picker takes every press while it is up.
        if modal.isUp { return modal.press(b) }
        // Sign in to Steam covers everything under it (UI/SignInView.swift).
        if nav.signIn { return SignInState.shared.press(b, model) }
        // Settings keeps the ring on its list or in the shown section (SettingsView.swift).
        if nav.settings, SettingsRing.press(b) { return }
        // The checklist: its steps with left and right or LB and RB (UI/SetupView.swift).
        if onSetup, SetupRing.press(b) { return }
        switch b {
        case .up: focus.move(.up)
        case .down: focus.move(.down)
        case .left: focus.move(.left)
        case .right: focus.move(.right)
        case .a: focus.activate()
        case .lb, .rb:
            guard !nav.settings, !nav.onGamePage else { return }
            nav.step(b == .lb ? -1 : 1)
        default:
            hints.first { $0.button == b }?.action()
        }
    }
}

/// LB, the three pages, RB; the controller and its battery; the gear.
private struct TopBar: View {
    @ObservedObject var installs: SteamInstalls
    @ObservedObject private var nav = AppNavigation.shared
    @ObservedObject private var router = PadRouter.shared

    var body: some View {
        HStack(spacing: 6) {
            Button { router.send(.lb) } label: { PadGlyph(button: .lb) }.buttonStyle(.plain)
            ForEach(AppNavigation.Page.allCases, id: \.self) { p in
                Button { nav.show(p) } label: {
                    // The Downloads count sits in the page's pill, highlighted with it.
                    HStack(spacing: 5) {
                        Text(p.title)
                            .font(PP.display(15, .semibold))
                            .foregroundStyle(nav.page == p ? PP.background : PP.muted)
                        if p == .downloads, !installs.jobs.isEmpty {
                            Text("\(installs.jobs.count)")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(PP.background)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(PP.accent, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(nav.page == p ? PP.text : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("page-\(p.rawValue)")
            }
            Button { router.send(.rb) } label: { PadGlyph(button: .rb) }.buttonStyle(.plain)
            Spacer(minLength: 8)
            if nav.page == .downloads {
                StorageBar()
            } else {
                HStack(spacing: 6) {
                    Image(systemName: router.controller == nil ? "gamecontroller" : "gamecontroller.fill")
                    Text(controllerText).lineLimit(1)
                }
                .font(.system(size: 13)).foregroundStyle(PP.muted)
            }
            Button { _ = nav.open("settings") } label: {
                Image(systemName: "gearshape").font(.system(size: 15))
                    .foregroundStyle(PP.soft)
                    .frame(width: 30, height: 30)
                    .background(PP.raised, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)
            .accessibilityLabel("Settings")
        }
        .frame(height: 48)
    }

    private var controllerText: String {
        guard let c = router.controller else { return "No controller" }
        guard let b = c.battery else { return c.name }
        return "\(c.name) \(b)%" + (c.charging ? " ⚡︎" : "")
    }
}
