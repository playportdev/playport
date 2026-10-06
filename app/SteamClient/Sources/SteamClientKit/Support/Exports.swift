// SPDX-License-Identifier: GPL-3.0-or-later
// The store-neutral core (app/ContentKit: the install engine, codecs, hashes,
// HTTP, secrets and redaction) is part of this module's interface, so the app
// and the tests see one module as before.
@_exported import ContentKit

/// The client's error type, named as it was before the core moved to ContentKit.
public typealias SteamError = ClientError

#if canImport(Security)
extension KeychainSecretStore {
    /// The Steam session's Keychain items (SecretKeys.service).
    public init(accessGroup: String? = nil) {
        self.init(service: SecretKeys.service, accessGroup: accessGroup)
    }
}
#endif
