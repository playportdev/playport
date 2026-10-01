// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import SteamClientKit

/// Steam sign-in by account name and password (SignIn.dc.html, "On this
/// phone"): the Authentication messages it sends and reads, the Steam Guard
/// code inbox, the service's `.credentials` sign-in over a scripted backend,
/// and the card's states and copy. The RSA step is RSATests'.
final class CredentialSignInTests: XCTestCase {
    // MARK: schemas

    func testRSAKeyResponseAndRequest() throws {
        XCTAssertEqual(try ProtoFields(GetPasswordRSAPublicKeyRequest(accountName: "someone").encode(), message: "r").string(1), "someone")
        var w = ProtoWriter()
        w.string(1, "C0FFEE")
        w.string(2, "010001")
        w.uint64(3, 1_700_000_000_123)
        let r = try GetPasswordRSAPublicKeyResponse.decode(w.bytes)
        XCTAssertEqual(r.modulusHex, "C0FFEE")
        XCTAssertEqual(r.exponentHex, "010001")
        XCTAssertEqual(r.timestamp, 1_700_000_000_123)
        var missing = ProtoWriter()
        missing.string(1, "C0FFEE")
        XCTAssertThrowsError(try GetPasswordRSAPublicKeyResponse.decode(missing.bytes)) { e in
            guard case SteamError.protocolChanged = e else { return XCTFail("\(e)") }
        }
    }

    func testBeginAuthSessionViaCredentialsRequestFields() throws {
        let req = BeginAuthSessionViaCredentialsRequest(deviceFriendlyName: "Playport iOS", accountName: "someone",
                                                        encryptedPassword: Secret("QUJD"), encryptionTimestamp: 42,
                                                        platformType: .steamClient)
        let f = try ProtoFields(req.encode(), message: "CAuthentication_BeginAuthSessionViaCredentials_Request")
        XCTAssertEqual(try f.string(1), "Playport iOS")
        XCTAssertEqual(try f.string(2), "someone")
        XCTAssertEqual(try f.string(3), "QUJD")
        XCTAssertEqual(try f.uint64(4), 42)
        XCTAssertEqual(try f.bool(5), true, "remember_login: a refresh token that lasts")
        XCTAssertEqual(try f.uint32(6), 1, "k_EAuthTokenPlatformType_SteamClient, as the QR login")
        XCTAssertEqual(try f.uint32(7), 1, "k_ESessionPersistence_Persistent")
        XCTAssertEqual(try f.string(8), "Client")
        let d = try XCTUnwrap(f.message(9, as: "CAuthentication_DeviceDetails"))
        XCTAssertEqual(try d.string(1), "Playport iOS")
        XCTAssertEqual(try d.uint32(2), 1)
        XCTAssertFalse(f.has(10), "no guard data unless given")
        XCTAssertFalse(String(describing: req).contains("QUJD"), "the encrypted password prints redacted")
    }

    func testBeginAuthSessionViaCredentialsResponse() throws {
        func confirmation(_ type: UInt32, _ message: String? = nil) -> [UInt8] {
            var m = ProtoWriter(); m.uint32(1, type); m.string(2, message); return m.bytes
        }
        var w = ProtoWriter()
        w.uint64(1, 987654321)
        w.bytes(2, [9, 8, 7])
        w.fixed32(3, Float(0.1).bitPattern)
        w.bytes(4, confirmation(4))
        w.bytes(4, confirmation(3))
        w.bytes(4, confirmation(2, "example.com"))
        w.uint64(5, 76561197960287930)
        w.string(6, "weak.jwt.token")
        let r = try BeginAuthSessionViaCredentialsResponse.decode(w.bytes)
        XCTAssertEqual(r.clientID, 987654321)
        XCTAssertEqual(r.requestID.value, [9, 8, 7])
        XCTAssertEqual(r.interval, 0.1, accuracy: 1e-6)
        XCTAssertEqual(r.steamID, 76561197960287930)
        XCTAssertEqual(r.allowedConfirmations, [AuthConfirmation(type: .deviceConfirmation), AuthConfirmation(type: .deviceCode),
                                                AuthConfirmation(type: .emailCode, message: "example.com")])
        XCTAssertFalse(String(reflecting: r.requestID).contains("9, 8"))
        XCTAssertEqual(AuthGuardType(9), .other(9))
        XCTAssertEqual(AuthGuardType(9).raw, 9)
        for raw: UInt32 in 1...7 { XCTAssertEqual(AuthGuardType(raw).raw, raw) }
    }

    func testSteamGuardCodeRequest() throws {
        let req = UpdateAuthSessionWithSteamGuardCodeRequest(clientID: 5, steamID: 76561197960287930, code: Secret("F4K3X"), codeType: .deviceCode)
        let f = try ProtoFields(req.encode(), message: "CAuthentication_UpdateAuthSessionWithSteamGuardCode_Request")
        XCTAssertEqual(try f.uint64(1), 5)
        XCTAssertEqual(try f.fixed64(2), 76561197960287930, "steamid is fixed64 here")
        XCTAssertEqual(try f.string(3), "F4K3X")
        XCTAssertEqual(try f.uint32(4), 3)
        XCTAssertFalse(String(describing: req).contains("F4K3X"))
    }

    func testNewResultsAndErrorsNameThemselves() {
        XCTAssertEqual(EResult(65), .invalidLoginAuthCode)
        XCTAssertEqual(EResult(88).name, "TwoFactorCodeMismatch")
        XCTAssertEqual(EResult(63).name, "AccountLogonDenied")
        XCTAssertEqual(EResult(29).name, "DuplicateRequest")
        XCTAssertEqual(SteamError.credentialsRefused(.invalidPassword).description, "credentials refused by Steam (EResult InvalidPassword)")
    }

    // MARK: the code inbox

    func testGuardCodeInbox() async throws {
        let inbox = GuardCodeInbox()
        let none = try await inbox.next(within: 0.05)
        XCTAssertNil(none)
        inbox.submit("  ")
        XCTAssertNil(inbox.take(), "an empty code is not sent")
        inbox.submit("f4k-3x ")
        inbox.submit("ABCDE")
        let first = try await inbox.next(within: 1)
        XCTAssertEqual(first?.value, "F4K3X", "spaces and dashes go, letters upper-cased")
        XCTAssertEqual(inbox.take()?.value, "ABCDE")
        // A code that comes while waiting ends the wait.
        Task { try? await Task.sleep(nanoseconds: 50_000_000); inbox.submit("12345") }
        let started = Date()
        let late = try await inbox.next(within: 5)
        XCTAssertEqual(late?.value, "12345")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    // MARK: the service

    func service(_ b: FakeBackend) -> SteamService {
        SteamService(backend: b, log: .silent, stateDirectory: nil)
    }

    /// Runs one credential sign-in, feeding its events to the card's model;
    /// `onConfirm` runs when Steam asks for a confirmation (to type codes).
    func signIn(_ s: SteamService, codes: GuardCodeInbox = GuardCodeInbox(),
                onConfirm: @escaping (inout CredentialSignInModel) -> Void = { _ in })
        async -> (events: [SignInEvent], failure: SignInFailure?, model: CredentialSignInModel, phases: [CredentialSignInModel.Phase]) {
        var model = CredentialSignInModel()
        model.setAccountName(" someone ")
        model.passwordEntered(empty: false)
        var phases = [model.phase]
        var events: [SignInEvent] = []
        let login = CredentialLogin(accountName: model.accountName, password: Secret("hunter2"), codes: codes)
        do {
            for try await e in s.signIn(method: .credentials(login)) {
                events.append(e)
                model.apply(e)
                phases.append(model.phase)
                if case .confirm = e { onConfirm(&model); phases.append(model.phase) }
                if case .codeRejected = e { onConfirm(&model); phases.append(model.phase) }
            }
            return (events, nil, model, phases)
        } catch {
            let f = error as? SignInFailure
            if let f { model.apply(f); phases.append(model.phase) }
            return (events, f, model, phases)
        }
    }

    func testApprovalInTheSteamAppSignsIn() async throws {
        let b = FakeBackend()
        await b.set(credentials: [.confirm([AuthConfirmation(type: .deviceConfirmation), AuthConfirmation(type: .deviceCode)])],
                    .success(FakeBackend.summary))
        let s = service(b)
        let r = await signIn(s)
        XCTAssertNil(r.failure)
        let names = await b.credentialNames
        let passwords = await b.passwordsSeen
        XCTAssertEqual(names, ["someone"], "the name is trimmed")
        XCTAssertEqual(passwords, ["hunter2"])
        XCTAssertEqual(r.phases[0], .checking)
        XCTAssertEqual(r.phases[1], .confirm(.init(approve: .app, code: .app)))
        XCTAssertEqual(r.phases.last, .signedIn(accountTag: FakeBackend.summary.accountTag))
        XCTAssertTrue(r.phases.contains(.approved))
        guard case .signedIn = await s.state else { return XCTFail("signed in") }
        let renewal = await s.lastRenewal
        XCTAssertEqual(renewal?.result, "paired", "stored and counted as the QR pairing is")
        let stored = try await b.storedSession()
        XCTAssertNotNil(stored)
    }

    func testSteamGuardCodeRefusedThenAccepted() async throws {
        let b = FakeBackend()
        await b.set(credentials: [.confirm([AuthConfirmation(type: .emailCode, message: "example.com")])], codeRejects: 1,
                    .success(FakeBackend.summary))
        let codes = GuardCodeInbox()
        var typed = ["wrong", "right"]
        let r = await signIn(service(b), codes: codes) { m in
            XCTAssertTrue(m.takesCode)
            codes.submit(typed.removeFirst())
            m.codeSubmitted()
        }
        XCTAssertNil(r.failure)
        let seen = await b.codesSeen
        XCTAssertEqual(seen, ["WRONG", "RIGHT"])
        XCTAssertTrue(r.events.contains(.codeRejected))
        XCTAssertTrue(r.events.contains(.codeAccepted))
        let email = CredentialSignInModel.Confirmation(code: .email(domain: "example.com"))
        XCTAssertEqual(r.phases[1], .confirm(email))
        XCTAssertEqual(r.phases[2], .codeSent(email))
        XCTAssertEqual(r.phases[3], .confirm(email), "a refused code: back to typing one")
        XCTAssertEqual(r.phases.last, .signedIn(accountTag: FakeBackend.summary.accountTag))
    }

    func testWrongPasswordThrottleDenialAndExpiry() async throws {
        let cases: [(SteamError, SignInFailure, CredentialSignInModel.Failure)] = [
            (.credentialsRefused(.invalidPassword), .wrongPassword, .wrongPassword),
            (.credentialsRefused(.accountLoginDeniedThrottle), .throttled, .throttled),
            (.credentialsRefused(.rateLimitExceeded), .throttled, .throttled),
            (.authSessionEnded(.accessDenied), .denied, .denied),
            (.authSessionEnded(.expired), .expired, .expired),
            (.authSessionEnded(.fileNotFound), .expired, .expired),
        ]
        for (error, failure, shown) in cases {
            let b = FakeBackend()
            await b.set(credentials: [], .failure(error))
            let s = service(b)
            let r = await signIn(s)
            XCTAssertEqual(r.failure, failure, "\(error)")
            XCTAssertEqual(r.model.phase, .failed(shown), "\(error)")
            XCTAssertNotNil(r.model.message)
            XCTAssertNotNil(r.model.action, "a failed card offers to start again")
            let st = await s.state
            XCTAssertEqual(st, .signedOut, "\(error)")
        }
    }

    func testRefusedWhileSignedInWithoutAskingSteam() async throws {
        let b = FakeBackend()
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        let s = service(b)
        _ = await s.restoreIfPossible()
        let r = await signIn(s)
        guard case .failed = r.failure else { return XCTFail("\(String(describing: r.failure))") }
        let n = await b.count("credentials")
        XCTAssertEqual(n, 0, "no password goes to Steam while an account is signed in")
    }

    // MARK: the card

    func testCardWalkAndCopy() {
        var m = CredentialSignInModel()
        XCTAssertEqual(m.phase, .accountName)
        XCTAssertTrue(m.showsSteps)
        XCTAssertNil(m.message)
        XCTAssertEqual(m.action, "Continue")
        XCTAssertEqual(m.backLabel, "Not now")
        m.setAccountName("   ")
        XCTAssertEqual(m.phase, .accountName, "no name, no password step")
        m.setAccountName("someone")
        XCTAssertEqual(m.phase, .password)
        XCTAssertNil(m.action, "the keyboard is up")
        m.passwordEntered(empty: true)
        XCTAssertEqual(m.phase, .accountName, "an empty password goes back to the name")
        XCTAssertEqual(m.accountName, "someone", "which stays")
        m.setAccountName("someone")
        m.passwordEntered(empty: false)
        XCTAssertEqual(m.message, CredentialSignInModel.Copy.checking)
        XCTAssertEqual(m.backLabel, "Cancel")
        XCTAssertTrue(m.keepsScreenAwake)

        m.apply(.confirm([AuthConfirmation(type: .deviceConfirmation)]))
        XCTAssertEqual(m.message, CredentialSignInModel.Copy.approveInApp)
        XCTAssertNil(m.action, "approval only: nothing to type")
        XCTAssertFalse(m.takesCode)

        m.apply(.confirm([AuthConfirmation(type: .deviceConfirmation), AuthConfirmation(type: .deviceCode)]))
        XCTAssertEqual(m.message, CredentialSignInModel.Copy.approveInApp + " " + CredentialSignInModel.Copy.orCode)
        XCTAssertEqual(m.action, "Enter code")
        m.codeSubmitted()
        XCTAssertEqual(m.message, CredentialSignInModel.Copy.codeSent)
        m.apply(.codeRejected)
        XCTAssertEqual(m.message, CredentialSignInModel.Copy.codeRejected + " " + CredentialSignInModel.Copy.approveInApp + " "
                       + CredentialSignInModel.Copy.orCode, "a refused code, and what still works")
        XCTAssertEqual(m.action, "Enter code again")
        m.apply(.approved(accountTag: "acct#0000"))
        XCTAssertEqual(m.message, CredentialSignInModel.Copy.approved)
        m.apply(.signedIn(SteamService.Account(accountTag: "acct#0000", steamIDTag: "sid#0000", pairedUntil: nil)))
        XCTAssertEqual(m.message, "Signed in as acct#0000.")
        XCTAssertFalse(m.isInFlight)

        m.apply(.cancelled)
        XCTAssertEqual(m.phase, .accountName)
        m.reset()
        XCTAssertEqual(m.phase, .accountName)
    }

    func testConfirmations() {
        typealias C = CredentialSignInModel.Confirmation
        XCTAssertEqual(C([AuthConfirmation(type: .emailCode)]), C(code: .email(domain: nil)))
        XCTAssertEqual(CredentialSignInModel.confirmText(C(code: .email(domain: nil))), "Steam e-mailed you a code. Type it here.")
        XCTAssertEqual(CredentialSignInModel.confirmText(C(code: .email(domain: "example.com"))),
                       "Steam e-mailed a code to your address at example.com. Type it here.")
        XCTAssertEqual(CredentialSignInModel.confirmText(C(code: .app)), CredentialSignInModel.Copy.codeFromApp)
        XCTAssertEqual(CredentialSignInModel.confirmText(C(approve: .email)), CredentialSignInModel.Copy.approveByEmail)
        XCTAssertEqual(C([AuthConfirmation(type: .deviceCode), AuthConfirmation(type: .emailCode)]), C(code: .app),
                       "the app's code before an e-mailed one")
        XCTAssertEqual(C([AuthConfirmation(type: .none)])?.none, true)
        XCTAssertNil(C([AuthConfirmation(type: .machineToken)]), "nothing Playport can do")
        XCTAssertNil(C([]))
        var m = CredentialSignInModel()
        m.setAccountName("someone")
        m.passwordEntered(empty: false)
        m.apply(.confirm([AuthConfirmation(type: .legacyMachineAuth)]))
        XCTAssertEqual(m.phase, .failed(.unsupported))
        XCTAssertEqual(m.message, CredentialSignInModel.Copy.unsupported)
    }

    func testPairingModelNamesTheNewFailures() {
        var p = PairingModel()
        p.apply(SignInFailure.wrongPassword)
        XCTAssertEqual(p.message, CredentialSignInModel.Copy.wrongPassword)
        p.apply(SignInEvent.codeRejected)
        XCTAssertEqual(p.message, CredentialSignInModel.Copy.wrongPassword, "the QR card ignores a credential event")
    }
}
