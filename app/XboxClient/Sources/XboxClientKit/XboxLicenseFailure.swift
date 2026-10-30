// SPDX-License-Identifier: GPL-3.0-only
// Xodus 514dd56f360a4bdf12f4acde5148bac5ce5f957f models/licensing.rs, and
// Xodus Nexus 96c652343d30ae16fe476818288edbed5dfac673's content-device-limit
// patch; translated to Swift by the Playport authors, 2026-10-30. Modified:
// names the ten-device limit; never uses provider text or remediation links.
// See LICENSE-Xodus.txt and LICENSE-XodusNexus.txt.
import Foundation
import ContentKit

public enum XboxLicenseFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case deviceLimit
    case refused
    public var description: String {
        switch self {
        case .deviceLimit:
            "Microsoft Store allows 10 linked devices. Unlink an old device you no longer use at account.microsoft.com/devices/content, then try again. You don't need to sign out or reset the Xbox device."
        case .refused:
            "Microsoft did not grant a licence for this copy. Check your purchase, subscription and Store region."
        }
    }
    /// Licensing reason 501 (NOT HTTP 501). Registration is anonymous; the Store
    /// associates the device with the account on licensing, not inline sign-in.
    /// The licensing client (PLA-496) uses this same public classifier.
    public static func check(_ response: XboxHTTPResponse) throws {
        guard (200..<300).contains(response.status) else { throw ClientError.transport("Xbox licensing returned HTTP \(response.status)") }
        struct XboxDenial: Decodable {
            struct XboxReason: Decodable { let code: Int64; let description: String }
            let satisfactionFailure: XboxReason
        }
        if let denial = try? JSONDecoder().decode(XboxDenial.self, from: Data(response.body.value)) {
            throw denial.satisfactionFailure.code == 501 ? Self.deviceLimit : Self.refused
        }
    }
}
