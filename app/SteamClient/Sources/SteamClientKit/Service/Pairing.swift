// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The Pair-with-Steam screen as a value: which state it is in and what it
/// says. The SwiftUI view only renders it, so every state and its copy is
/// unit-tested without a device (docs/ARCHITECTURE.md, Native Steam client).
public struct PairingModel: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// The intro card, before a code is requested.
        case intro
        /// Waiting for Steam's first challenge.
        case requesting
        /// A code is on screen.
        case showingCode(QRCode)
        /// The other device scanned it and shows the approval prompt.
        case scanned
        /// Approved; logging on and loading the library.
        case approved(accountTag: String)
        case paired(SteamService.Account)
        case expired
        case denied
        /// The app left the foreground; that attempt was cancelled.
        case interrupted
        case failed(String)
    }

    public private(set) var phase: Phase = .intro

    public init() {}

    // MARK: copy

    public enum Copy {
        public static let intro = "Open the Steam app on another phone or tablet signed in to your account, and scan this code. Keep Playport open until it confirms."
        public static let warning = "Don't switch to Steam on this phone; the sign-in will expire."
        public static let requesting = "Getting a code from Steam…"
        public static let scanned = "Approve on your other device…"
        public static let approved = "Paired. Loading your library…"
        public static let expired = "Code expired; show a new one"
        public static let denied = "Sign-in was declined"
        public static let interrupted = "Playport left the screen, so that code stopped working. Show a new one."
        public static let showNewCode = "Show a new code"
        public static let start = "Show code"
    }

    // MARK: transitions

    public mutating func start() { phase = .requesting }

    public mutating func apply(_ event: SignInEvent) {
        switch event {
        case let .code(c): phase = .showingCode(c)
        case .scanned: phase = .scanned
        case let .approved(tag): phase = .approved(accountTag: tag)
        case let .signedIn(a): phase = .paired(a)
        case .confirm, .codeAccepted, .codeRejected: break   // a credential sign-in's (CredentialSignInModel)
        }
    }

    /// The attempt ended without a session. A cancellation caused by leaving
    /// the foreground has already moved the screen to `.interrupted`, which a
    /// late `cancelled` must not overwrite.
    public mutating func apply(_ failure: SignInFailure) {
        switch failure {
        case .expired: phase = .expired
        case .denied: phase = .denied
        case .cancelled: if phase != .interrupted { phase = .intro }
        case .busy: phase = .failed("Steam is busy with another sign-in. Try again in a moment.")
        case .wrongPassword: phase = .failed(CredentialSignInModel.Copy.wrongPassword)
        case .throttled: phase = .failed(CredentialSignInModel.Copy.throttled)
        case let .network(s): phase = .failed("Steam can't be reached (\(s)).")
        case let .failed(s): phase = .failed(s)
        }
    }

    /// The scene left `.active` while a code was up (a suspended poll kills the
    /// Steam session anyway): the caller cancels the attempt.
    public mutating func sceneBecameInactive() {
        if isInFlight { phase = .interrupted }
    }

    // MARK: presentation

    /// A sign-in stream is running for this phase.
    public var isInFlight: Bool {
        switch phase {
        case .requesting, .showingCode, .scanned, .approved: return true
        default: return false
        }
    }

    /// The QR code to draw; nil in every state but `showingCode`.
    public var code: QRCode? {
        if case let .showingCode(c) = phase { return c }
        return nil
    }

    /// The screen stays awake while a code or the approval is pending.
    public var keepsScreenAwake: Bool { isInFlight }

    public var message: String {
        switch phase {
        case .intro, .showingCode: return Copy.intro
        case .requesting: return Copy.requesting
        case .scanned: return Copy.scanned
        case .approved: return Copy.approved
        case let .paired(a): return "Paired as \(a.accountTag)."
        case .expired: return Copy.expired
        case .denied: return Copy.denied
        case .interrupted: return Copy.interrupted
        case let .failed(s): return s
        }
    }

    /// The warning shows with the intro and the code: the times a switch to
    /// Steam on this phone would kill the attempt.
    public var showsWarning: Bool {
        switch phase {
        case .intro, .requesting, .showingCode, .scanned: return true
        default: return false
        }
    }

    /// The button under the message, if any.
    public var actionTitle: String? {
        switch phase {
        case .intro: return Copy.start
        case .expired, .denied, .interrupted, .failed: return Copy.showNewCode
        default: return nil
        }
    }

    /// Whole seconds left on the code's countdown, never negative.
    public func secondsRemaining(at date: Date) -> Int {
        guard let c = code else { return 0 }
        return max(0, Int(c.expiresAt.timeIntervalSince(date).rounded(.up)))
    }

    /// "m:ss" for the countdown.
    public func countdown(at date: Date) -> String {
        let s = secondsRemaining(at: date)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The sign-in card "On this phone" (SignIn.dc.html) as a value: the account
/// name, then the password on the controller keyboard, then an approval in
/// the Steam Mobile app or a Steam Guard code (SteamService's
/// `.credentials` sign-in). The view renders it; every state and its copy is
/// tested here. The password never enters this value: the keyboard hands it
/// straight to the sign-in.
public struct CredentialSignInModel: Sendable, Equatable {
    /// How Steam lets this sign-in be confirmed (from `allowed_confirmations`).
    public struct Confirmation: Sendable, Equatable {
        /// A request to approve in the Steam Mobile app (or a link in an e-mail).
        public var approve: Approve?
        /// A code to type: the Steam Mobile app's Steam Guard code, or one sent by e-mail.
        public var code: Code?

        public enum Approve: Sendable, Equatable { case app, email }
        public enum Code: Sendable, Equatable { case app, email(domain: String?) }

        public init(approve: Approve? = nil, code: Code? = nil) { self.approve = approve; self.code = code }

        /// nil when Steam asks for nothing Playport can do (a legacy machine token).
        public init?(_ allowed: [AuthConfirmation]) {
            let types = allowed.map(\.type)
            approve = types.contains(.deviceConfirmation) ? .app : types.contains(.emailConfirmation) ? .email : nil
            if types.contains(.deviceCode) {
                code = .app
            } else if let e = allowed.first(where: { $0.type == .emailCode }) {
                code = .email(domain: e.message)
            } else {
                code = nil
            }
            guard approve != nil || code != nil || types.contains(.none) else { return nil }
        }

        /// Steam asked for no confirmation: the approval comes by itself.
        public var none: Bool { approve == nil && code == nil }
    }

    public enum Failure: Sendable, Equatable {
        case wrongPassword, throttled, expired, denied, unsupported, busy
        case network(String)
        case other(String)
    }

    public enum Phase: Sendable, Equatable {
        /// The card before a name is typed, or with the name typed and no password yet.
        case accountName
        /// The password keyboard is up.
        case password
        /// The password went to Steam; waiting for its answer.
        case checking
        /// Steam took the password; waiting for the approval or a code.
        case confirm(Confirmation)
        /// A code went to Steam; waiting for the approval that follows it.
        case codeSent(Confirmation)
        /// Approved; logging on and loading the library.
        case approved
        case signedIn(accountTag: String)
        case failed(Failure)
    }

    public private(set) var phase: Phase = .accountName
    public private(set) var accountName = ""
    /// The last code sent was refused (shown until the next one goes).
    public private(set) var codeRejected = false

    public init() {}

    // MARK: copy

    public enum Copy {
        public static let heading = "Approve in the Steam app"
        public static let label = "On this phone"
        public static let steps = [
            "Type your Steam account name with the controller keyboard.",
            "Then your password. It goes to Steam encrypted, and Playport keeps none of it.",
            "Approve the sign-in in the Steam Mobile app, or type its Steam Guard code.",
        ]
        public static let placeholder = "Account name"
        public static let checking = "Checking with Steam…"
        public static let approveInApp = "Steam sent a sign-in request to the Steam Mobile app. Approve it there, then come back."
        public static let approveByEmail = "Steam e-mailed you a link to approve this sign-in. Open it, then come back."
        public static let orCode = "Or type the Steam Guard code the app shows."
        public static let codeFromApp = "Type the Steam Guard code the Steam Mobile app shows."
        public static let codeSent = "Checking the code…"
        public static let codeRejected = "That code didn't work. Check it and try again."
        public static let approved = "Approved. Loading your library…"
        public static let wrongPassword = "Steam didn't accept that account name and password."
        public static let throttled = "Steam has seen too many sign-in attempts from here. Wait a while, or use the QR code."
        public static let expired = "The sign-in request expired. Start again."
        public static let denied = "The sign-in was declined in the Steam app."
        public static let unsupported = "Steam asks for a confirmation Playport can't do here. Use the QR code."
        public static let busy = "Steam is busy with another sign-in. Try again in a moment."

        public static func codeByEmail(_ domain: String?) -> String {
            domain.map { "Steam e-mailed a code to your address at \($0). Type it here." } ?? "Steam e-mailed you a code. Type it here."
        }
    }

    // MARK: transitions

    /// The name keyboard closed: with a name, the password comes next.
    public mutating func setAccountName(_ name: String) {
        accountName = name.trimmingCharacters(in: .whitespaces)
        phase = accountName.isEmpty ? .accountName : .password
    }

    /// The password keyboard closed: empty goes back to the name, else it goes to Steam.
    public mutating func passwordEntered(empty: Bool) {
        codeRejected = false
        phase = empty ? .accountName : .checking
    }

    public mutating func apply(_ event: SignInEvent) {
        switch event {
        case let .confirm(allowed):
            if let c = Confirmation(allowed) { phase = .confirm(c) } else { phase = .failed(.unsupported) }
        case .codeRejected:
            codeRejected = true
            if case let .codeSent(c) = phase { phase = .confirm(c) }
        case .codeAccepted:
            codeRejected = false
        case .approved: phase = .approved
        case let .signedIn(a): phase = .signedIn(accountTag: a.accountTag)
        case .code, .scanned: break   // the QR card's (PairingModel)
        }
    }

    /// A code was typed and sent.
    public mutating func codeSubmitted() {
        codeRejected = false
        if case let .confirm(c) = phase { phase = .codeSent(c) }
    }

    public mutating func apply(_ failure: SignInFailure) {
        switch failure {
        case .wrongPassword: phase = .failed(.wrongPassword)
        case .throttled: phase = .failed(.throttled)
        case .expired: phase = .failed(.expired)
        case .denied: phase = .failed(.denied)
        case .busy: phase = .failed(.busy)
        case let .network(s): phase = .failed(.network(s))
        case let .failed(s): phase = .failed(.other(s))
        case .cancelled: phase = .accountName
        }
    }

    /// Cancelled, or started over: the name stays.
    public mutating func reset() {
        phase = .accountName
        codeRejected = false
    }

    // MARK: presentation

    /// A sign-in is running (the password went to Steam).
    public var isInFlight: Bool {
        switch phase {
        case .checking, .confirm, .codeSent, .approved: return true
        default: return false
        }
    }

    /// The screen stays awake while Steam's answer or the approval is pending.
    public var keepsScreenAwake: Bool { isInFlight }

    /// A code can be typed now.
    public var takesCode: Bool {
        if case let .confirm(c) = phase { return c.code != nil }
        return false
    }

    /// The card's step list shows before the password goes (the design's two steps and ours).
    public var showsSteps: Bool {
        switch phase {
        case .accountName, .password: return true
        default: return false
        }
    }

    /// The line under the heading once the steps are gone; nil while they show.
    public var message: String? {
        switch phase {
        case .accountName, .password: return nil
        case .checking: return Copy.checking
        case let .confirm(c):
            return (codeRejected ? Copy.codeRejected + " " : "") + Self.confirmText(c)
        case .codeSent: return Copy.codeSent
        case .approved: return Copy.approved
        case let .signedIn(tag): return "Signed in as \(tag)."
        case let .failed(f):
            switch f {
            case .wrongPassword: return Copy.wrongPassword
            case .throttled: return Copy.throttled
            case .expired: return Copy.expired
            case .denied: return Copy.denied
            case .unsupported: return Copy.unsupported
            case .busy: return Copy.busy
            case let .network(s): return "Steam can't be reached (\(s))."
            case let .other(s): return s
            }
        }
    }

    static func confirmText(_ c: Confirmation) -> String {
        switch (c.approve, c.code) {
        case (.app?, .app?): return Copy.approveInApp + " " + Copy.orCode
        case (.app?, _): return Copy.approveInApp
        case (.email?, nil): return Copy.approveByEmail
        case (_, .app?): return Copy.codeFromApp
        case let (_, .email(domain)?): return Copy.codeByEmail(domain)
        case (nil, nil): return Copy.checking
        }
    }

    /// What A does on the card: the footer's label, nil when A does nothing now.
    public var action: String? {
        switch phase {
        case .accountName: return "Continue"
        case .password: return nil
        case .confirm: return takesCode ? (codeRejected ? "Enter code again" : "Enter code") : nil
        case .failed(.wrongPassword): return "Try again"
        case .failed: return "Start again"
        default: return nil
        }
    }

    /// B on the screen: cancel a running sign-in, else leave.
    public var backLabel: String { isInFlight ? "Cancel" : "Not now" }
}

/// The Account screen's headline for each account state.
public enum AccountCopy {
    public static func status(_ state: SteamService.AccountState) -> String {
        switch state {
        case .unknown, .restoring: return "Checking your Steam sign-in…"
        case .signedOut: return "Signed out"
        case .pairing: return "Pairing"
        case let .signedIn(a): return "Signed in as \(a.accountTag)"
        case let .offline(a, reason): return "Signed in as \(a.accountTag) (offline: \(reason))"
        case .expired: return "Session expired (pair again)"
        }
    }

    /// "Paired until <date>" from the token's `exp`.
    public static func pairedUntil(_ a: SteamService.Account, style: (Date) -> String) -> String {
        guard let d = a.pairedUntil else { return "Pairing expiry unknown" }
        return "Paired until \(style(d))"
    }

    public static let signOutNote = "Installed games and saves stay on this phone"
}
