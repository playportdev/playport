// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(Security)
import Security
#endif

/// Used only in the helper process. Neither current nor pending credentials
/// have a read/export operation in the XPC contract.
public final class PairingVault {
    struct State: Codable {
        var current: Data?
        var revision: String?
        var pending: Data?
        var token: String?
        var baseRevision: String?
    }

    public enum Failure: Error, LocalizedError {
        case invalid, changed, missing, keychain(Int32), locked, isolation
        public var errorDescription: String? {
            switch self {
            case .invalid: "Invalid pairing credentials"
            case .changed: "Pairing changed during setup; try again"
            case .missing: "No pairing credentials in the helper"
            case .keychain(let status): "Helper Keychain operation failed (\(status))"
            case .locked: "Another helper is updating pairing credentials"
            case .isolation: "The helper has no separate Keychain group; re-sign each bundle with its own profile"
            }
        }
    }

    private let read: () throws -> Data?
    private let write: (Data) throws -> Void
    private let acquireLock: () throws -> (() -> Void)

    public convenience init() {
        self.init(read: Self.keychainRead, write: Self.keychainWrite, acquireLock: Self.fileLock)
    }

    init(read: @escaping () throws -> Data?, write: @escaping (Data) throws -> Void,
         acquireLock: @escaping () throws -> (() -> Void) = { {} }) {
        self.read = read
        self.write = write
        self.acquireLock = acquireLock
    }

    private func state() throws -> State {
        guard let data = try read() else { return State() }
        let state = try PropertyListDecoder().decode(State.self, from: data)
        guard (state.current == nil) == (state.revision == nil) else { throw Failure.invalid }
        return state
    }

    public func revision() throws -> String? { try state().revision }

    public func credentials(candidate token: String? = nil) throws -> Data {
        let state = try state()
        if let token {
            guard token == state.token, let data = state.pending else { throw Failure.changed }
            return data
        }
        guard let data = state.current else { throw Failure.missing }
        return data
    }

    public func stage(_ data: Data) throws -> String {
        try Self.validate(data)
        let unlock = try acquireLock(); defer { unlock() }
        var state = try state()
        let token = UUID().uuidString
        state.pending = data
        state.token = token
        state.baseRevision = state.revision
        try save(state)
        return token
    }

    public func commit(candidate token: String, replacing expected: String?) throws -> String {
        let unlock = try acquireLock(); defer { unlock() }
        var state = try state()
        guard state.token == token, state.revision == expected,
              state.baseRevision == expected, let data = state.pending else { throw Failure.changed }
        let revision = UUID().uuidString
        state.current = data
        state.revision = revision
        state.pending = nil
        state.token = nil
        state.baseRevision = nil
        try save(state)
        return revision
    }

    public func importCredentials(_ data: Data, replacing expected: String?) throws -> String {
        try Self.validate(data)
        let unlock = try acquireLock(); defer { unlock() }
        var state = try state()
        guard state.revision == expected else { throw Failure.changed }
        let revision = UUID().uuidString
        state.current = data
        state.revision = revision
        state.pending = nil
        state.token = nil
        state.baseRevision = nil
        try save(state)
        return revision
    }

    public func discard(candidate token: String) throws {
        let unlock = try acquireLock(); defer { unlock() }
        var state = try state()
        guard state.token == token else { return }
        state.pending = nil
        state.token = nil
        state.baseRevision = nil
        try save(state)
    }

    /// Retry-safe across a crash after helper commit but before legacy deletion.
    /// An existing different credential is preserved, never silently replaced.
    public func adoptLegacy(_ data: Data) throws -> String {
        try Self.validate(data)
        let unlock = try acquireLock(); defer { unlock() }
        var state = try state()
        if let current = state.current {
            guard current == data, let revision = state.revision else { throw Failure.changed }
            return revision
        }
        let revision = UUID().uuidString
        state.current = data
        state.revision = revision
        try save(state)
        return revision
    }

    private func save(_ state: State) throws { try write(PropertyListEncoder().encode(state)) }

    private static func fileLock() throws -> (() -> Void) {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlayportPairing.lock")
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.locked }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            close(fd)
            throw Failure.locked
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < deadline else {
                close(fd)
                throw Failure.locked
            }
            // Kernel file locks disappear on crash; no stale sentinel to trust.
            usleep(20_000)
        }
        return { close(fd) }
    }

    private static func validate(_ data: Data) throws {
        guard let p = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              (p["public_key"] as? Data)?.count == 32, (p["private_key"] as? Data)?.count == 32,
              let identifier = p["identifier"] as? String, !identifier.isEmpty,
              p["alt_irk"] == nil || (p["alt_irk"] as? Data)?.count == 16 else { throw Failure.invalid }
    }

    #if canImport(Security)
    private static let ownGroup: Result<String, Error> = Result {
        guard let bundle = Bundle.main.bundleIdentifier, bundle.hasSuffix(".PlayportJIT") else { throw Failure.isolation }
        // A nonsecret marker reveals the actual default group chosen by the
        // system. Do not rely on an unsigned IPA's eventual re-signer doing
        // the right thing, or search all entitled groups for a credential.
        let marker: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.playport.helper.group-check",
            kSecAttrAccount as String: UUID().uuidString, kSecAttrSynchronizable as String: false]
        let add = marker.merging([kSecValueData as String: Data("scope-check".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecReturnAttributes as String: true]) { $1 }
        var value: CFTypeRef?
        let status = SecItemAdd(add as CFDictionary, &value)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        let attributes = value as? [String: Any]
        let cleanup = SecItemDelete(marker as CFDictionary)
        guard cleanup == errSecSuccess else { throw Failure.keychain(cleanup) }
        guard let group = attributes?[kSecAttrAccessGroup as String] as? String,
              group.hasSuffix("." + bundle) else { throw Failure.isolation }
        return group
    }

    private static func query() throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.playport.helper.jit",
         kSecAttrAccount as String: "pairing-state-v1",
         kSecAttrAccessGroup as String: try ownGroup.get(),
         kSecAttrSynchronizable as String: false]
    }

    private static func keychainRead() throws -> Data? {
        var q = try query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = SecItemCopyMatching(q as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = value as? Data else { throw Failure.keychain(result) }
        return data
    }

    private static func keychainWrite(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let query = try query()
        var result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            result = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw Failure.keychain(result) }
        guard try keychainRead() == data else { throw Failure.invalid }
    }
    #else
    private static func keychainRead() throws -> Data? { throw Failure.keychain(-4) }
    private static func keychainWrite(_ data: Data) throws { throw Failure.keychain(-4) }
    #endif
}
