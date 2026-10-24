// SPDX-License-Identifier: GPL-3.0-or-later
// Device-initiated RP pairing: Apple's Bonjour advertises idevice's exact
// identity/TXT/listener. The helper generates and keeps credentials; only PIN,
// public Bonjour records and an opaque candidate token reach this process.
import Foundation
import os
import SwiftUI
import UIKit

private final class PairingSession: @unchecked Sendable {
    let cancel = OSAllocatedUnfairLock(initialState: false)
}

@MainActor
final class OnDevicePairing: NSObject, ObservableObject, @preconcurrency NetServiceDelegate {
    static let shared = OnDevicePairing()
    @Published private(set) var busy = false
    @Published private(set) var status = "Not started"
    @Published private(set) var code: String?
    @Published private(set) var hasNewPairing = false
    @Published private(set) var storedNewPairing = false
    private(set) var pendingToken: String?
    private var attempt: PairingSession?
    private var service: NetService?
    private var background = UIBackgroundTaskIdentifier.invalid
    private var timeout: Task<Void, Never>?
    private var completion: (@MainActor (String?, String?) -> Void)?
    let codeWindow = PairingCodeWindow()

    func start(completion: (@MainActor (String?, String?) -> Void)? = nil) {
        guard !busy, BuiltInJit.mayHandleCredentials else { return }
        guard #available(iOS 27.0, *) else { status = "On-device pairing needs iOS 27."; completion?(nil, status); return }
        guard !BuiltInJitStatus.shared.busy, !TitleLaunch.shared.running else {
            status = "Wait for the readiness check or game to finish."; completion?(nil, status); return
        }
        self.completion = completion
        busy = true
        hasNewPairing = false
        storedNewPairing = false
        discardCredentials()
        let pin = String(format: "%06d", Int.random(in: 0..<1_000_000))
        code = pin
        codeWindow.show(pin)
        status = "Starting Bonjour…"
        let run = PairingSession()
        attempt = run
        background = UIApplication.shared.beginBackgroundTask(withName: "Playport pairing") {
            Task { @MainActor in
                guard self.attempt === run else { return }
                self.stop(reason: "iOS ended the background time. Return to Playport and try again.")
            }
        }
        timeout = Task {
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled, attempt === run else { return }
            stop(reason: "No pairing completed within 90 seconds. Try again.")
        }
        BuiltInJitStatus.log("on-device pairing: starting Bonjour")
        Task {
            do {
                let token = try await BuiltInJit.pair(pin: pin, cancelled: run.cancel) { name, records, port in
                    DispatchQueue.main.async {
                        OnDevicePairing.shared.advertise(run: run, name: name, records: records, port: port)
                    }
                }
                finished(run: run, token: token, failure: nil)
            } catch { finished(run: run, token: nil, failure: error.localizedDescription) }
        }
    }

    private func advertise(run: PairingSession, name: String, records: Data, port: UInt16) {
        guard attempt === run, busy, code != nil else { return }
        guard let txt = (try? JSONSerialization.jsonObject(with: records)) as? [String: String] else {
            stop(reason: "The pairing host returned invalid Bonjour records."); return
        }
        let s = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: name, port: Int32(port))
        s.delegate = self
        s.setTXTRecord(NetService.data(fromTXTRecord: txt.mapValues { Data($0.utf8) }))
        service = s
        // NetService's delegate callbacks run on this explicitly scheduled main run loop.
        s.schedule(in: .main, forMode: .common)
        s.publish()
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard service === sender else { return }
        status = "Tap Open Settings, then Privacy & Security → Developer Mode → Pair with Playport, and enter this code. With Picture in Picture on, it stays on screen over Settings. Return here afterwards."
        BuiltInJitStatus.log("on-device pairing: Bonjour published")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard service === sender else { return }
        BuiltInJitStatus.log("on-device pairing: Bonjour publication failed \(errorDict)")
        stop(reason: "Bonjour could not advertise Playport. Allow Local Network access in Playport’s iOS Settings, then try again.")
    }

    func stop(reason: String = "Cancelled") {
        discardCredentials()
        guard let run = attempt else { return }
        status = reason
        code = nil
        stopAdvertising()
        endBackgroundTime()
        run.cancel.withLock { $0 = true }
    }

    private func finished(run: PairingSession, token: String?, failure: String?) {
        guard attempt === run else { return }
        attempt = nil
        stopAdvertising()
        timeout?.cancel()
        timeout = nil
        endBackgroundTime()
        let cancelled = code == nil
        code = nil
        busy = false
        let done = completion
        completion = nil
        if cancelled {
            if let token { BuiltInJit.discardPairing(token) }
            done?(nil, status)
            return
        }
        if let failure { status = failure; BuiltInJitStatus.log("on-device pairing: \(failure)"); done?(nil, failure); return }
        guard let token else { status = "Pairing returned no candidate."; done?(nil, status); return }
        pendingToken = token
        hasNewPairing = true
        status = "Paired. Preparing game debugging…"
        BuiltInJitStatus.log("on-device pairing: helper candidate ready (no credentials exported)")
        done?(token, nil)
    }

    private func stopAdvertising() {
        codeWindow.close()
        service?.delegate = nil
        service?.stop()
        service?.remove(from: .main, forMode: .common)
        service = nil
    }

    private func endBackgroundTime() {
        if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
    }

    func discardCredentials() {
        if let token = pendingToken { BuiltInJit.discardPairing(token) }
        pendingToken = nil
        hasNewPairing = false
    }

    #if !PLAYPORT_RELEASE
    /// The diagnostic's explicit replacement; the product instead verifies first.
    func useNewPairing() {
        guard let token = pendingToken, !busy, !BuiltInJitStatus.shared.busy else { return }
        Task {
            do {
                let original = try await BuiltInJit.storedPairingRevision()
                try await BuiltInJit.commitGeneratedPairing(token, replacing: original)
                discardCredentials()
                storedNewPairing = true
                status = "New pairing stored in the helper Keychain."
                BuiltInJitStatus.shared.refreshPairingAfterProbe()
            } catch { status = "Could not store the pairing in the helper Keychain." }
        }
    }
    #endif
}
