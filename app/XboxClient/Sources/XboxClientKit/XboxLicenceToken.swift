// SPDX-License-Identifier: GPL-3.0-only
// Xodus 53ea781dcd073e31d7ea68e894134e9c959bff04 licensing/content.rs
// (get_license_token) and models/licensing.rs, and Xodus Nexus
// e0668a12f1da931aed13537ef04295599011317b's xodus-store-license and
// xodus-license-sku patches (store_license.rs); translated to Swift by the Playport
// authors, 2026-10-30. Modified: injected HTTP; typed problems; nothing logged but
// the outcome.
import Foundation
import ContentKit

extension XboxSession {
    static let licenceTokenEndpoint = URL(string: "https://licensing.mp.microsoft.com/v8.0/licenseToken")!

    /// The Store licence token a game asks for (XStoreQueryLicenseTokenAsync): Nexus's
    /// request, authorised by the device's Store ticket and naming the account by its
    /// Store ticket and PUID. Product IDs and the developer string go as given; the
    /// bridge binds them to the playing copy. Throws `XboxLicenceProblem` when
    /// Microsoft gives no token, `ClientError.cancelled` on sign-out.
    public func licenceToken(parentProductID: String, productIDs: [String], nonce: String) async throws -> Secret<String> {
        let epoch = generation
        let device: XboxTicket, user: XboxTicket
        do {
            device = try await deviceTicket(scope: Self.storeScope, clientID: Self.storeApp, policy: "mbi_ssl")
            user = try await storeTicket()
        } catch let error as XboxSessionError { throw XboxLicenceProblem.session(error) }
        catch ClientError.cancelled { throw ClientError.cancelled }
        catch let error as ClientError {
            if case .credentialStore = error { throw error }
            if case .transport = error { throw XboxLicenceProblem.network }
            throw XboxLicenceProblem.invalidResponse
        }
        guard let reference = try ticketReference else { throw XboxLicenceProblem.session(.signInRequired) }
        try check(epoch)
        struct Body: Encodable {
            struct Identity: Encodable { let identityType = "Msa"; let identityValue: String; let localTicketReference: String }
            let parentProductId: String
            let enforceSellableBy = true
            let relatedProductIds: [String]
            let customDeveloperString: String
            let beneficiaries: [Identity]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = Body(parentProductId: parentProductID, relatedProductIds: productIDs, customDeveloperString: nonce,
                        beneficiaries: [.init(identityValue: user.token.value, localTicketReference: reference)])
        let request = XboxHTTPRequest(url: Self.licenceTokenEndpoint, headers: [
            "from": Secret("XboxLicenseManager"), "Authorization": device.token, "User-Agent": Secret("XboxGameRuntime"),
            "Content-Type": Secret("application/json"),
        ], body: Secret(Array(try encoder.encode(body))))
        let response: XboxHTTPResponse
        do { response = try await http.send(request) }
        catch is CancellationError { throw ClientError.cancelled }
        catch ClientError.cancelled { throw ClientError.cancelled }
        catch { throw XboxLicenceProblem.network }
        try check(epoch)
        switch response.status {
        case 200..<300: break
        case 408, 429, 500..<600: throw XboxLicenceProblem.service(response.status)
        default: throw XboxLicenceProblem.rejected(response.status)
        }
        struct Reply: Decodable { let licenseToken: String }
        // Nexus's bounds: a body of at most 60,000 bytes, a token of at most 48,000.
        guard response.body.value.count <= 60_000,
              let token = try? JSONDecoder().decode(Reply.self, from: Data(response.body.value)).licenseToken,
              !token.isEmpty, token.utf8.count <= 48_000 else { throw XboxLicenceProblem.invalidResponse }
        log.info("xbox", "licence token issued")
        return Secret(token)
    }
}
