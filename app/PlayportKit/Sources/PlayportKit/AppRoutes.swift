// SPDX-License-Identifier: GPL-3.0-or-later
// Product navigation without SwiftUI: nested screens remember the screen
// (including its section/panels) and focus that opened them. Back unwinds local
// panels and that history; main sections are roots, switched with LB/RB.

public enum GameRef: Hashable {
    case title(String)
    case steam(UInt32)
}

public enum LicencePage: Hashable {
    case list
    case component(String)
    case text(String)
}

public struct AppRoutes {
    public enum Page: String, Hashable, CaseIterable {
        case home, library, downloads

        public var title: String {
            switch self {
            case .home: "Home"
            case .library: "Library"
            case .downloads: "Downloads"
            }
        }
    }

    public enum GamePanel: String, Hashable {
        case options, achievements
    }

    private struct Screen {
        var page = Page.home
        var settings = false
        var settingsSection = SettingsSection.steam
        var licences: [LicencePage] = []
        var setup = false
        var setupStart = SetupStep.controller
        var signIn = false
        var gamePath: [GameRef] = []
        var gamePanels: [GamePanel] = []
        var focus: String?
    }

    private var screen = Screen()
    private var history: [Screen] = []

    public init() {}

    public var page: Page { screen.page }
    public var settings: Bool { screen.settings }
    public var setup: Bool { screen.setup }
    public var setupStart: SetupStep { screen.setupStart }
    public var signIn: Bool { screen.signIn }
    public var gamePath: [GameRef] { screen.gamePath }
    public var licences: [LicencePage] { screen.licences }
    public var focusStart: String? { screen.focus }
    public var settingsSection: SettingsSection {
        get { screen.settingsSection }
        set {
            if newValue != screen.settingsSection { screen.licences = [] }
            screen.settingsSection = newValue
        }
    }
    public var gamePanels: [GamePanel] {
        get { screen.gamePanels }
        set { screen.gamePanels = newValue }
    }
    public var onGamePage: Bool {
        !settings && !setup && !signIn && !gamePath.isEmpty
    }
    public var canGoBack: Bool { onGamePage || settings || setup || signIn }
    public var gameBackLabel: String {
        guard let origin = history.last else { return "Library" }
        if origin.signIn { return "Sign in" }
        if origin.settings { return "Settings" }
        if origin.setup { return "Setup" }
        if !origin.gamePath.isEmpty { return "Back" }
        return origin.page.title
    }

    private mutating func remember(_ focus: String?) {
        screen.focus = focus
        history.append(screen)
        screen.focus = nil
    }

    /// Explicit tab selection or a Home card/search link starts a new root,
    /// not Back history. Reopening the visible page is a no-op.
    @discardableResult
    public mutating func show(_ page: Page, focus: String?) -> Bool {
        guard screen.page != page || settings || setup || signIn || !gamePath.isEmpty else { return false }
        history.removeAll()
        screen.focus = nil
        screen.signIn = false
        screen.settings = false
        screen.licences = []
        screen.setup = false
        screen.gamePath = []
        screen.gamePanels = []
        screen.page = page
        return true
    }

    @discardableResult
    public mutating func openGame(_ ref: GameRef, focus: String?) -> Bool {
        // A failed retry/cloud choice may reopen the already visible title.
        guard !onGamePage || gamePath.last != ref else { return false }
        remember(focus)
        screen.signIn = false
        screen.settings = false
        screen.setup = false
        screen.page = .library
        screen.gamePath = [ref]
        screen.gamePanels = []
        return true
    }

    @discardableResult
    public mutating func openSettings(section: SettingsSection? = nil, focus: String?) -> Bool {
        guard !settings || signIn || (section != nil && section != settingsSection) else { return false }
        remember(focus)
        screen.signIn = false
        screen.settings = true
        if let section { settingsSection = section }
        return true
    }

    @discardableResult
    public mutating func openSetup(on step: SetupStep, focus: String?) -> Bool {
        if setup && !settings && !signIn {
            screen.setupStart = step
            return false
        }
        remember(focus)
        screen.signIn = false
        screen.settings = false
        screen.setup = true
        screen.setupStart = step
        screen.gamePath = []
        screen.gamePanels = []
        return true
    }

    @discardableResult
    public mutating func openSignIn(focus: String?) -> Bool {
        guard !signIn else { return false }
        remember(focus)
        screen.signIn = true
        return true
    }

    public mutating func openLicence(_ page: LicencePage) { screen.licences.append(page) }
    @discardableResult
    public mutating func closeLicence() -> LicencePage? { screen.licences.popLast() }
    public mutating func closeLicences() { screen.licences = [] }

    /// Native NavigationStack dismissal, which can remove the game and all its
    /// panels at once. The custom Back button closes only the top panel.
    public mutating func closeGame() {
        guard onGamePage else { return }
        screen.gamePanels = []
        _ = back()
    }

    @discardableResult
    public mutating func back() -> Bool {
        guard canGoBack else { return false }
        if settings && !signIn && !licences.isEmpty {
            _ = closeLicence()
            return true
        }
        if onGamePage && !gamePanels.isEmpty {
            screen.gamePanels.removeLast()
            return true
        }
        if var previous = history.popLast() {
            // Outside Settings, remember the last section for its next opening.
            // A return *into* Settings must instead keep the origin's section.
            if !previous.settings { previous.settingsSection = settingsSection }
            screen = previous
            return true
        }
        screen = Screen()
        return true
    }
}
