// SPDX-License-Identifier: GPL-3.0-or-later
// Sign in to Steam (docs/design/2026-09-28-gamepad-ui/SignIn.dc.html): two
// cards side by side.
//
// "On this phone" (SteamClientKit CredentialSignInModel): A asks for the
// account name on the controller keyboard, then the password on it (drawn as
// dots, kept out of every log); the password goes straight into the sign-in
// (SteamService `.credentials`), which encrypts it with the account's RSA
// key for Steam and drops it. Steam then wants an approval in the Steam
// Mobile app, or a Steam Guard code, which A types on the keyboard. Nothing
// but the refresh token is kept, in the Keychain, as the QR pairing keeps
// it (decision 0004). Leaving for the Steam app to approve does not end the
// attempt: the poll picks the same session up on the way back.
//
// "Another device": the QR pairing as before (PairingModel): a second device
// signed in to Steam scans the code and approves. RB rings it and shows a
// code.
//
// It covers the shell (AppNavigation.signIn), over Settings › Steam account,
// the checklist's Steam step, or whatever `open:signin` found; B cancels a
// running sign-in, else goes back there, as a sign-in that ends signed in does.
// While Steam is signed in (a dev build's `open:signin`, Settings' Preview
// sign-in) it shows a preview: the same screens, and nothing goes to Steam.

import HostIOKit
import PlayportKit
import SteamClientKit
import SwiftUI

@MainActor
final class SignInState: ObservableObject {
    static let shared = SignInState()

    /// The preview's card, when this is one; nil for the real sign-in.
    @Published private(set) var preview: CredentialSignInModel?

    static func log(_ line: String) { WineHostRuntime.appendLog("signin: " + line) }

    func open(preview: Bool) {
        self.preview = preview ? CredentialSignInModel() : nil
        Self.log(preview ? "opened (preview: nothing goes to Steam)" : "opened")
        AppNavigation.shared.openSignIn()
    }

    /// The card shown: the preview's, or the real one.
    func card(_ model: SteamAccountModel) -> CredentialSignInModel { preview ?? model.credentials }

    // MARK: the card's steps

    /// A on the card.
    func activate(_ model: SteamAccountModel) {
        let card = card(model)
        switch card.phase {
        case .accountName, .failed: askName(model)
        case .confirm where card.takesCode: askCode(model)
        default: break
        }
    }

    private func askName(_ model: SteamAccountModel) {
        if preview == nil { model.cancelCredentialSignIn() } else { preview?.reset() }
        PadModal.shared.keyboard(title: "Steam account name", text: card(model).accountName,
                                 placeholder: CredentialSignInModel.Copy.placeholder, maxLength: 64, privacy: .hidden) { [weak self] name in
            guard let self else { return }
            let next: Bool
            if self.preview != nil {
                self.preview?.setAccountName(name)
                next = self.preview?.phase == .password
            } else {
                next = model.credentialName(name)
            }
            if next { self.askPassword(model) }
        }
    }

    private func askPassword(_ model: SteamAccountModel) {
        PadModal.shared.keyboard(title: "Password", text: "", placeholder: "Password", maxLength: 128, privacy: .secret) { [weak self] password in
            guard let self else { return }
            if self.preview != nil {
                self.preview?.passwordEntered(empty: password.isEmpty)
                if !password.isEmpty { self.previewSteam() }
            } else {
                model.credentialPassword(password)
                Self.log(password.isEmpty ? "no password; back to the name" : "password sent to Steam's sign-in (not kept)")
            }
        }
    }

    private func askCode(_ model: SteamAccountModel) {
        PadModal.shared.keyboard(title: "Steam Guard code", text: "", placeholder: "Code", maxLength: 12, privacy: .hidden) { [weak self] code in
            guard let self, !code.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if self.preview != nil {
                self.preview?.codeSubmitted()
                Self.log("preview: a code, not sent")
                // The preview shows a refused code: nothing checks it.
                Task { try? await Task.sleep(for: .seconds(1)); self.preview?.apply(.codeRejected) }
            } else {
                model.submitGuardCode(code)
                Self.log("Steam Guard code sent")
            }
        }
    }

    /// The preview's Steam: after a second, it asks for the app's approval or its code.
    private func previewSteam() {
        Self.log("preview: nothing sent to Steam")
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard preview?.phase == .checking else { return }
            preview?.apply(.confirm([AuthConfirmation(type: .deviceConfirmation), AuthConfirmation(type: .deviceCode)]))
        }
    }

    /// B: a running sign-in (either card's) stops; else the screen closes.
    func back(_ model: SteamAccountModel) {
        if let p = preview, p.isInFlight {
            preview?.reset()
        } else if preview == nil, model.credentials.isInFlight {
            model.cancelCredentialSignIn()
            Self.log("cancelled")
        } else if model.pairing.isInFlight {
            model.cancelPairing()
        } else {
            close(model)
        }
    }

    func close(_ model: SteamAccountModel) {
        if preview == nil {
            if model.credentials.isInFlight { model.cancelCredentialSignIn() }
            if model.pairing.isInFlight { model.cancelPairing() }
        }
        preview = nil
        AppNavigation.shared.closeSignIn()
    }

    /// RB: the QR card, with a code on it.
    func useQR(_ model: SteamAccountModel) {
        PadFocus.shared.ring(SignInView.qrItem)
        guard preview == nil else { return Self.log("preview: no QR code") }
        if !model.pairing.isInFlight { model.startPairing() }
    }

    /// The footer (SignIn.dc.html): A on the ringed card, RB the QR code, B Not now or Cancel.
    func hints(_ model: SteamAccountModel) -> [PadHint] {
        var h: [PadHint] = []
        let focus = PadFocus.shared
        if let a = focus.hint, !a.isEmpty { h.append(PadHint(button: .a, label: a) { focus.activate() }) }
        if focus.focused != SignInView.qrItem { h.append(PadHint(button: .rb, label: "Use QR code") { self.useQR(model) }) }
        let running = card(model).isInFlight || (preview == nil && model.pairing.isInFlight)
        h.append(PadHint(button: .b, label: running ? "Cancel" : "Not now") { self.back(model) })
        return h
    }

    /// A press on this screen: directions and A move and run the ring, the rest are the footer's.
    func press(_ b: NavButton, _ model: SteamAccountModel) {
        let focus = PadFocus.shared
        switch b {
        case .up: focus.move(.up)
        case .down: focus.move(.down)
        case .left, .lb: focus.move(.left)
        case .right: focus.move(.right)
        case .a: focus.activate()
        case .rb: useQR(model)
        case .b: back(model)
        default: break
        }
    }

    /// What the driver's `pad:` log names.
    func summary(_ model: SteamAccountModel) -> String {
        let c = card(model)
        return "signin\(preview == nil ? "" : " preview") \(Self.phaseName(c.phase))"
            + (c.accountName.isEmpty ? "" : ", name typed") + (c.codeRejected ? ", code refused" : "")
            + ", qr \(Self.pairingName(model.pairing.phase))"
    }

    static func phaseName(_ p: CredentialSignInModel.Phase) -> String {
        switch p {
        case .accountName: "account-name"
        case .password: "password"
        case .checking: "checking"
        case .confirm(let c): "confirm(" + [c.approve.map { "approve-\($0)" }, c.code.map { if case .app = $0 { "code-app" } else { "code-email" } }]
            .compactMap { $0 }.joined(separator: ",") + ")"
        case .codeSent: "code-sent"
        case .approved: "approved"
        case .signedIn: "signed-in"
        case .failed(let f): "failed(\(f))"
        }
    }

    static func pairingName(_ p: PairingModel.Phase) -> String {
        switch p {
        case .intro: "intro"
        case .requesting: "requesting"
        case .showingCode: "code"
        case .scanned: "scanned"
        case .approved: "approved"
        case .paired: "paired"
        case .expired: "expired"
        case .denied: "denied"
        case .interrupted: "interrupted"
        case .failed: "failed"
        }
    }
}

struct SignInView: View {
    static let cardItem = "signin:phone"
    static let qrItem = "signin:qr"
    static let startItem = cardItem
    /// The footer's grey note at the left.
    static let footerNote = "Games already in C:\\Games play without Steam"

    @EnvironmentObject private var model: SteamAccountModel
    @ObservedObject private var state = SignInState.shared
    @ObservedObject private var focus = PadFocus.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("Sign in to Steam").font(PP.display(28))
                Text("Your games, cloud saves and achievements. Playport keeps no password.")
                    .font(.system(size: 13)).foregroundStyle(PP.muted).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.top, 20).padding(.bottom, 12)
            HStack(alignment: .top, spacing: 16) {
                phoneCard
                qrCard.frame(width: 330)
            }
            // Clear of the footer's line, the ring too (SignIn.dc.html: 14 pt).
            .padding(.bottom, 14)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(PP.text)
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Signed in (either card, not a preview): back where the sign-in came from.
        .onChange(of: model.state) { _, s in
            guard state.preview == nil, case .signedIn = s else { return }
            SignInState.log("signed in; closing")
            Task { try? await Task.sleep(for: .seconds(1.5)); if AppNavigation.shared.signIn { state.close(model) } }
        }
        .onChange(of: SignInState.phaseName(state.card(model).phase)) { _, p in SignInState.log("card: " + p) }
    }

    // MARK: on this phone

    private var phoneCard: some View {
        let card = state.card(model)
        return VStack(alignment: .leading, spacing: 10) {
            Text(CredentialSignInModel.Copy.label.uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(1.1).foregroundStyle(PP.accent)
            Text(CredentialSignInModel.Copy.heading).font(PP.display(21))
            if card.showsSteps {
                ForEach(Array(CredentialSignInModel.Copy.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(i + 1)").font(.system(size: 11, weight: .bold))
                            .frame(width: 20, height: 20).background(PP.line, in: Circle())
                        Text(step).font(.system(size: 13)).foregroundStyle(PP.soft).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if let m = card.message {
                HStack(alignment: .top, spacing: 10) {
                    if card.isInFlight, !card.takesCode || card.phase == .checking { ProgressView().controlSize(.small).tint(PP.muted) }
                    Text(m).font(.system(size: 14))
                        .foregroundStyle(card.codeRejected || { if case .failed = card.phase { true } else { false } }() ? PP.accent : PP.soft)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("signin-message")
                }
            }
            Spacer(minLength: 0)
            if state.preview != nil {
                Text("Preview: nothing here goes to Steam.")
                    .font(.system(size: 11)).foregroundStyle(PP.muted)
            }
            nameField(card)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 16))
        .padItem(Self.cardItem, hint: card.action ?? "", cornerRadius: 16) { state.activate(model) }
    }

    private func nameField(_ card: CredentialSignInModel) -> some View {
        HStack(spacing: 8) {
            Text(card.accountName.isEmpty ? CredentialSignInModel.Copy.placeholder : card.accountName)
                .font(.system(size: 14)).foregroundStyle(card.accountName.isEmpty ? PP.muted : PP.text).lineLimit(1)
            Spacer(minLength: 0)
            if !card.accountName.isEmpty, card.isInFlight {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(PP.muted)
                Text("Password sent").font(.system(size: 12)).foregroundStyle(PP.muted)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(PP.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0x4A5667), lineWidth: 1))
        .padding(.top, 4)
    }

    // MARK: another device

    private var qrCard: some View {
        let pairing = model.pairing
        return HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(PP.text)
                // Hidden unless active, so the app switcher's snapshot never holds the code.
                if state.preview == nil, scenePhase == .active, let code = pairing.code, let image = QRImage.make(code.payload) {
                    Image(uiImage: image).interpolation(.none).resizable().scaledToFit().padding(6)
                        .accessibilityLabel("Steam sign-in QR code \(code.fingerprint)")
                } else {
                    Image(systemName: "qrcode").font(.system(size: 54, weight: .light)).foregroundStyle(Color(hex: 0x3A4452))
                }
            }
            .frame(width: 132, height: 132)
            VStack(alignment: .leading, spacing: 8) {
                Text("ANOTHER DEVICE").font(.system(size: 11, weight: .semibold)).tracking(1.1).foregroundStyle(PP.muted)
                Text("Scan with the Steam app").font(PP.display(19)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(qrText(pairing, at: context.date))
                        .font(.system(size: 12)).foregroundStyle(PP.muted).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 16))
        .padItem(Self.qrItem, hint: state.preview == nil ? pairing.actionTitle ?? "" : "", cornerRadius: 16) {
            guard state.preview == nil, pairing.actionTitle != nil else { return }
            model.startPairing()
        }
    }

    private func qrText(_ p: PairingModel, at date: Date) -> String {
        let path = "Steam app › Steam Guard › Scan a QR code."
        switch p.phase {
        case .intro: return path + " RB shows a code."
        case .showingCode(let c): return path + " Code \(c.fingerprint), new code in \(p.countdown(at: date))."
        default: return p.message
        }
    }
}
