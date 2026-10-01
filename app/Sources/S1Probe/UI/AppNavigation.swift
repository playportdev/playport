// SPDX-License-Identifier: GPL-3.0-or-later
// Where the product UI is (UI/AppShell.swift): Home, Library or Downloads,
// switched with LB and RB; Settings over them, behind ≡ or the gear; and the
// game page open over the Library, with its Game options panel and the
// achievements list over it (`gamePanels`); Sign in to Steam over any of
// them (`signIn`); Settings › About › Licences' pages over the About section
// (`licences`). The Library's chips, sort and search are LibraryGrid's. The views bind to it; a dev build's
// UIDriver sets it (`open:` actions, `open(_:)`).

import PlayportKit
import SwiftUI

@MainActor
final class AppNavigation: ObservableObject {
    enum GamePanel: String, Hashable {
        case options, achievements
    }

    enum Page: String, Hashable, CaseIterable {
        case home, library, downloads

        var title: String {
            switch self {
            case .home: "Home"
            case .library: "Library"
            case .downloads: "Downloads"
            }
        }
    }

    static let shared = AppNavigation()

    // Another screen starts its focus ring afresh, reset here before the new
    // screen reports its items (an onChange runs after they came).
    @Published var page = Page.home { didSet { if page != oldValue { PadFocus.shared.reset() } } }
    /// Settings, over whichever page was showing; B or Back closes it.
    /// It opens with the ring on the list's entry for `settingsSection`.
    @Published var settings = false {
        didSet {
            guard settings != oldValue else { return }
            if !settings { closeLicences() }
            PadFocus.shared.reset(start: settings ? settingsSection.navItem : nil)
        }
    }
    /// The Settings section shown at the right (SettingsView.swift); the ring on its
    /// entry in the list down the left picks it.
    @Published var settingsSection = SettingsSection.steam { didSet { if settingsSection != oldValue { closeLicences() } } }
    /// Settings › About › Licences (UI/LicencesView.swift): the pages shown in place of
    /// the About section, the top one last. B on one of their rows closes the top one;
    /// another section, and Settings closing, close them all.
    @Published private(set) var licences: [LicencePage] = []
    /// The first-run checklist (UI/SetupView.swift) in place of the pages; Settings
    /// can open over it (its Steam step). Leaving it once keeps it from opening by itself.
    @Published var setup = false {
        didSet {
            guard setup != oldValue else { return }
            PadFocus.shared.reset(start: setup ? setupStart.item : nil)
            if !setup { UserDefaults.standard.set(true, forKey: SetupState.leftKey) }
        }
    }
    /// Sign in to Steam (UI/SignInView.swift) over whatever opened it: Settings ›
    /// Steam account, the checklist's Steam step, or `open:signin`. B, a sign-in
    /// that ends signed in, and Not now go back there.
    @Published private(set) var signIn = false {
        didSet { if signIn != oldValue { PadFocus.shared.reset(start: signIn ? SignInView.startItem : signInReturn) } }
    }
    /// The ring's item to go back to when the sign-in closes.
    private var signInReturn: String?
    /// Where the checklist's ring starts, and whether B goes back to Settings › Setup check.
    private var setupStart = SetupStep.controller
    private var setupFromSettings = false
    /// The Library's navigation stack: the game page open over the grid.
    @Published var gamePath: [GameRef] = [] { didSet { if gamePath != oldValue { gamePanels = [] } } }
    /// The panels over the game page, the top one last: Game options, and the
    /// achievements list (from Game options or the page's button). B closes the top one.
    @Published var gamePanels: [GamePanel] = []
    /// A section of the open game page's options (graphics, game, files, developer; in a dev
    /// build also ordering, steam) to scroll to, or of Settings to show (SettingsSection.named);
    /// a dev build's `open:ID#SECTION` sets it.
    @Published var pageSection: String?

    /// The screens `open:` names in a dev build: the three pages, the Library on
    /// its All Steam games chip (`games`), Settings and its Steam account (`account`), and
    /// the first-run checklist (`setup`, as Settings › Setup check's first row opens it), and
    /// Sign in to Steam (`signin`: its preview while Steam is signed in, SignInState.open).
    /// Settings opens on the section it showed last (Steam account at first).
    static let screens = ["home", "library", "games", "downloads", "settings", "account", "setup", "signin"]

    /// Shows a screen `screens` names; false for any other name.
    func open(_ screen: String) -> Bool {
        switch screen {
        case "games":
            show(.library)
            gamePath = []
            LibraryGrid.shared.filter = .steam
        case "settings", "account":
            if screen == "account" { settingsSection = .steam }
            settings = true
        case "setup":
            openSetup(fromSettings: settings)
        case "signin":
            SignInState.shared.open(preview: SteamAccountModel.current?.state.account != nil)
        default:
            guard let p = Page(rawValue: screen) else { return false }
            show(p)
            if p == .library {
                gamePath = []
                LibraryGrid.shared.filter = .installed
            }
        }
        return true
    }

    /// A licences page over the About section (or the page before it), the ring on its first row.
    func openLicence(_ page: LicencePage) {
        licences.append(page)
        PadFocus.shared.reset(start: page.firstItem)
    }

    /// B on a licences page: the page under it, the ring back on the row that opened this one.
    func closeLicence() {
        guard let page = licences.popLast() else { return }
        PadFocus.shared.reset(start: page.row)
    }

    func closeLicences() { licences = [] }

    /// A dev build's `open:licences`: Settings › About › Licences, then `pages` over it
    /// (a component's files).
    func showLicences(_ pages: [LicencePage] = []) {
        signIn = false
        settingsSection = .about
        settings = true
        closeLicences()
        for page in [LicencePage.list] + pages { openLicence(page) }
    }

    /// A page, with Settings and the checklist closed.
    func show(_ p: Page) {
        signIn = false
        settings = false
        setup = false
        page = p
    }

    /// The first-run checklist, the ring on `step` (else the first step not done);
    /// `fromSettings`: B goes back to Settings › Setup check.
    func openSetup(on step: SetupStep? = nil, fromSettings: Bool = false) {
        setupFromSettings = fromSettings
        setupStart = step ?? SetupChecklist.firstTodo(SetupState.shared.facts)
        gamePath = []
        settings = false
        if setup { PadFocus.shared.ring(setupStart.item) } else { setup = true }
    }

    /// A catalogued title's page, over the Library; `options` opens its Game options too.
    func openTitle(_ id: String, options: Bool = false) {
        openGame(.title(id))
        if options { gamePanels = [.options] }
    }

    func openGame(_ ref: GameRef) {
        show(.library)
        gamePath = [ref]
    }

    /// LB and RB: the page before or after this one, wrapping round.
    func step(_ by: Int) {
        let all = Page.allCases
        let i = all.firstIndex(of: page) ?? 0
        show(all[(i + by + all.count) % all.count])
    }

    /// Sign in to Steam over this screen; the ring comes back to the item it is on.
    func openSignIn() {
        guard !signIn else { return }
        signInReturn = PadFocus.shared.focused
        signIn = true
    }

    func closeSignIn() { signIn = false }

    /// B: one screen back. False when there is nothing to go back from.
    func back() -> Bool {
        if signIn {
            signIn = false
            return true
        }
        if settings {
            settings = false
            // Back to the checklist it was opened from (its Steam step).
            if setup { PadFocus.shared.reset(start: SetupStep.steam.item) }
            return true
        }
        if setup {
            setup = false
            if setupFromSettings {
                settingsSection = .setup
                settings = true
                PadFocus.shared.reset(start: "set:setup:checklist")
            }
            return true
        }
        switch page {
        case .library where !gamePath.isEmpty && !gamePanels.isEmpty: gamePanels.removeLast()
        case .library where !gamePath.isEmpty: gamePath.removeLast()
        case .library, .downloads: page = .home
        case .home: return false
        }
        return true
    }

    /// A game page is open over the Library.
    var onGamePage: Bool {
        page == .library && !settings && !setup && !signIn && !gamePath.isEmpty
    }
}
