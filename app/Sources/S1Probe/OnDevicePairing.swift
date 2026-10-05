// SPDX-License-Identifier: GPL-3.0-or-later
// Device-initiated RP pairing: Apple's Bonjour advertises idevice's exact
// identity/TXT/listener. Credentials and PIN stay in memory; JitSetup verifies
// readiness before committing credentials to the this-device-only Keychain.
import Foundation
import Relaunch
import SwiftUI
import UIKit

private final class PairingSession: @unchecked Sendable {
    let cancel = pairable_host_cancel_new()!
    // Only the single worker queue accesses this buffer.
    var data: Data?
    deinit { pairable_host_cancel_free(cancel) }
}

@MainActor
final class OnDevicePairing: NSObject, ObservableObject, @preconcurrency NetServiceDelegate {
    static let shared = OnDevicePairing()
    @Published private(set) var busy = false
    @Published private(set) var status = "Not started"
    @Published private(set) var code: String?
    @Published private(set) var hasNewPairing = false
    @Published private(set) var storedNewPairing = false
    private(set) var pendingData: Data?
    private var attempt: PairingSession?
    private var service: NetService?
    private var background = UIBackgroundTaskIdentifier.invalid
    private var timeout: Task<Void, Never>?
    private var completion: (@MainActor (Data?, String?) -> Void)?
    let codeWindow = PairingCodeWindow()

    func start(completion: (@MainActor (Data?, String?) -> Void)? = nil) {
        guard !busy else { return }
        guard #available(iOS 27.0, *) else { status = "On-device pairing needs iOS 27."; completion?(nil, status); return }
        guard !BuiltInJitStatus.shared.busy, !TitleLaunch.shared.running else {
            status = "Wait for the readiness check or game to finish."; completion?(nil, status); return
        }
        self.completion = completion
        busy = true
        hasNewPairing = false
        storedNewPairing = false
        pendingData = nil
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
        DispatchQueue.global(qos: .userInitiated).async {
            let context = Unmanaged.passUnretained(run).toOpaque()
            let error = pairable_host_accept_bonjour("Playport", pin, { identifier, txt, port, context in
                guard let identifier, let txt, let context else { return }
                let run = Unmanaged<PairingSession>.fromOpaque(context).takeUnretainedValue()
                let name = String(cString: identifier)
                let records = Data(String(cString: txt).utf8)
                DispatchQueue.main.async {
                    OnDevicePairing.shared.advertise(run: run, name: name, records: records, port: port)
                }
            }, { bytes, len, context in
                guard let bytes, let context else { return }
                Unmanaged<PairingSession>.fromOpaque(context).takeUnretainedValue().data = Data(bytes: bytes, count: len)
            }, context, run.cancel)
            let failure = error.map { "Pairing failed [\($0.pointee.code)/\($0.pointee.sub_code)]." }
            if let error { idevice_error_free(error) }
            let data = run.data
            DispatchQueue.main.async { OnDevicePairing.shared.finished(run: run, data: data, failure: failure) }
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
        pendingData = nil
        hasNewPairing = false
        guard let run = attempt else { return }
        status = reason
        code = nil
        stopAdvertising()
        endBackgroundTime()
        pairable_host_cancel_signal(run.cancel)
    }

    private func finished(run: PairingSession, data: Data?, failure: String?) {
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
        if cancelled { done?(nil, status); return }
        if let failure { status = failure; BuiltInJitStatus.log("on-device pairing: \(failure)"); done?(nil, failure); return }
        guard let data else { status = "Pairing returned no credentials."; done?(nil, status); return }
        pendingData = data
        hasNewPairing = true
        status = "Paired. Preparing game debugging…"
        BuiltInJitStatus.log("on-device pairing: credentials received (not logged; not yet stored)")
        done?(data, nil)
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

    func discardCredentials() { pendingData = nil; hasNewPairing = false }

    #if !PLAYPORT_RELEASE
    /// The diagnostic's explicit replacement; the product instead verifies first.
    func useNewPairing() {
        guard let data = pendingData, !busy, !BuiltInJitStatus.shared.busy else { return }
        do {
            try BuiltInJit.storeGeneratedPairing(data)
            discardCredentials()
            storedNewPairing = true
            status = "New pairing stored in the Keychain."
            BuiltInJitStatus.shared.refreshPairingAfterProbe()
        } catch { status = "Could not store the pairing in the Keychain." }
    }
    #endif
}
