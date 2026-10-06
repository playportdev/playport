// SPDX-License-Identifier: GPL-3.0-or-later
// Root-owned, same-phone setup. A pending Play awaits sheet dismissal before
// starting the runtime; no title, code or temporary credential persists on disk.
// A first run starts at the checklist (UI/SetupView.swift), whose pairing step
// begins this; a Play with no pairing or LocalDevVPN down begins it too (ensureReady).
import Foundation
import os
import SwiftUI
import UIKit

@MainActor
final class JitSetup: ObservableObject {
    static let shared = JitSetup()
    enum Phase { case preparing, pairing, vpn, connectingVPN, checking, failed, ready, cancelled }
    @Published private(set) var presented = false
    @Published private(set) var phase = Phase.preparing
    @Published private(set) var message = "Preparing game debugging…"
    private var visible = false
    private var generation = 0
    private var repair = false
    private var original: Data?
    private var candidate: Data?
    private var cancellation = OSAllocatedUnfairLock(initialState: false)
    private var waiter: CheckedContinuation<Bool, Never>?
    private var preparation: Task<Void, Never>?
    private var dismissing = false
    private var replacementConflict = false


    /// Same entry for the game button and driver. Existing credentials with an
    /// active VPN do not require another sheet/check before each ordinary Play.
    var isActive: Bool { presented || visible || dismissing }

    func ensureReady() async -> Bool {
        guard !TitleLaunch.shared.running, !TitleLaunch.shared.spent else { return false }
        // A setup already visible (the checklist's pairing step) may be up before the driver's Play.
        // Join it once; subsequent duplicate Play requests are refused.
        if isActive {
            guard waiter == nil else { return false }
            return await withCheckedContinuation { waiter = $0 }
        }
        guard waiter == nil else { return false }
        // JIT from another app (JitMethod): that app has its own pairing and tunnel.
        guard JitProvider.method.usesPairing else { return true }
        do {
            if try BuiltInJit.storedPairingData() != nil, LocalDevVPN.tunnelUp { return true }
        } catch { /* Present a recoverable Keychain error, not an automatic replacement. */ }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            begin()
        }
    }

    func begin(repair: Bool = false) {
        guard !presented, !visible, !dismissing, !TitleLaunch.shared.running, !TitleLaunch.shared.spent else { return }
        replacementConflict = false
        preparation?.cancel()
        preparation = nil
        generation += 1
        cancellation = OSAllocatedUnfairLock(initialState: false)
        self.repair = repair
        original = nil
        candidate = nil
        visible = false
        phase = .preparing
        message = "Preparing game debugging…"
        presented = true
    }

    func appeared() { visible = true; advance() }
    func sceneBecameActive() {
        OnDevicePairing.shared.codeWindow.dock()
        if presented, visible { advance() }
    }

    private func advance() {
        guard presented, visible, UIApplication.shared.applicationState == .active else { return }
        switch phase {
        case .preparing:
            guard preparation == nil else { return }
            let id = generation
            preparation = Task {
                defer { if id == generation { preparation = nil } }
                while BuiltInJitStatus.shared.busy || OnDevicePairing.shared.busy {
                    guard id == generation, presented, !Task.isCancelled else { return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard id == generation, presented, UIApplication.shared.applicationState == .active else { return }
                guard BuiltInJit.hasGetTaskAllow else {
                    fail("This install cannot enable game debugging. Re-sign Playport with a development signature."); return
                }
                if candidate == nil {
                    do { original = try BuiltInJit.storedPairingData() }
                    catch { fail("The Keychain could not be read. Unlock this iPhone and try again. Your pairing was not replaced."); return }
                }
                if candidate == nil && (original == nil || repair) {
                    phase = .pairing
                    message = "Pair this iPhone"
                    OnDevicePairing.shared.start { data, failure in
                        guard id == self.generation, self.presented else { return }
                        guard let data else { self.fail(failure ?? "Pairing did not complete."); return }
                        self.candidate = data
                        self.phase = .vpn
                        self.advance()
                    }
                } else {
                    phase = .vpn
                    advance()
                }
            }
        case .vpn:
            if LocalDevVPN.tunnelUp { checkReadiness(); return }
            phase = .connectingVPN
            message = "Connecting LocalDevVPN… Allow its VPN configuration if iOS asks."
            let id = generation
            LocalDevVPN.connect { outcome in
                guard id == self.generation, self.presented else { return }
                switch outcome {
                case .connected:
                    self.phase = .vpn
                    self.advance()
                case .notInstalled:
                    self.fail("Install LocalDevVPN from the App Store page, open it once to allow its VPN, then return and tap Continue.")
                case .notConnected:
                    self.fail("LocalDevVPN is not connected. Open it and allow its VPN configuration, then tap Continue.")
                case .late:
                    self.fail("Welcome back. Tap Continue to finish setting up game debugging.")
                }
            }
        case .ready: finishPresentation()
        default: break
        }
    }

    private func checkReadiness() {
        guard !BuiltInJitStatus.shared.busy else {
            phase = .preparing
            advance()
            return
        }
        phase = .checking
        message = "Preparing game debugging… The disk image downloads and mounts automatically."
        let id = generation
        BuiltInJitStatus.shared.check(pairingFile: candidate, cancelled: cancellation) { status in
            guard id == self.generation, self.presented else { return }
            guard status == "ready" else {
                self.fail(status == "unreachable"
                    ? "LocalDevVPN could not be reached. Connect it, then tap Continue."
                    : "Game debugging could not be prepared. Tap Continue to try again.")
                return
            }
            do {
                if let data = self.candidate {
                    try BuiltInJit.commitGeneratedPairing(data, replacing: self.original)
                    BuiltInJitStatus.shared.generatedPairingCommitted()
                    OnDevicePairing.shared.discardCredentials()
                    self.candidate = nil
                    BuiltInJitStatus.log("on-device setup: verified pairing committed to Keychain")
                }
            } catch {
                if case BuiltInJit.Failure.helper(let why) = error, why.contains("changed during setup") {
                    self.replacementConflict = true
                    self.candidate = nil
                    self.repair = false
                    OnDevicePairing.shared.discardCredentials()
                    self.fail("Another pairing was saved during setup. Tap Continue to use it; it was not replaced.")
                } else {
                    self.fail("The pairing could not be saved. Your existing pairing was not replaced.")
                }
                return
            }
            self.phase = .ready
            self.message = "Ready"
            // Never launch/dismiss over system Settings or another app.
            if UIApplication.shared.applicationState == .active { self.finishPresentation() }
        }
    }

    private func finishPresentation() {
        guard presented else { return }
        if visible { dismissing = true }
        presented = false
        if !visible { resumeWaiter(phase == .ready) }
    }

    func retry() {
        guard presented, phase == .failed else { return }
        if replacementConflict {
            replacementConflict = false
            original = nil
            phase = .preparing
        } else if candidate != nil || (!repair && original != nil) {
            phase = .vpn
        } else { phase = .preparing }
        advance()
    }

    private func fail(_ text: String) { phase = .failed; message = text }

    func cancel() {
        preparation?.cancel()
        preparation = nil
        generation += 1
        cancellation.withLock { $0 = true }
        OnDevicePairing.shared.stop()
        candidate = nil
        original = nil
        phase = .cancelled
        finishPresentation()
    }

    private func resumeWaiter(_ ready: Bool) {
        let continuation = waiter
        waiter = nil
        continuation?.resume(returning: ready)
    }

    /// Root sheet onDismiss: consume a pending Play exactly once, after the
    /// presentation has gone. Cold launch never resurrects an executable request.
    func dismissed() {
        visible = false
        dismissing = false
        let ready = phase == .ready
        if !ready { cancel() }
        original = nil
        candidate = nil
        resumeWaiter(ready)
    }
}

struct JitSetupSheet: View {
    @ObservedObject private var setup = JitSetup.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Set up game debugging").font(.title2.bold())
                    if setup.phase == .pairing {
                        if let code = pairing.code {
                            // Plain text first: the picture-in-picture layer below shows
                            // nothing for someone who has picture in picture turned off.
                            Text("Pairing code").font(.headline).foregroundStyle(.secondary)
                            Text(verbatim: String(code.prefix(3)) + " " + String(code.suffix(3)))
                                .font(.system(size: 56, weight: .semibold, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("Pairing code \(code.map(String.init).joined(separator: " "))")
                            PairingCodeView(window: pairing.codeWindow)
                                .aspectRatio(720.0 / 270.0, contentMode: .fit)
                            Text("If the code does not float over Settings (Picture in Picture is off in Settings → General), remember it before you tap Open Settings.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Open Settings") { pairing.openSettings() }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                        Text(pairing.status)
                        Text("Playport finishes setup by itself when you come back.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        if setup.phase != .failed { ProgressView() }
                        Text(setup.message)
                    }
                    if setup.phase == .failed {
                        Button("Continue") { setup.retry() }.buttonStyle(.borderedProminent)
                        Button("Playport permissions in iOS Settings") {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                        }
                    }
                    Text("Developer Mode and system permissions need your approval. No computer or pairing file is needed on iOS 27.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { setup.cancel() } } }
        }
        .interactiveDismissDisabled()
        .onAppear { setup.appeared() }
    }
}
