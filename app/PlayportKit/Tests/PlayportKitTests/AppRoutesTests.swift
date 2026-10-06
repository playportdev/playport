// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import PlayportKit

final class AppRoutesTests: XCTestCase {
    private let game = GameRef.title("app-367520")

    func testHomeGameAndOptionsReturnHome() {
        var nav = AppRoutes()
        nav.openGame(game, focus: "hero:app-367520")
        XCTAssertEqual(nav.gameBackLabel, "Home")
        nav.gamePanels = [.options, .achievements]
        XCTAssertTrue(nav.back())
        XCTAssertEqual(nav.gamePanels, [.options])
        XCTAssertTrue(nav.back())
        XCTAssertTrue(nav.onGamePage)
        XCTAssertTrue(nav.back())
        XCTAssertEqual(nav.page, .home)
        XCTAssertTrue(nav.gamePath.isEmpty)
        XCTAssertEqual(nav.focusStart, "hero:app-367520")
        XCTAssertFalse(nav.back())
    }

    func testGameReturnsToEveryOrigin() {
        for page in AppRoutes.Page.allCases {
            var nav = AppRoutes()
            nav.show(page, focus: nil)
            nav.openGame(game, focus: "origin")
            XCTAssertEqual(nav.gameBackLabel, page.title)
            nav.back()
            XCTAssertEqual(nav.page, page)
            XCTAssertEqual(nav.focusStart, "origin")
        }
    }

    func testStorageGameReturnsToStorageThenItsUnderlyingPage() {
        for page in AppRoutes.Page.allCases {
            var nav = AppRoutes()
            nav.show(page, focus: nil)
            nav.openSettings(section: .storage, focus: "page-item")
            nav.openGame(game, focus: "set:storage:app-367520")
            XCTAssertEqual(nav.gameBackLabel, "Settings")
            nav.gamePanels = [.options]
            nav.back()
            XCTAssertTrue(nav.onGamePage)
            nav.back()
            XCTAssertTrue(nav.settings)
            XCTAssertEqual(nav.settingsSection, .storage)
            XCTAssertEqual(nav.focusStart, "set:storage:app-367520")
            nav.back()
            XCTAssertFalse(nav.settings)
            XCTAssertEqual(nav.page, page)
            XCTAssertEqual(nav.focusStart, "page-item")
        }
    }

    func testSettingsOverGameRestoresItsPanelsAndFocus() {
        var nav = AppRoutes()
        nav.openGame(game, focus: "hero")
        nav.gamePanels = [.options, .achievements]
        nav.openSettings(section: .storage, focus: "achievements-row")
        nav.openGame(.steam(292030), focus: "storage-row")
        nav.back()
        XCTAssertTrue(nav.settings)
        XCTAssertEqual(nav.focusStart, "storage-row")
        nav.back()
        XCTAssertTrue(nav.onGamePage)
        XCTAssertEqual(nav.gamePath, [game])
        XCTAssertEqual(nav.gamePanels, [.options, .achievements])
        XCTAssertEqual(nav.focusStart, "achievements-row")
        XCTAssertEqual(nav.gameBackLabel, "Home")
    }

    func testSetupOpenedByPlayReturnsToGameNotLibrary() {
        var nav = AppRoutes()
        nav.openGame(game, focus: "hero")
        nav.openSetup(on: .pairing, focus: "play")
        nav.openSettings(section: .accounts, focus: "setup:steam")
        nav.openSignIn(focus: "signin-row")
        nav.back()
        XCTAssertTrue(nav.settings)
        XCTAssertEqual(nav.focusStart, "signin-row")
        nav.back()
        XCTAssertTrue(nav.setup)
        XCTAssertFalse(nav.settings)
        XCTAssertEqual(nav.setupStart, .pairing)
        XCTAssertEqual(nav.focusStart, "setup:steam")
        nav.back()
        XCTAssertTrue(nav.onGamePage)
        XCTAssertEqual(nav.focusStart, "play")
        nav.back()
        XCTAssertEqual(nav.page, .home)
    }

    func testSetupFromSettingsRestoresExactSectionAndRow() {
        var nav = AppRoutes()
        nav.openSettings(section: .setup, focus: "home-item")
        nav.openSetup(on: .pairing, focus: "set:setup:preview")
        nav.openSignIn(focus: "setup:step:steam")
        nav.back()
        XCTAssertTrue(nav.setup)
        XCTAssertEqual(nav.focusStart, "setup:step:steam")
        nav.back()
        XCTAssertTrue(nav.settings)
        XCTAssertEqual(nav.settingsSection, .setup)
        XCTAssertEqual(nav.focusStart, "set:setup:preview")
    }

    func testSignInFromAllKindsOfScreen() {
        for origin in 0..<5 {
            var nav = AppRoutes()
            switch origin {
            case 1: nav.show(.downloads, focus: nil)
            case 2: nav.openGame(game, focus: nil)
            case 3: nav.openSettings(section: .accounts, focus: nil)
            case 4: nav.openSetup(on: .steam, focus: nil)
            default: break
            }
            let page = nav.page, path = nav.gamePath
            let settings = nav.settings, setup = nav.setup
            XCTAssertTrue(nav.openSignIn(focus: "origin-row"))
            XCTAssertFalse(nav.openSignIn(focus: "wrong"))
            nav.back()
            XCTAssertFalse(nav.signIn)
            XCTAssertEqual(nav.page, page)
            XCTAssertEqual(nav.gamePath, path)
            XCTAssertEqual(nav.settings, settings)
            XCTAssertEqual(nav.setup, setup)
            XCTAssertEqual(nav.focusStart, "origin-row")
        }
    }

    func testLicencePagesUnwindBeforeLeavingSettings() {
        var nav = AppRoutes()
        nav.openSettings(section: .about, focus: "home-item")
        nav.openLicence(.list)
        nav.openLicence(.component("Wine"))
        nav.openLicence(.text("COPYING"))
        nav.back()
        XCTAssertEqual(nav.licences, [.list, .component("Wine")])
        nav.back()
        XCTAssertEqual(nav.licences, [.list])
        nav.back()
        XCTAssertTrue(nav.settings)
        XCTAssertTrue(nav.licences.isEmpty)
        nav.back()
        XCTAssertEqual(nav.page, .home)
        XCTAssertFalse(nav.settings)
    }

    func testSidebarChoiceClearsLicencesButSectionLinkReturnsToOrigin() {
        var nav = AppRoutes()
        nav.openSettings(section: .about, focus: "home-item")
        nav.openLicence(.list)
        nav.settingsSection = .setup
        XCTAssertTrue(nav.licences.isEmpty)
        nav.openSettings(section: .accounts, focus: "set:setup:steam")
        nav.back()
        XCTAssertTrue(nav.settings)
        XCTAssertEqual(nav.settingsSection, .setup)
        XCTAssertEqual(nav.focusStart, "set:setup:steam")
        nav.back()
        XCTAssertFalse(nav.settings)
        nav.openSettings(focus: nil)
        XCTAssertEqual(nav.settingsSection, .setup)
    }

    func testMainSectionsDoNotOfferBack() {
        var nav = AppRoutes()
        for page in [AppRoutes.Page.library, .downloads, .home, .downloads, .library] {
            XCTAssertTrue(nav.show(page, focus: "previous-page-item"))
            XCTAssertFalse(nav.canGoBack)
            XCTAssertFalse(nav.back())
            XCTAssertEqual(nav.page, page)
            XCTAssertNil(nav.focusStart)
        }
    }

    func testGameReturnsToLibraryButCannotUnwindEarlierSections() {
        var nav = AppRoutes()
        nav.show(.downloads, focus: "download")
        nav.show(.library, focus: "download-job")
        XCTAssertFalse(nav.show(.library, focus: "wrong"))
        nav.openGame(game, focus: "lib:app-367520")
        XCTAssertTrue(nav.back())
        XCTAssertEqual(nav.page, .library)
        XCTAssertEqual(nav.focusStart, "lib:app-367520")
        XCTAssertFalse(nav.canGoBack)
        XCTAssertFalse(nav.back())
        XCTAssertEqual(nav.page, .library)
        XCTAssertTrue(nav.gamePath.isEmpty)
    }

    func testSectionSelectionDiscardsNestedHistory() {
        var nav = AppRoutes()
        nav.openGame(game, focus: "hero")
        nav.gamePanels = [.options]
        nav.openSettings(section: .storage, focus: "options-row")
        nav.show(.downloads, focus: "storage-row")
        nav.openSignIn(focus: "download-row")
        XCTAssertTrue(nav.back())
        XCTAssertEqual(nav.page, .downloads)
        XCTAssertEqual(nav.focusStart, "download-row")
        XCTAssertFalse(nav.settings)
        XCTAssertTrue(nav.gamePath.isEmpty)
        XCTAssertTrue(nav.gamePanels.isEmpty)
        XCTAssertFalse(nav.back())
    }

    func testNativeGamePopRestoresStorageAndSkipsPanels() {
        var nav = AppRoutes()
        nav.openSettings(section: .storage, focus: "hero")
        nav.openGame(game, focus: "storage-row")
        nav.gamePanels = [.options, .achievements]
        nav.closeGame()
        XCTAssertTrue(nav.settings)
        XCTAssertEqual(nav.settingsSection, .storage)
        XCTAssertEqual(nav.focusStart, "storage-row")
        XCTAssertTrue(nav.gamePath.isEmpty)
    }

    func testReopeningVisibleGameDoesNotDuplicateOriginOrDropPanels() {
        var nav = AppRoutes()
        nav.openGame(game, focus: "hero")
        nav.gamePanels = [.options]
        XCTAssertFalse(nav.openGame(game, focus: "wrong"))
        XCTAssertEqual(nav.gamePanels, [.options])
        nav.back()
        nav.back()
        XCTAssertEqual(nav.page, .home)
        XCTAssertEqual(nav.focusStart, "hero")
        XCTAssertFalse(nav.back())
    }
}
