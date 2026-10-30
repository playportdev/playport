// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import XboxClientKit

/// Which licence results are a verdict on the copy, for its lapse (PLA-505): only
/// Microsoft's grant and its definitive refusal of the copy.
final class XboxLicenceLapseTests: XCTestCase {
    private func licence(_ source: XboxLicence.Source) -> XboxLicence {
        XboxLicence(contentID: "31f3afa5-0000-0000-0000-000000000000", keys: [], expiresAt: Date(), offlineLease: nil, source: source)
    }

    func testOnlyMicrosoftsGrantAndItsRefusalOfTheCopyAreVerdicts() {
        XCTAssertEqual(XboxLicenceResult.licensed(licence(.microsoft)).copyLicensed, true)
        XCTAssertEqual(XboxLicenceResult.refused(.refused).copyLicensed, false)
    }

    func testNoAnswerAStoredLicenceAndADeviceRefusalAreNoVerdict() {
        let none: [XboxLicenceResult] = [
            .licensed(licence(.cache)),  // the Keychain's licence while Microsoft can't be reached
            .refused(.deviceLimit),      // the device, not the copy
            .unavailable(.network),
            .unavailable(.service(503)),
            .unavailable(.service(429)),
            .unavailable(.rejected(403)),
            .unavailable(.rejected(401)),
            .unavailable(.invalidResponse),
            .unavailable(.session(.signInRequired)),
        ]
        for r in none { XCTAssertNil(r.copyLicensed, "\(r)") }
    }
}
