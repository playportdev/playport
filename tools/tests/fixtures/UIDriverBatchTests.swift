// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Only the continuation's filesystem/log dependencies are stubbed, not its save/drop code.
enum WineHostRuntime {
    static let documents = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DRIVER_TEST_DIR"]!)
    static func appendLog(_ text: String) {}
}

@main
struct UIDriverBatchTests {
    @MainActor static func main() async {
        var failures: [String] = []
        func check(_ value: Bool, _ name: String) { if !value { failures.append(name) } }
        // Virtual monotonic clock: no device and no real delays.
        var active = false, ticks = 0.0
        var wake: () -> Void = {}
        func make() -> UIDriverBatch {
            UIDriverBatch(active: { active }, now: { ticks }, sleep: { _ in
                ticks += 1
                wake()
                if ticks > 200 { throw CancellationError() }
            })
        }
        var batch = make()
        wake = { active = true; batch.sceneChanged(active: true) }
        do { try await batch.ready { true } } catch { failures.append("initial activation readiness") }
        check(batch.failure == nil && active, "initial inactive must not cancel")
        active = false
        batch = make(); ticks = 0
        do { try batch.checkpoint(); failures.append("action requires active") } catch {}
        // Initial readiness has a bounded wait, not a session duration cap.
        batch = make(); ticks = 0; wake = { if ticks > 121 { active = true } }
        do { try await batch.ready { true }; failures.append("readiness timeout") } catch {}
        check(batch.failure != nil, "readiness timeout is terminal")
        active = true; ticks = 0; batch = make(); batch.sceneChanged(active: true)
        wake = { active = false; batch.sceneChanged(active: false); active = true; batch.sceneChanged(active: true) }
        do { try await batch.ready { false }; failures.append("loss during readiness") } catch {}
        check(batch.failure != nil, "readiness loss stays cancelled after activation")
        let nonce = "ab12cd34"
        var markers = ["ui-cancel-old": "old", "ui-cancel-\(nonce)": "other"]
        check(!UIDriverBatch.cancellationRequested(nonce: nonce, read: { markers[$0] }), "stale/other nonce ignored")
        check(!UIDriverBatch.cancellationRequested(nonce: "../bad", read: { _ in "../bad" }), "invalid nonce ignored")
        markers["ui-cancel-\(nonce)"] = nonce
        check(UIDriverBatch.cancellationRequested(nonce: nonce, read: { markers[$0] }), "current nonce accepted")
        active = false; batch = make()
        batch.cancelRequested = { true }
        do { try await batch.ready { true }; failures.append("startup marker ignored") } catch {}
        for loss in ["before-action", "during-action", "before-step", "during-step", "mid-press", "cancel", "host-cancel", "sleep-cancel"] {
            active = true; ticks = 0; batch = make(); batch.sceneChanged(active: true)
            var actions: [String] = [], presses: [String] = [], acks: [Int] = [], cancels = 0
            batch.onCancel = { _ in cancels += 1 }
            if loss == "before-action" { active = false; batch.sceneChanged(active: false) }
            wake = {
                if loss == "cancel" { batch.cancel("owner stop") }
                else if loss == "host-cancel" { batch.cancelRequested = { true } }
                else if loss == "sleep-cancel" { /* the sleep throws below */ }
                else { active = false; batch.sceneChanged(active: false) }
                // Losing foreground is permanent, even if active before the await returns.
                active = true; batch.sceneChanged(active: true)
            }
            if loss == "sleep-cancel" { batch.sleep = { _ in ticks += 1; throw CancellationError() } }
            do {
                try await batch.run(["one", "two"], perform: { _, action in
                    actions.append(action)
                    if loss == "mid-press" {
                        try await batch.presses(["a", "down", "a"]) { presses.append($0) }
                    } else if !["before-step", "during-step"].contains(loss) { try await batch.pause(.seconds(1)) }
                }, acknowledge: { n, _ in
                    acks.append(n)
                    if loss == "before-step" { wake() }
                }, step: { _ in
                    try await batch.step { loss == "before-step" }
                })
                failures.append("\(loss) did not throw")
            } catch {}
            check(!actions.contains("two"), "\(loss) queued next action")
            check(acks == (["before-step", "during-step"].contains(loss) ? [1] : []), "\(loss) acknowledged after cancellation")
            check(presses == (loss == "mid-press" ? ["a"] : []), "\(loss) sent another press")
            check(cancels == 1 && batch.failure != nil, "\(loss) one terminal cancellation")
            do { try batch.checkpoint(); failures.append("\(loss) resumed") } catch {}
        }
        active = true; ticks = 0; batch = make(); batch.sceneChanged(active: true); wake = {}
        var actions: [String] = [], acks: [Int] = [], presses: [String] = []
        do {
            try await batch.run(["one", "two"], perform: { _, action in
                actions.append(action)
                try await batch.presses(["a", "b"]) { presses.append($0) }
            }, acknowledge: { n, _ in acks.append(n) }, step: { _ in try await batch.step { true } })
        } catch { failures.append("normal active batch: \(error)") }
        check(actions == ["one", "two"] && acks == [1, 2] && presses == ["a", "b", "a", "b"], "normal batch")
        batch = make(); ticks = 0
        do { try await batch.step { false }; failures.append("missing ack did not fail") } catch {}
        check(batch.failure != nil, "step timeout is terminal")
        // Real Task cancellation must be observed even if a foreign await returns normally.
        let cancelledTask = Task { @MainActor () -> Bool in
            let queue = UIDriverBatch(active: { true })
            withUnsafeCurrentTask { $0?.cancel() }
            do { try queue.checkpoint(); return false } catch { return queue.failure != nil }
        }
        check(await cancelledTask.value, "real task cancellation")
        // A completed/refused action terminates without acknowledging or running its successor.
        batch = make(); actions = []; acks = []
        do {
            try await batch.run(["refused", "later"], perform: { _, action in
                actions.append(action); batch.end()
            }, acknowledge: { n, _ in acks.append(n) }, step: { _ in })
        } catch { failures.append("explicit end") }
        check(actions == ["refused"] && acks.isEmpty, "explicit end drops queue")
        // Real DriverContinuation save/drop, with a simulated process-replacement window.
        let continuation = WineHostRuntime.documents.appendingPathComponent("ui-continue.json")
        for loss in ["none", "inactive", "host-cancel"] {
            active = true; ticks = 0; batch = make(); batch.sceneChanged(active: true)
            actions = []; acks = []; presses = []
            batch.onCancel = { _ in DriverContinuation.drop() }
            wake = {}
            do {
                try await batch.run(["restart", "later"], perform: { _, action in
                    actions.append(action)
                    DriverContinuation.save(remaining: ["open:home"], continuesPlay: false)
                    batch.handoff()
                }, acknowledge: { n, _ in acks.append(n) }, step: { _ in })
                check(FileManager.default.fileExists(atPath: continuation.path), "\(loss) continuation saved")
                check(batch.handingOff && !batch.ended && actions == ["restart"] && acks.isEmpty,
                      "\(loss) handoff stops iteration but stays armed")
                do { try await batch.presses(["a"]) { presses.append($0) } }
                catch { failures.append("\(loss) revocation disarmed before replacement") }
                check(presses.isEmpty, "no presses during replacement")
                if loss == "none" {
                    try batch.checkpoint()
                    check(batch.failure == nil, "ordinary replacement without observed loss")
                } else {
                    if loss == "inactive" { active = false; batch.sceneChanged(active: false) }
                    else { batch.cancelRequested = { true } }
                    active = true; batch.sceneChanged(active: true)
                    do { try await batch.waitForHandoff(); failures.append("\(loss) handoff did not throw") } catch {}
                    check(!FileManager.default.fileExists(atPath: continuation.path), "\(loss) continuation dropped")
                    do { try batch.checkpoint(); failures.append("\(loss) handoff revived") } catch {}
                }
            } catch { failures.append("\(loss) save/handoff: \(error)") }
            DriverContinuation.drop()
        }
        if !failures.isEmpty {
            for failure in failures { print("FAIL: \(failure)") }
            exit(1)
        }
        print("UIDriverBatch: readiness, action/press/step gates, terminal loss/cancel, timeout and normal queue pass")
    }
}
