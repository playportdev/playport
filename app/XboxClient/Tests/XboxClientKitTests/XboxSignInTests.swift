// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
import XboxClientKit

final class XboxSignInTests: XCTestCase {
    func testMicrosoftsInlinePageGetsItsHostContextButOnlyItsOwnOriginCanHandOverTokens() throws {
        let page = XboxSignIn.page()
        XCTAssertEqual(page.url.host, "login.live.com")
        XCTAssertEqual(page.url.path, "/ppsecure/InlineLogin.srf")
        XCTAssertEqual(page.headers["hostApp"], "CloudExperienceHost")
        let message = Secret(#"{"type":"invoke","value":{"name":"CloudExperienceHost.getContext","context":"quoted\"context"}}"#)
        guard case let .script(script) = try XboxSignIn.receive(message, from: page.url) else { return XCTFail("no context reply") }
        XCTAssertTrue(script.contains("CloudExperienceHost.Bridge.dispatchMessage"))
        let argument = script.split(separator: "(", maxSplits: 1)[1].dropLast(2)
        let replyJSON = try JSONDecoder().decode(String.self, from: Data(argument.utf8))
        let reply = try JSONSerialization.jsonObject(with: Data(replyJSON.utf8)) as? [String: Any]
        XCTAssertEqual((reply?["value"] as? [String: Any])?["context"] as? String, "quoted\"context")
        let data = try Data(contentsOf: Bundle.module.url(forResource: "Fixtures/signin.json", withExtension: nil)!)
        let token = Secret(String(decoding: data, as: UTF8.self))
        guard case .token = try XboxSignIn.receive(token, from: URL(string: "https://login.live.com/ppsecure/post.srf")!) else {
            return XCTFail("no sign-in result")
        }
        for url in ["https://evil.invalid/ppsecure/post.srf", "http://login.live.com/ppsecure/post.srf", "https://login.live.com.evil.invalid/"] {
            guard case .ignored = try XboxSignIn.receive(token, from: URL(string: url)!) else { return XCTFail("foreign page accepted") }
        }
        XCTAssertTrue(XboxSignIn.passkeyNote.contains("Authenticator"))
    }
}
