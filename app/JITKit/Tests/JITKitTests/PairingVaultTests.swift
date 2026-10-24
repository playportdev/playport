// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import JITKit

final class PairingVaultTests: XCTestCase {
    #if canImport(Security)
    func testDefaultStoreRejectsAProcessOutsideTheHelper() {
        XCTAssertThrowsError(try PairingVault().revision()) { error in
            guard case PairingVault.Failure.isolation = error else {
                return XCTFail("Unexpected failure: \(error)")
            }
        }
    }
    #endif
    private final class Memory {
        var data: Data?
        var failWrites = false
        let lock = NSLock()
        func vault() -> PairingVault {
            PairingVault(read: { self.data }, write: {
                if self.failWrites { throw PairingVault.Failure.keychain(-1) }
                self.data = $0
            }, acquireLock: { self.lock.lock(); return { self.lock.unlock() } })
        }
    }

    private func credential(_ byte: UInt8) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "public_key": Data(repeating: byte, count: 32),
            "private_key": Data(repeating: byte, count: 32),
            "identifier": "test-host", "alt_irk": Data(repeating: byte, count: 16),
        ], format: .binary, options: 0)
    }

    func testPendingNeverReplacesActiveUntilCommitAndSurvivesHelperRestart() throws {
        let memory = Memory(), vault = memory.vault()
        let old = try credential(1), new = try credential(2)
        let revision = try vault.importCredentials(old, replacing: nil)
        let token = try vault.stage(new)
        let restarted = memory.vault()
        XCTAssertEqual(try restarted.credentials(), old)
        XCTAssertEqual(try restarted.credentials(candidate: token), new)
        XCTAssertThrowsError(try restarted.credentials(candidate: "wrong-token"))
        let next = try restarted.commit(candidate: token, replacing: revision)
        XCTAssertNotEqual(next, revision)
        XCTAssertEqual(try restarted.credentials(), new)
        XCTAssertThrowsError(try restarted.credentials(candidate: token))
    }

    func testInterveningImportAndStaleTokenCannotCommitOrDiscardNewCandidate() throws {
        let vault = Memory().vault()
        let first = try vault.importCredentials(credential(1), replacing: nil)
        let stale = try vault.stage(credential(2))
        let second = try vault.importCredentials(credential(3), replacing: first)
        XCTAssertThrowsError(try vault.commit(candidate: stale, replacing: first))
        let current = try vault.stage(credential(4))
        try vault.discard(candidate: stale)
        XCTAssertEqual(try vault.credentials(candidate: current), try credential(4))
        XCTAssertThrowsError(try vault.commit(candidate: current, replacing: first))
        XCTAssertEqual(try vault.credentials(), try credential(3))
        _ = try vault.commit(candidate: current, replacing: second)
    }

    func testFailedWritesAndInvalidInputsPreserveActiveCredentials() throws {
        let memory = Memory(), vault = memory.vault()
        let old = try credential(1)
        let revision = try vault.importCredentials(old, replacing: nil)
        XCTAssertThrowsError(try vault.stage(Data("not a plist".utf8)))
        let token = try vault.stage(credential(2))
        memory.failWrites = true
        XCTAssertThrowsError(try vault.commit(candidate: token, replacing: revision))
        XCTAssertEqual(try vault.credentials(), old)
        XCTAssertEqual(try vault.revision(), revision)
        memory.failWrites = false
        try vault.discard(candidate: token)
        XCTAssertEqual(try vault.credentials(), old)
        XCTAssertThrowsError(try vault.credentials(candidate: token))
    }

    func testEmptyAndCorruptVaultFailWithoutInventingCredentials() throws {
        let memory = Memory(), vault = memory.vault()
        XCTAssertNil(try vault.revision())
        XCTAssertThrowsError(try vault.credentials())
        memory.data = Data("corrupt state".utf8)
        XCTAssertThrowsError(try vault.revision())
        XCTAssertThrowsError(try vault.stage(credential(1)))
    }

    func testMigrationIsIdempotentAfterCrashAndNeverOverwritesAnotherKey() throws {
        let memory = Memory(), vault = memory.vault()
        let old = try credential(1)
        let revision = try vault.adoptLegacy(old)
        XCTAssertEqual(try memory.vault().adoptLegacy(old), revision)
        XCTAssertThrowsError(try vault.adoptLegacy(credential(2)))
        XCTAssertEqual(try vault.credentials(), old)
        XCTAssertEqual(try vault.revision(), revision)
    }

    func testSeparateWritersCannotBothReplaceTheSameRevision() throws {
        final class Competition: @unchecked Sendable {
            let vaults: [PairingVault]
            let data: Data
            let lock = NSLock()
            var successes = 0
            init(_ vaults: [PairingVault], _ data: Data) { self.vaults = vaults; self.data = data }
        }
        let memory = Memory()
        let competition = Competition([memory.vault(), memory.vault()], try credential(1))
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                _ = try competition.vaults[index].importCredentials(competition.data, replacing: nil)
                competition.lock.withLock { competition.successes += 1 }
            } catch {}
        }
        XCTAssertEqual(competition.successes, 1)
        XCTAssertEqual(try memory.vault().credentials(), competition.data)
    }
}
