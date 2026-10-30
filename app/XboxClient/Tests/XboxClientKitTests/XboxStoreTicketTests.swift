// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
import XboxClientKit

final class XboxStoreTicketTests: XCTestCase, @unchecked Sendable {
    let date = Date(timeIntervalSince1970: 1_793_318_400)

    /// The Store's own ticket (Nexus's store_session): one silent exchange for
    /// www.microsoft.com under the Store app's client ID, then the cached ticket.
    func testTheStoreTicketIsASilentExchangeForTheStoreAppAndIsReused() async throws {
        let store = MemorySecretStore(), http = XboxFixtureHTTP(), lines = XboxLines()
        let session = XboxSession(store: store, http: http, log: lines.logger, now: { [date] in date })
        _ = try await session.prepareSignIn()
        _ = try await session.signIn(xboxSignInToken())
        try await http.reply("renew", "store-ticket.xml")
        let ticket = try await session.storeTicket()
        XCTAssertEqual(ticket.token.value, "t=synthetic-store-ticket&p=")
        let sent = await http.request("renew")
        let request = String(decoding: try XCTUnwrap(sent).body.value, as: UTF8.self)
        XCTAssertTrue(request.contains(">www.microsoft.com<"))
        XCTAssertTrue(request.contains("URI=\"mbi_ssl\""))
        XCTAssertTrue(request.contains(">{d6d5a677-0872-4ab0-9442-bb792fce85c5}<"))
        XCTAssertTrue(request.contains(">Silent<"))
        XCTAssertFalse(request.contains("http://Passport.NET/tb"), "the Store ticket asks for nothing else")
        let again = try await session.storeTicket()
        XCTAssertEqual(again.token.value, ticket.token.value)
        let exchanges = await http.count("renew")
        XCTAssertEqual(exchanges, 1)
        XCTAssertFalse(lines.text.contains("synthetic-store"))
        try await session.signOut()
        do { _ = try await session.storeTicket(); XCTFail("signed out") } catch XboxSessionError.signInRequired {}
    }

    func testARefusedStoreTicketAsksForSignInButKeepsTheSession() async throws {
        let store = MemorySecretStore(), http = XboxFixtureHTTP()
        let session = XboxSession(store: store, http: http, now: { [date] in date })
        _ = try await session.prepareSignIn()
        _ = try await session.signIn(xboxSignInToken())
        try await http.reply("renew", "renewal-refused.xml")
        do { _ = try await session.storeTicket(); XCTFail("refused") } catch XboxSessionError.signInRequired {}
        let state = await session.state
        XCTAssertEqual(state, .signedIn)
    }
}
