// SPDX-License-Identifier: GPL-3.0-or-later
// Gyro aim's sensors over a running game (docs/plans/2026-10-09-touch-controls.md,
// phase 2): the iPhone's or a controller's gyro into HostIOKit's GyroAim, its
// output into the guest as slot 0's right stick or relative mouse motion.
//
// GyroSensors (main thread) decides when the sensors run and which
// (PlayportKit GyroRun): only while the game's gyro output (ControlsStore: its
// own over the gyro.* defaults) is not Off and the game is drawing, in front
// and taking input. The background, focus loss, the in-game menu or a web page
// (HostIO.holdGuest), a guest dialog, the setting going Off and the game's end
// all stop them; when they start again GyroAim restarts its windows, so nothing
// from before the stop moves the aim.
//
// - The iPhone: CoreMotion's device motion at 100 Hz on GyroFeed's queue,
//   `rotationRate` and `gravity`, onto the aim frame for the interface
//   orientation (HostIOKit GyroFrame.phone), followed as the screen rotates.
//   Device motion's rotation rate, not the raw gyro: CoreMotion has already
//   taken most of the bias out (its own fusion, with the accelerometer), so
//   GyroAim's stillness calibration only trims what is left, and a slow steady
//   turn it might take for bias (under 0.05 rad/s, perfectly even) moves a
//   bias that is already near zero. Device motion asks for no permission.
// - A controller: GCController.motion with its sensors on, `rotationRate`, and
//   `gravity` when it reports it, else `acceleration` (gravity plus the hand's
//   motion; a pad that reports neither gives no gravity, and player space is
//   yaw then), onto the aim frame (GyroFrame.controller). GameController calls
//   on the main thread; each sample hops to the feed's queue, stamped then.
// - Automatic: the current controller's gyro when it reports rotation rate,
//   else the iPhone's; a controller connecting or going decides again.
// - The output (GyroFeed, on its queue): GyroAim with the pause button read
//   from slot 0 as the guest has it; a right-stick deflection into the mixer
//   under the pad lock and through the menu's gate, as every slot-0 change;
//   mouse counts coalesced to at most 125 moves a second (GyroMouseCoalescer:
//   Winios's ring holds 256 events and drops new ones when the game does not
//   drain it) and pushed to the ring, which takes them from any thread.
//
// A dev build logs `gyro:` lines: the source and output as the sensors start
// and stop, the calibration once learnt, and a summary of the output at most
// every 2 s while it moves (none while the aim is still): the samples and
// their rate, and for the mouse the moves sent, their rate and the longest a
// move waited in the coalescer.

#if canImport(UIKit)
import Combine
import CoreMotion
import Foundation
import GameController
import HostIOKit
import os
import PlayportKit
import UIKit
import WinIOS

@MainActor
final class GyroSensors {
    static let shared = GyroSensors()

    /// The iPhone's device motion rate.
    static let phoneHz = 100.0

    /// Whether the sensors run now, and which.
    private(set) var run = GyroRun.stopped("not started")
    private var settings = GyroSettings()
    private var started = false
    private var appActive = true
    private var guestHeld = false
    private var dialog = false
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var geometry: NSKeyValueObservation?
    private let motion = CMMotionManager()
    /// The controller whose motion is read while a controller's gyro runs.
    private var controller: GCController?
    nonisolated let feed = GyroFeed()

    nonisolated static func log(_ line: String) {
        #if !PLAYPORT_RELEASE
        HostIO.log("gyro: " + line)
        #endif
    }

    /// HostIO.start: follow the settings, the launch, the controllers and the screen's orientation.
    func start() {
        guard !started else { return }
        started = true
        let later = { DispatchQueue.main.async { MainActor.assumeIsolated { GyroSensors.shared.update() } } }
        // objectWillChange fires before the change: read it on the next turn.
        ControlsStore.shared.objectWillChange.sink { _ in later() }.store(in: &subscriptions)
        TitleLaunch.shared.objectWillChange.sink { _ in later() }.store(in: &subscriptions)
        let nc = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect, .GCControllerDidBecomeCurrent,
                     .GCControllerDidStopBeingCurrent] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { GyroSensors.shared.update() }
            })
        }
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            geometry = scene.observe(\.effectiveGeometry, options: [.initial, .new]) { scene, _ in
                MainActor.assumeIsolated { GyroSensors.shared.screen(scene.effectiveGeometry.interfaceOrientation) }
            }
        }
        update()
    }

    /// The app is active and in the foreground (HostIO's Lifecycle), or not.
    func appState(active: Bool) {
        guard active != appActive else { return }
        appActive = active
        update()
    }

    /// The in-game menu or a web page holds the game's input (HostIO.holdGuest), or let it go.
    func guestHeld(_ held: Bool) {
        guestHeld = held
        update()
    }

    /// A guest dialog came over the game, or the last one went (HostIO.dialogOverGame).
    func dialogOverGame(_ up: Bool) {
        dialog = up
        update()
    }

    private func screen(_ o: UIInterfaceOrientation) {
        let mapped: GyroScreenOrientation? = switch o {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: nil
        }
        guard let mapped, feed.setOrientation(mapped), run.device == .phone else { return }
        Self.log("screen \(mapped.rawValue): the iPhone's axes follow it")
    }

    /// The current controller (else the first connected) when it reports rotation rate.
    private func gyroController() -> GCController? {
        let c = GCController.current ?? GCController.controllers().first { $0.extendedGamepad != nil }
        guard let c, c.extendedGamepad != nil, c.motion?.hasRotationRate == true else { return nil }
        return c
    }

    private func update() {
        guard started else { return }
        let launch = TitleLaunch.shared
        settings = launch.titleID.map { ControlsStore.shared.gyro($0) } ?? ControlsStore.shared.gyroDefaults
        feed.configure(settings)
        let pad = gyroController()
        let next = GyroRun.decide(GyroConditions(settings: settings,
                                                 gameDrawing: launch.running && launch.step == .drawing && !launch.quitting,
                                                 appActive: appActive, guestHeld: guestHeld, dialog: dialog,
                                                 phoneHasGyro: motion.isDeviceMotionAvailable, controllerHasGyro: pad != nil))
        let samePad = next.device != .controller || pad === controller
        guard next != run || !samePad else { return }
        stopSensors(next)
        run = next
        if case .running(let d, let o) = next { startSensors(d, output: o, pad: pad) }
    }

    private func stopSensors(_ next: GyroRun) {
        guard case .running(let d, let o) = run else { return }
        switch d {
        case .phone:
            motion.stopDeviceMotionUpdates()
        case .controller:
            if let m = controller?.motion {
                m.valueChangedHandler = nil
                if m.sensorsRequireManualActivation { m.sensorsActive = false }
            }
            controller = nil
        }
        feed.stop()
        let why = if case .stopped(let r) = next { r } else { "source or output changed" }
        Self.log("stopped (\(why)); was source \(d.rawValue), output \(o.rawValue)")
    }

    private func startSensors(_ d: GyroDevice, output o: GyroOutput, pad: GCController?) {
        feed.start(d)
        switch d {
        case .phone:
            motion.deviceMotionUpdateInterval = 1 / Self.phoneHz
            feed.startPhone(motion)
            Self.log("source phone (device motion \(Int(Self.phoneHz)) Hz, \(feed.orientation.rawValue)); output \(o.rawValue); "
                     + settings.summary)
        case .controller:
            guard let pad, let m = pad.motion else { return }
            controller = pad
            if m.sensorsRequireManualActivation { m.sensorsActive = true }
            feed.startController(m)
            Self.log("source controller (\"\(pad.vendorName ?? "?")\", gravity "
                     + (m.hasGravityAndUserAcceleration ? "reported" : "from acceleration") + "); output \(o.rawValue); "
                     + settings.summary)
        }
    }
}

/// Gyro aim's processing on its own queue: the sensors' samples through GyroAim
/// into the guest. Its state is the queue's alone; `control` is what the main
/// thread sets, read with each sample.
final class GyroFeed: @unchecked Sendable {
    let dispatch = DispatchQueue(label: "hostio.gyro", qos: .userInteractive)
    /// CoreMotion's handler queue: `dispatch`.
    let queue: OperationQueue

    private struct Control: Sendable {
        /// The device whose samples are taken; nil while stopped.
        var running: GyroDevice?
        /// Each start and stop; a start whose turn on the queue comes after a later stop does nothing.
        var generation = 0
        var settings = GyroSettings()
        var orientation = GyroScreenOrientation.landscapeRight
        #if !PLAYPORT_RELEASE
        /// A dev build's `gyro:` script runs: its samples replace the sensors'.
        var scripted = false
        #endif
    }
    private let control = OSAllocatedUnfairLock(initialState: Control())

    // The queue's alone:
    private var aim = GyroAim()
    private var aimDevice: GyroDevice?
    private var coalescer = GyroMouseCoalescer()
    private var activity = GyroActivity()
    private var calibrationLogged = false

    init() {
        queue = OperationQueue()
        queue.name = "hostio.gyro"
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = dispatch
    }

    var orientation: GyroScreenOrientation { control.withLock { $0.orientation } }

    /// The screen's orientation; true when it changed.
    func setOrientation(_ o: GyroScreenOrientation) -> Bool {
        control.withLock { c in
            defer { c.orientation = o }
            return c.orientation != o
        }
    }

    func configure(_ s: GyroSettings) { control.withLock { $0.settings = s } }

    /// Take `d`'s samples: the same device's aim restarts its windows (its bias
    /// kept), another device's starts afresh.
    func start(_ d: GyroDevice) {
        let generation = control.withLock { c in
            c.generation += 1
            c.running = nil
            return c.generation
        }
        dispatch.async { [self] in
            if aimDevice == d {
                aim.restart()
            } else {
                aim = GyroAim(config: control.withLock { $0.settings }.aimConfig)
                aimDevice = d
                calibrationLogged = false
            }
            coalescer.reset()
            activity.reset()
            control.withLock { c in if c.generation == generation { c.running = d } }
        }
    }

    /// Take no more samples (at once), and take the gyro off the right stick.
    func stop() {
        control.withLock { c in
            c.generation += 1
            c.running = nil
        }
        dispatch.async { [self] in
            coalescer.reset()
            activity.reset()
            HostIO.pads.withLock { p in HostIO.apply(p.mixer.gyro(.none).slot0, slot: 0, &p.gate) }
        }
    }

    func startPhone(_ m: CMMotionManager) {
        m.startDeviceMotionUpdates(to: queue) { @Sendable [self] motion, _ in
            guard let motion else { return }
            let r = motion.rotationRate, g = motion.gravity
            take(time: motion.timestamp, rate: GyroVector(x: r.x, y: r.y, z: r.z), gravity: GyroVector(x: g.x, y: g.y, z: g.z),
                 from: .phone)
        }
    }

    /// GameController calls on the main thread; the sample hops to the queue.
    func startController(_ m: GCMotion) {
        m.valueChangedHandler = { @Sendable [self] m in
            let time = ProcessInfo.processInfo.systemUptime
            let r = m.rotationRate
            let g = m.hasGravityAndUserAcceleration ? m.gravity : m.acceleration
            let rate = GyroVector(x: r.x, y: r.y, z: r.z), gravity = GyroVector(x: g.x, y: g.y, z: g.z)
            dispatch.async { [self] in take(time: time, rate: rate, gravity: gravity, from: .controller) }
        }
    }

    /// A sensor's sample in its own frame, on the queue: taken while its device runs (and no `gyro:` script does).
    private func take(time: Double, rate: GyroVector, gravity: GyroVector, from d: GyroDevice) {
        let c = control.withLock { $0 }
        guard c.running == d else { return }
        #if !PLAYPORT_RELEASE
        if c.scripted { return }
        #endif
        let s = switch d {
        case .phone:
            GyroSample(time: time, rate: GyroFrame.phone(rate, c.orientation), gravity: GyroFrame.phone(gravity, c.orientation))
        case .controller:
            GyroSample(time: time, rate: GyroFrame.controller(rate), gravity: GyroFrame.controller(gravity))
        }
        _ = process(s, c.settings)
    }

    /// One aim-frame sample through GyroAim into the guest; GyroAim's output.
    private func process(_ s: GyroSample, _ settings: GyroSettings) -> GyroAimOutput {
        let config = settings.aimConfig
        if aim.config != config { aim.config = config }
        let (o, outputs) = HostIO.pads.withLock { p in
            let o = aim.add(s, paused: settings.paused(by: p.mixer.slot0))
            let r = p.mixer.gyro(o)
            HostIO.apply(r.slot0, slot: 0, &p.gate)
            return (o, r.outputs)
        }
        for case .move(let dx, let dy) in outputs {
            if let m = coalescer.add(dx: dx, dy: dy, time: s.time) {
                winios_pointer(m.dx, m.dy, Pointer.move, 0)
                #if !PLAYPORT_RELEASE
                activity.sent(delay: coalescer.lastDelay)
                #endif
            }
        }
        #if !PLAYPORT_RELEASE
        if aim.calibrated, !calibrationLogged {
            calibrationLogged = true
            GyroSensors.log("calibrated: " + Self.bias(aim.bias))
        }
        if let line = activity.add(o, time: s.time) { GyroSensors.log(line + "; " + Self.bias(aim.bias)) }
        #endif
        return o
    }

    private static func bias(_ b: GyroVector) -> String { String(format: "bias %.4f %.4f %.4f rad/s", b.x, b.y, b.z) }

    #if !PLAYPORT_RELEASE
    // A dev build's `gyro:` script (Dev/GyroDriver.swift): its samples enter
    // where the sensors' do, and replace them while it plays.

    /// What a script's samples did.
    struct ScriptResult: Sendable {
        var samples = 0
        /// Taken: the sensors were running (else the sample moved nothing, as a sensor's would not).
        var taken = 0
        var dx = 0, dy = 0
        var peak = 0.0
    }

    private struct Playing {
        var samples: [GyroSample]
        var next = 0
        var result = ScriptResult()
        var timer: DispatchSourceTimer
        var done: CheckedContinuation<ScriptResult, Never>
    }
    /// The queue's alone.
    private var playing: Playing?

    /// Plays `script` from now, each sample at its time, on the queue; returns once the last is fed.
    func play(_ script: GyroScript) async -> ScriptResult {
        await withCheckedContinuation { done in
            dispatch.async { [self] in
                control.withLock { $0.scripted = true }
                let timer = DispatchSource.makeTimerSource(queue: dispatch)
                playing = Playing(samples: script.samples(from: ProcessInfo.processInfo.systemUptime), timer: timer, done: done)
                timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .milliseconds(1))
                timer.setEventHandler { [self] in scriptTick() }
                timer.resume()
            }
        }
    }

    private func scriptTick() {
        guard var p = playing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        while p.next < p.samples.count, p.samples[p.next].time <= now {
            let s = p.samples[p.next]
            p.next += 1
            p.result.samples += 1
            let c = control.withLock { $0 }
            guard c.running != nil else { continue }
            p.result.taken += 1
            switch process(s, c.settings) {
            case .none: break
            case .mouse(let dx, let dy): p.result.dx += Int(dx); p.result.dy += Int(dy)
            case .rightStick(let x, let y): p.result.peak = max(p.result.peak, (x * x + y * y).squareRoot())
            }
        }
        guard p.next == p.samples.count else { playing = p; return }
        p.timer.cancel()
        playing = nil
        control.withLock { $0.scripted = false }
        p.done.resume(returning: p.result)
    }
    #endif
}
#endif
