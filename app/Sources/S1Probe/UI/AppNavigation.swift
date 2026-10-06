// SPDX-License-Identifier: GPL-3.0-or-later
// SwiftUI/focus adapter for PlayportKit.AppRoutes. The shell, controller and
// dev UI driver all use these transitions; origins are owned by the router,
// never by a destination view's onDisappear.

import PlayportKit
import SwiftUI

@MainActor
final class AppNavigation: ObservableObject {
    typealias Page = AppRoutes.Page
    typealias GamePanel = AppRoutes.GamePanel

    static let shared = AppNavigation()
    @Published private var routes = AppRoutes()
    /// A dev driver's game-options section or Settings section to reveal.
    @Published var pageSection: String?

    var page: Page { routes.page }
    var settings: Bool { routes.settings }
    var setup: Bool { routes.setup }
    var signIn: Bool { routes.signIn }
    var licences: [LicencePage] { routes.licences }
    var onGamePage: Bool { routes.onGamePage }
    var canGoBack: Bool { routes.canGoBack && (signIn || !setupBlocksLeaving) }
    private var setupBlocksLeaving: Bool { setup && !SetupState.shared.canLeave }
    var gameBackLabel: String { routes.gameBackLabel }
    var focusStart: String? { routes.focusStart }
    var settingsSection: SettingsSection {
        get { routes.settingsSection }
        set { routes.settingsSection = newValue }
    }
    var gamePanels: [GamePanel] {
        get { routes.gamePanels }
        set { routes.gamePanels = newValue }
    }
    /// Bound to the Library's NavigationStack; a native pop restores the same
    /// origin as the controller/footer Back, including Home or Settings.
    var gamePath: [GameRef] {
        get { routes.gamePath }
        set {
            guard newValue != routes.gamePath else { return }
            if newValue.isEmpty {
                let wasSetup = setup
                routes.closeGame()
                transitioned(wasSetup: wasSetup)
            } else if let ref = newValue.last {
                openGame(ref)
            }
        }
    }

    static let screens = ["home", "library", "games", "downloads", "settings", "account", "setup", "signin"]

    @discardableResult
    func open(_ screen: String) -> Bool {
        switch screen {
        case "games":
            show(.library)
            LibraryGrid.shared.filter = .steam
        case "settings", "account":
            openSettings(section: screen == "account" ? .accounts : nil)
        case "setup":
            openSetup()
        case "signin":
            SignInState.shared.open(preview: SteamAccountModel.current?.state.account != nil)
        default:
            guard let p = Page(rawValue: screen) else { return false }
            show(p)
            if p == .library { LibraryGrid.shared.filter = .all }
        }
        return true
    }

    func openLicence(_ page: LicencePage) {
        routes.openLicence(page)
        PadFocus.shared.reset(start: page.firstItem)
    }

    func closeLicence() {
        guard let page = routes.closeLicence() else { return }
        PadFocus.shared.reset(start: page.row)
    }

    func closeLicences() { routes.closeLicences() }

    func showLicences(_ pages: [LicencePage] = []) {
        if signIn { closeSignIn() }
        openSettings(section: .about)
        closeLicences()
        for page in [LicencePage.list] + pages { openLicence(page) }
    }

    func show(_ p: Page) {
        guard !setupBlocksLeaving else { return }
        let wasSetup = setup
        if routes.show(p, focus: PadFocus.shared.focused) { transitioned(wasSetup: wasSetup) }
    }

    /// Also used for a link from one Settings section to another, so Back can
    /// return to the section/row that opened it (unlike choosing the sidebar).
    func openSettings(section: SettingsSection? = nil) {
        guard !setupBlocksLeaving else { return }
        let wasSetup = setup
        if routes.openSettings(section: section, focus: PadFocus.shared.focused) { transitioned(wasSetup: wasSetup) }
    }

    func openSetup(on step: SetupStep? = nil) {
        let wasSetup = setup
        let start = step ?? SetupChecklist.firstTodo(SetupState.shared.shown)
        if routes.openSetup(on: start, focus: PadFocus.shared.focused) {
            transitioned(wasSetup: wasSetup)
        } else {
            PadFocus.shared.ring(start.item)
        }
    }

    func openTitle(_ id: String, options: Bool = false) {
        openGame(.title(id))
        if options { gamePanels = [.options] }
    }

    func openGame(_ ref: GameRef) {
        guard !setupBlocksLeaving else { return }
        let wasSetup = setup
        // The game page appears in place: no NavigationStack slide.
        if Self.instant({ routes.openGame(ref, focus: PadFocus.shared.focused) }) { transitioned(wasSetup: wasSetup) }
    }

    /// A route change with no animation (the game page's push and pop).
    private static func instant<T>(_ change: () -> T) -> T {
        var t = Transaction()
        t.disablesAnimations = true
        return withTransaction(t, change)
    }

    func step(_ by: Int) {
        let all = Page.allCases
        let i = all.firstIndex(of: page) ?? 0
        show(all[(i + by + all.count) % all.count])
    }

    func openSignIn() {
        let wasSetup = setup
        if routes.openSignIn(focus: PadFocus.shared.focused) { transitioned(wasSetup: wasSetup) }
    }

    func closeSignIn() { if signIn { _ = back() } }

    @discardableResult
    func back() -> Bool {
        // Steam can always cancel/return to setup, but an unfinished first run
        // cannot pop the checklist itself (footer, controller or native Back).
        guard signIn || !setupBlocksLeaving else { return false }
        if settings && !signIn && !licences.isEmpty {
            closeLicence()
            return true
        }
        // GameDetailView restores focus within its panels itself.
        if onGamePage && !gamePanels.isEmpty { return routes.back() }
        let wasSetup = setup
        guard onGamePage ? Self.instant({ routes.back() }) : routes.back() else { return false }
        transitioned(wasSetup: wasSetup)
        return true
    }

    private func transitioned(wasSetup: Bool) {
        pageSection = nil
        if wasSetup && !setup { SetupState.shared.leftChecklist() }
        let start = routes.focusStart ?? (signIn ? SignInView.startItem
            : settings ? settingsSection.navItem
            : setup ? routes.setupStart.item : nil)
        PadFocus.shared.reset(start: start)
    }
}
