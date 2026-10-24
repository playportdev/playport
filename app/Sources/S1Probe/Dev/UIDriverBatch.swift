// SPDX-License-Identifier: GPL-3.0-or-later
// Dev-only queue mechanics, shared verbatim with the Linux host regression harness.
import Foundation

@MainActor
final class UIDriverBatch {
    private(set) var ended = false
    private(set) var failure: String?
    private(set) var handingOff = false
    private var observedActive = false

    struct Stopped: Error, CustomStringConvertible {
        let description: String
    }
    var active: () -> Bool
    var now: () -> TimeInterval
    var sleep: (Duration) async throws -> Void
    var onCancel: (String) -> Void = { _ in }
    var cancelRequested: () -> Bool = { false }

    static func cancellationRequested(nonce: String, read: (String) -> String?) -> Bool {
        guard nonce.count == 8, nonce.allSatisfy({ "0123456789abcdef".contains($0) }) else { return false }
        return read("ui-cancel-\(nonce)") == nonce
    }

    init(active: @escaping () -> Bool,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.active = active
        self.now = now
        self.sleep = sleep
    }

    // Initial inactive is normal during launch; after the first active observation,
    // even a transient inactive transition permanently revokes this batch.
    func sceneChanged(active: Bool) {
        guard !ended else { return }
        if active { observedActive = true }
        else if observedActive { cancel("Playport left foreground (inactive/background)") }
    }

    func checkpoint() throws {
        if cancelRequested() { cancel("host requested cancellation for this batch") }
        if Task.isCancelled { cancel("task cancelled") }
        sceneChanged(active: active())
        if !ended && !active() { cancel("Playport is not active") }
        if let failure { throw Stopped(description: failure) }
        if ended { throw Stopped(description: "batch ended") }
    }

    func cancel(_ reason: String) {
        guard !ended else { return }
        failure = reason
        ended = true
        handingOff = false
        onCancel(reason)
    }
    func end() { ended = true; handingOff = false }

    // Stop local iteration, but keep revocation armed until process termination.
    // An observed loss during replacement must also drop the saved continuation.
    func handoff() { if !ended { handingOff = true } }

    func waitForHandoff() async throws {
        while handingOff { try await pause(.milliseconds(100)) }
        if let failure { throw Stopped(description: failure) }
    }

    func pause(_ duration: Duration) async throws {
        try checkpoint()
        // The existing wait duration is unchanged, but interruption markers must
        // also be observed during long waits, not only at their eventual return.
        var left = duration
        while left > .zero {
            let slice = min(left, .milliseconds(100))
            do { try await sleep(slice) }
            catch { cancel("task cancelled during wait"); throw error }
            try checkpoint()
            left -= slice
        }
    }

    func ready(_ condition: () -> Bool) async throws {
        let deadline = now() + 90
        while true {
            if cancelRequested() { cancel("host requested cancellation during startup") }
            if Task.isCancelled { cancel("task cancelled during startup") }
            sceneChanged(active: active())
            if let failure { throw Stopped(description: failure) }
            if active() && condition() { try checkpoint(); return }
            if now() >= deadline {
                cancel("startup readiness timed out (active app/library/opening required)")
                throw Stopped(description: failure!)
            }
            do { try await sleep(.milliseconds(100)) }
            catch { cancel("task cancelled during startup"); throw error }
        }
    }

    func presses<T>(_ values: [T], send: (T) -> Void) async throws {
        for value in values {
            try checkpoint()
            if handingOff { return }
            send(value)
            try await pause(.milliseconds(250))
        }
    }

    func step(acknowledged: () -> Bool) async throws {
        let deadline = now() + 90
        try checkpoint()
        while !acknowledged() {
            if now() >= deadline {
                cancel("step acknowledgement timed out")
                throw Stopped(description: failure!)
            }
            try await pause(.milliseconds(200))
        }
        try checkpoint()
    }

    func run(_ actions: [String], perform: (Int, String) async throws -> Void,
             acknowledge: (Int, String) -> Void, step: (Int) async throws -> Void) async throws {
        for (i, action) in actions.enumerated() {
            try checkpoint()
            if handingOff { return }
            try await perform(i, action)
            if ended && failure == nil { return }
            try checkpoint()
            if handingOff { return }
            acknowledge(i + 1, action)
            try await step(i + 1)
            try checkpoint()
        }
    }
}
