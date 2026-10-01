// SPDX-License-Identifier: GPL-3.0-or-later
// Host I/O for a title (docs/ARCHITECTURE.md, HostIO):
// the four app pieces a running game needs, wired to UIKit, GameController and
// AVFAudio. The decisions live in HostIOKit, which is tested on the Linux host;
// this file only moves events between the system and the runtime.
//
//   presentation  GameSurfaceView's CAMetalLayer, handed to IOSDisplayShim
//                 (madeira_display_set_layer), which DXMT's swap chain finds
//                 through macdrv_functions
//   audio         AVAudioSession (playback) for the RemoteIO driver in
//                 libntdll_unix.a; interruptions and the background stop its
//                 units (ios_audio_host_suspend)
//   input         touches, hardware keys and a mouse into Winios's input ring;
//                 game controllers into Madeira's controller snapshot, which
//                 Wine's xinput1_*.dll reads through win32u
//   in-game menu  the controller's Home button held opens Playport's menu
//                 (UI/InGameMenuView.swift, HostIOKit.QuickMenuControl); while
//                 it is up the pads' presses are the menu's, the guest's pads
//                 are at rest (HostIOKit.GuestPadGate), audio stops and the
//                 session root holds the game's threads (pauseGame)
//   lifecycle     focus loss before releasing held controls (pads by Winios's
//                 drain, after the loss reaches the game), audio back when
//                 active, foreground and uninterrupted, and DXMT's Metal
//                 commits held while the app is in the background
//                 (winemetal_host_gpu_gate) (HostIOKit.Lifecycle)
//
// A title launch turns this on (TitleLaunch). Every handler runs on the main thread and does only cheap
// work there: ring pushes and atomic stores. Audio-session calls go to a
// serial queue.
//
// A release build logs only the audio session, the GPU gate and the
// accessories that connect and disconnect (decision 0009). What a dev build's
// s1-host.log also shows (after the 2026-09-23 session, which could not tell
// where the mouse and pad chains stopped): each GameController notification as
// it is posted, on the posting thread, and again when the main thread handles
// it; once a second, the mouse handler calls against the pixels pushed into
// Winios's ring and each pad's last values (HostIOKit.InputTrace); every pad
// button or trigger change as it is written to the block; and the main queue
// going quiet for more than 2 s, since every GameController handler waits on it.

#if canImport(UIKit)
import AVFAudio
import Foundation
import GameController
import HostIO
import HostIOKit
import os
import Metal
import QuartzCore
import SwiftUI
import UIKit
import WineHost
import WinIOS

@MainActor
final class HostIO {
    static let shared = HostIO()

    /// Signalled once the surface's layer is registered; the launch thread
    /// waits on it so DXMT never looks for a layer that does not exist yet.
    nonisolated static let surfaceReady = DispatchSemaphore(value: 0)

    private var lifecycle = Lifecycle()
    private var slots = PadSlots<ObjectIdentifier>()
    private var motion = RelativeMotion()
    /// The Home button and the in-game menu's presses, from every pad.
    private var menuControl = QuickMenuControl()
    private var menuClock: Timer?
    /// The in-game menu is up: keys, touches and the mouse do not reach the guest.
    private(set) var menuUp = false
    /// The game layer, once registered: the menu's performance overlay switches its HUD.
    weak var gameLayer: CAMetalLayer?
    /// What the guest's pads get (HostIOKit.GuestPadGate), from the main thread
    /// and the scripted pad's queue; host_pad_set is called under it, so a
    /// stale value never overtakes the rest the menu put there.
    nonisolated static let gate = OSAllocatedUnfairLock(initialState: GuestPadGate())
    /// The in-game menu's controls to the session root, in order (pauseGame).
    private nonisolated static let sessionQueue = DispatchQueue(label: "hostio.session", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private nonisolated static let audioQueue = DispatchQueue(label: "hostio.audio", qos: .userInitiated)
    nonisolated static let trace = TraceBox()

    /// One line into the app log (AppLog), from any thread, through host_log.c,
    /// which writes it the way Winios does once the runtime owns stderr (host_log.c).
    nonisolated static func log(_ line: String) {
        host_log(AppLog.path, line)
    }

    /// Before wine_host_init, off the main thread: an active audio session for
    /// the RemoteIO driver. start() has already set the guest's environment.
    nonisolated static func prepareRuntime(log: (String) -> Void) {
        let env = ProcessInfo.processInfo.environment
        log("hostio: WINEDLLOVERRIDES=\(env["WINEDLLOVERRIDES"] ?? "unset")")
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            log("hostio: audio session active, \(Int(session.sampleRate)) Hz, output latency \(Int(session.outputLatency * 1000)) ms")
        } catch {
            log("hostio: audio session: \(error)")
        }
    }

    /// On the main thread, before the runtime thread starts: the environment the
    /// guest inherits, then the observers.
    func start() {
        guard !started else { return }
        started = true
        // windows.gaming.input is disabled: with no winebus it lists no pad, and
        // Unity picks it over XInput when it loads, so the game never sees the
        // pad; without it Unity falls back to XInput (Wine's builtin, which
        // reads the controller snapshot host_pad_set writes).
        setenv("WINEDLLOVERRIDES", "windows.gaming.input=d", 0)
        let nc = NotificationCenter.default
        let app: [(Notification.Name, LifecycleEvent)] = [
            (UIApplication.willResignActiveNotification, .resignActive),
            (UIApplication.didBecomeActiveNotification, .becomeActive),
            (UIApplication.didEnterBackgroundNotification, .enterBackground),
            (UIApplication.willEnterForegroundNotification, .enterForeground),
            (AVAudioSession.mediaServicesWereResetNotification, .mediaServicesReset),
        ]
        for (name, event) in app {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { HostIO.shared.handle(event) }
            })
        }
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            MainActor.assumeIsolated { HostIO.shared.handle(began ? .interruptionBegan : .interruptionEnded) }
        })
        #if !PLAYPORT_RELEASE
        // On the posting thread, before any hop to the main queue: shows whether
        // GameController posted at all when the main-queue handler never runs.
        let posted: [Notification.Name] = [.GCControllerDidConnect, .GCControllerDidDisconnect, .GCControllerDidBecomeCurrent,
                                           .GCMouseDidConnect, .GCMouseDidDisconnect, .GCMouseDidBecomeCurrent]
        for name in posted {
            observers.append(nc.addObserver(forName: name, object: nil, queue: nil) { note in
                HostIO.log("hostio: posted \(note.name.rawValue) (on the main thread: \(Thread.isMainThread))")
            })
        }
        #endif
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
            nonisolated(unsafe) let c = note.object as? GCController   // delivered on .main, used there
            MainActor.assumeIsolated { if let c { HostIO.shared.attach(controller: c) } }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { note in
            nonisolated(unsafe) let c = note.object as? GCController   // delivered on .main, used there
            MainActor.assumeIsolated { if let c { HostIO.shared.detach(controller: c) } }
        })
        observers.append(nc.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { note in
            nonisolated(unsafe) let m = note.object as? GCMouse   // delivered on .main, used there
            MainActor.assumeIsolated { if let m { HostIO.shared.attach(mouse: m) } }
        })
        observers.append(nc.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { note in
            nonisolated(unsafe) let m = note.object as? GCMouse   // delivered on .main, used there
            MainActor.assumeIsolated { HostIO.log("hostio: mouse disconnected \"\(m?.vendorName ?? "?")\"") }
        })
        // GameController sends a mouse's motion to the handlers of the current
        // mouse, and a handler set before the mouse became current may not be
        // the one it calls, so they are set again each time one does.
        observers.append(nc.addObserver(forName: .GCMouseDidBecomeCurrent, object: nil, queue: .main) { note in
            nonisolated(unsafe) let m = note.object as? GCMouse   // delivered on .main, used there
            MainActor.assumeIsolated { if let m { HostIO.shared.install(mouse: m, reason: "current") } }
        })
        observers.append(nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { note in
            nonisolated(unsafe) let k = note.object as? GCKeyboard   // delivered on .main, used there
            MainActor.assumeIsolated { HostIO.log("hostio: keyboard connected \"\(k?.vendorName ?? "?")\"") }
        })
        observers.append(nc.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
            HostIO.log("hostio: keyboard disconnected")
        })
        if let k = GCKeyboard.coalesced { HostIO.log("hostio: keyboard connected \"\(k.vendorName ?? "?")\"") }
        GCController.controllers().forEach(attach(controller:))
        GCMouse.mice().forEach(attach(mouse:))
        #if !PLAYPORT_RELEASE
        startVirtualPad()
        Self.trace.start()
        #endif
    }

    #if !PLAYPORT_RELEASE
    /// A pad slot for something other than a GameController pad (Dev/VirtualPad.swift).
    func connectSlot(_ id: ObjectIdentifier) -> Int? { slots.connect(id) }
    #endif

    // MARK: lifecycle

    private func handle(_ event: LifecycleEvent) {
        let actions = lifecycle.handle(event)
        if event == .resignActive { motion.reset() }
        for a in actions {
            switch a {
            case .focus(let active):
                winios_post_focus(active ? 1 : 0)
            case .releaseKeys(let vks):
                for vk in vks { winios_post_key(Int32(vk), 0) }
            case .releaseButtons(let flags):
                for f in flags { winios_pointer(0, 0, f, 0) }
            case .suspendAudio(let deactivate):
                Self.audioQueue.async {
                    _ = ios_audio_host_suspend(1)
                    if deactivate { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
                }
            case .resumeAudio:
                Self.audioQueue.async {
                    do { try AVAudioSession.sharedInstance().setActive(true) } catch { NSLog("hostio: setActive(true): \(error)") }
                    _ = ios_audio_host_suspend(0)
                }
            case .gpu(let open):
                // Here, not on a queue: iOS refuses the commits that come after
                // the didEnterBackground handler returns, so the gate must be shut
                // (and what is committed scheduled) before it does.
                let t0 = DispatchTime.now().uptimeNanoseconds
                let unscheduled = winemetal_host_gpu_gate(open ? 1 : 0)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                HostIO.log("hostio: gpu gate \(open ? "opened" : "closed") in \(String(format: "%.2f", ms)) ms "
                           + "on the main thread (\(unscheduled) unscheduled)")
            }
        }
    }

    // MARK: keyboard and pointer (from GameSurfaceView)

    func key(hidUsage: Int, down: Bool) -> Bool {
        guard let vk = KeyMap.virtualKey(hidUsage: hidUsage) else { return false }
        if down && menuUp { return true }   // a key let go while the menu is up still reaches the game
        if down ? lifecycle.keyDown(vk) : lifecycle.keyUp(vk) { winios_post_key(Int32(vk), down ? 1 : 0) }
        return true
    }

    /// A direct touch as the left button, at the same point of the client area.
    func touch(at p: CGPoint, in size: CGSize, phase: UITouch.Phase) {
        let x = min(max(p.x, 0), size.width - 0.001), y = min(max(p.y, 0), size.height - 0.001)
        guard let f = Pointer.clientFraction(x: x, y: y, width: size.width, height: size.height) else { return }
        if menuUp && phase != .ended && phase != .cancelled { return }
        switch phase {
        case .began:
            if lifecycle.buttonDown(upFlag: Pointer.leftUp) { winios_post_client_pointer(f.0, f.1, Pointer.move | Pointer.leftDown, 0) }
        case .moved:
            winios_post_client_pointer(f.0, f.1, Pointer.move, 0)
        case .ended, .cancelled:
            if lifecycle.buttonUp(upFlag: Pointer.leftUp) { winios_post_client_pointer(f.0, f.1, Pointer.move | Pointer.leftUp, 0) }
        default:
            break
        }
    }

    private func attach(mouse: GCMouse) {
        HostIO.log("hostio: mouse connected \"\(mouse.vendorName ?? "?")\"")
        install(mouse: mouse, reason: "connected")
    }

    private func install(mouse: GCMouse, reason: String) {
        guard let input = mouse.mouseInput else {
            HostIO.log("hostio: mouse \"\(mouse.vendorName ?? "?")\" has no mouseInput; no handlers")
            return
        }
        HostIO.log("hostio: mouse handlers set on \"\(mouse.vendorName ?? "?")\" (\(reason))")
        // GameController's +y is up; Windows' is down.
        input.mouseMovedHandler = { _, dx, dy in
            MainActor.assumeIsolated {
                guard !HostIO.shared.menuUp else { return }
                let d = HostIO.shared.motion.add(dx: Double(dx), dy: Double(-dy))
                HostIO.trace.update { $0.mouseMoved(dx: Double(dx), dy: Double(-dy), pushed: d) }
                if let d { winios_pointer(d.0, d.1, Pointer.move, 0) }
            }
        }
        let buttons: [(GCControllerButtonInput?, UInt32, UInt32)] = [
            (input.leftButton, Pointer.leftDown, Pointer.leftUp),
            (input.rightButton, Pointer.rightDown, Pointer.rightUp),
            (input.middleButton, Pointer.middleDown, Pointer.middleUp),
        ]
        for (button, downFlag, upFlag) in buttons {
            button?.pressedChangedHandler = { _, _, pressed in
                MainActor.assumeIsolated { HostIO.shared.mouseButton(down: pressed, downFlag: downFlag, upFlag: upFlag) }
            }
        }
        input.scroll.yAxis.valueChangedHandler = { _, value in
            guard value != 0 else { return }
            MainActor.assumeIsolated {
                HostIO.trace.update { $0.wheel += 1 }
                winios_pointer(0, 0, Pointer.wheel, UInt32(bitPattern: Int32((value * 120).rounded())))
            }
        }
    }

    private func mouseButton(down: Bool, downFlag: UInt32, upFlag: UInt32) {
        if down && menuUp { return }
        if down ? lifecycle.buttonDown(upFlag: upFlag) : lifecycle.buttonUp(upFlag: upFlag) {
            HostIO.trace.update { $0.mouseButtons += 1 }
            winios_pointer(0, 0, down ? downFlag : upFlag, 0)
        }
    }

    // MARK: game controllers

    private func attach(controller c: GCController) {
        // The log names each accessory the app saw.
        HostIO.log("hostio: controller connected \"\(c.vendorName ?? "?")\" category \"\(c.productCategory)\" extended=\(c.extendedGamepad != nil)")
        guard let pad = c.extendedGamepad, let slot = slots.connect(ObjectIdentifier(c)) else { return }
        HostIO.log("hostio: controller \"\(c.vendorName ?? "?")\" is XInput slot \(slot)")
        pad.valueChangedHandler = { gp, _ in
            MainActor.assumeIsolated { HostIO.shared.padChanged(gp, slot: slot) }
        }
        // Home is Playport's: held, it opens the in-game menu (the system's own use of it is off while a game runs).
        if let home = pad.buttonHome {
            home.preferredSystemGestureState = .disabled
            home.pressedChangedHandler = { [weak pad] _, _, _ in
                MainActor.assumeIsolated { if let pad { HostIO.shared.padChanged(pad, slot: slot) } }
            }
        }
        padChanged(pad, slot: slot)
    }

    /// Every pad the guest's again, after the app's screens had them
    /// (UI/Pad/PadRouter.swift): a launch after one refused before the runtime.
    func attachPads() { GCController.controllers().forEach(attach(controller:)) }

    private func detach(controller c: GCController) {
        HostIO.log("hostio: controller disconnected \"\(c.vendorName ?? "?")\"")
        guard let slot = slots.disconnect(ObjectIdentifier(c)) else { return }
        HostIO.trace.update { $0.pads[slot] = nil }
        Self.gate.withLock { $0.disconnect(slot: slot) }
        host_pad_disconnect(Int32(slot))
    }

    private func padChanged(_ gp: GCExtendedGamepad, slot: Int) {
        let input = PadInput(gp)   // UI/Pad/PadRouter.swift
        menuInput(input)
        Self.publish(PadMapping.values(input), slot: slot)
    }

    /// A pad's values toward the guest's slot, through the menu's gate.
    /// `changesOnly`: the trace counts only a change (the scripted pad, which sends every 8 ms).
    nonisolated static func publish(_ v: PadValues, slot: Int, changesOnly: Bool = false) {
        gate.withLock { g in
            guard let out = g.input(slot: slot, v) else { return }
            set(slot, out)
        }
        #if !PLAYPORT_RELEASE
        if let line = trace.update({ changesOnly && $0.pads[slot] == v ? nil : $0.pad(slot: slot, v) }) { log(line) }
        #endif
    }

    private nonisolated static func set(_ slot: Int, _ v: PadValues) {
        var st = hio_pad_state(buttons: v.buttons, left_trigger: v.leftTrigger, right_trigger: v.rightTrigger,
                              thumb_lx: v.lx, thumb_ly: v.ly, thumb_rx: v.rx, thumb_ry: v.ry)
        host_pad_set(Int32(slot), &st)
    }

    // MARK: the in-game menu (UI/InGameMenuView.swift)

    /// A pad's snapshot as the menu reads it: from a GameController pad, the
    /// scripted pad (Dev/VirtualPad.swift) and a dev build's driver (`menu:open`).
    func menuInput(_ p: PadInput) {
        menuEvents(menuControl.update(p, at: ProcessInfo.processInfo.systemUptime))
    }

    private func menuEvents(_ events: [QuickMenuEvent]) {
        for e in events {
            switch e {
            case .open:
                if !InGameMenu.shared.open() { menuControl.closed() }
            case .close:
                InGameMenu.shared.resume()
            case .press(let b):
                InGameMenu.shared.press(b)
            }
        }
        if menuControl.needsClock, menuClock == nil {
            menuClock = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
                MainActor.assumeIsolated { HostIO.shared.menuTick() }
            }
        } else if !menuControl.needsClock {
            menuClock?.invalidate()
            menuClock = nil
        }
    }

    private func menuTick() {
        menuEvents(menuControl.tick(at: ProcessInfo.processInfo.systemUptime))
    }

    /// The menu is up: the guest's pads at rest, no keys or pointer, no audio.
    func holdGuest() {
        guard !menuUp else { return }
        menuUp = true
        Self.gate.withLock { g in for s in g.hold() { Self.set(s, PadValues()) } }
        handle(.menuOpened)
    }

    /// The menu closed: the pads the guest's again, but not the buttons still
    /// down from the menu (GuestPadGate), and audio back when nothing else holds it.
    func releaseGuest() {
        menuControl.closed()
        menuEvents([])
        guard menuUp else { return }
        menuUp = false
        Self.gate.withLock { g in for (s, v) in g.release() { Self.set(s, v) } }
        handle(.menuClosed)
    }

    /// One of the in-game menu's controls to the session root
    /// (wine_host_session_control), in order on a queue of its own; `then` runs
    /// on the main thread with its result and count.
    nonisolated static func sessionControl(_ kind: Int, _ name: String, wait: UInt32 = 0,
                                           then: (@MainActor @Sendable (Int32, UInt32) -> Void)? = nil) {
        sessionQueue.async {
            let t0 = DispatchTime.now().uptimeNanoseconds
            var n: UInt32 = 0
            let rc = wine_host_session_control(Int32(kind), wait, 5_000, &n)
            let ms = (DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            log("menu: \(name) -> \(rc), \(n) \(kind == PP_CONTROL_CLOSE ? "windows" : "threads") in \(ms) ms")
            if let then { DispatchQueue.main.async { MainActor.assumeIsolated { then(rc, n) } } }
        }
    }
}

/// HostIO's InputTrace behind a lock (the handlers write it on the main thread,
/// the once-a-second summary reads it on a background queue), and the main-queue
/// watch: GameController calls every handler on the main queue, so a main
/// queue that stops running looks exactly like a mouse or pad that sends nothing.
final class TraceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var trace = InputTrace(), logged = InputTrace()
    private var mainSeen = DispatchTime.now().uptimeNanoseconds
    private var mainQuiet = false
    private var ticks = 0

    func update<R>(_ body: (inout InputTrace) -> R) -> R { lock.withLock { body(&trace) } }

    /// On the main run loop: the main thread is the one thread whose HostIO
    /// work is known to run once the runtime is up (host_log.c).
    func start() {
        let t = Timer(timeInterval: 1, repeats: true) { [self] _ in tick() }
        RunLoop.main.add(t, forMode: .common)
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let (line, quiet): (String?, Double?) = lock.withLock {
            let line = trace.summary(since: logged)
            logged = trace
            let silent = Double(now - mainSeen) / 1e9
            guard silent > 2, !mainQuiet else { return (line, nil) }
            mainQuiet = true
            return (line, silent)
        }
        if let line { HostIO.log(line) }
        // After wine_host_init: shows that HostIO's lines still reach the log with no input at all.
        let n = lock.withLock { ticks += 1; return ticks }
        if n == 15 || n == 60 { HostIO.log("hostio: log alive at \(n) s") }
        if let quiet { HostIO.log("hostio: main queue has not run for \(Int(quiet)) s; GameController handlers and notifications wait on it") }
        DispatchQueue.main.async { [self] in
            let back: Double? = lock.withLock {
                let now = DispatchTime.now().uptimeNanoseconds, was = mainQuiet ? Double(now - mainSeen) / 1e9 : nil
                mainSeen = now
                mainQuiet = false
                return was
            }
            if let back { HostIO.log("hostio: main queue ran again after \(Int(back)) s") }
        }
    }
}

/// Apple's Metal performance HUD over a game, from Settings. Metal loads the
/// HUD only when MTL_HUD_ENABLED=1 is in the environment as the process
/// starts, so the app always sets it then (PlayportApp); each game layer then
/// shows or hides it from the setting as it is at that launch. A dev build
/// that starts with the setting on also has Metal log the HUD's figures once a
/// second (MTL_HUD_LOG_ENABLED; `pp perf` reads them). A process launched
/// with its own MTL_HUD_ENABLED keeps what that says.
enum MetalHUD {
    static let key = "metalHUD"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    private static let inherited = ProcessInfo.processInfo.environment["MTL_HUD_ENABLED"] != nil

    /// Before anything creates a Metal device.
    static func loadAtStart() {
        if !inherited { setenv("MTL_HUD_ENABLED", "1", 1) }
        #if !PLAYPORT_RELEASE
        if !inherited, enabled { setenv("MTL_HUD_LOG_ENABLED", "1", 1) }
        #endif
    }

    static func show(on layer: CAMetalLayer) {
        guard !inherited else { return HostIO.log("hostio: Metal HUD from the launch environment") }
        set(enabled, on: layer)
    }

    /// The HUD on the game layer now (the in-game menu's performance overlay),
    /// for this game only: the setting stays as Settings has it.
    static func set(_ on: Bool, on layer: CAMetalLayer) {
        layer.developerHUDProperties = ["mode": on ? "default" : "off"]
        HostIO.log("hostio: Metal HUD " + (on ? "on" : "off"))
    }
}

/// The game layer: a CAMetalLayer whose nextDrawable, the call DXMT makes on
/// its encode thread for every frame, is held so frames start at most at the
/// player's frame rate limit (LaunchSettings; FramePacer). With no limit it
/// passes straight through, and presents run free (TitleScreen.swift). It
/// keeps the texture of the frame on screen (the last drawable presented),
/// which the in-game menu's Screenshot reads: DXMT's layer is not
/// framebuffer-only, and the game is paused behind the menu, so that texture
/// is what the player sees.
final class PacedMetalLayer: CAMetalLayer {
    private static let pacer = OSAllocatedUnfairLock(initialState: FramePacer(fps: 0))
    private static let shown = OSAllocatedUnfairLock<(any MTLTexture)?>(uncheckedState: nil)

    /// The frame on screen, nil before the first.
    static var lastPresented: (any MTLTexture)? { shown.withLockUnchecked { $0 } }

    private static let firstFrame = OSAllocatedUnfairLock<(() -> Void)?>(uncheckedState: nil)

    /// 0 for none. Set before the runtime starts; read on the encode thread.
    static func limit(fps: Int) { pacer.withLock { $0 = FramePacer(fps: fps) } }

    /// Runs `then` once, on the encode thread, when the game next asks for a
    /// drawable: its first frame (LaunchCoordinator's `first frame` mark).
    static func onFirstFrame(_ then: @escaping () -> Void) { firstFrame.withLockUnchecked { $0 = then } }

    override func nextDrawable() -> (any CAMetalDrawable)? {
        let wait = Self.pacer.withLock { $0.delay(now: CACurrentMediaTime()) }
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        let drawable = super.nextDrawable()
        drawable?.addPresentedHandler { d in
            guard let t = (d as? CAMetalDrawable)?.texture else { return }
            Self.shown.withLockUnchecked { $0 = t }
        }
        if let then = Self.firstFrame.withLockUnchecked({ h in defer { h = nil }; return h }) { then() }
        return drawable
    }
}

/// The full-screen view DXMT presents into: its backing layer is a
/// PacedMetalLayer, registered with IOSDisplayShim when the view reaches a window.
/// The swap chain is aspect-fitted, black around it, and touches map into
/// the fitted picture.
final class GameSurfaceView: UIView {
    override class var layerClass: AnyClass { PacedMetalLayer.self }
    override var canBecomeFirstResponder: Bool { true }
    private var registered = false

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        layer.contentsGravity = .resizeAspect
        isMultipleTouchEnabled = false
        // Counted only (hostio: input … hover=N): whether iOS shows a mouse to
        // UIKit as a hovering pointer when GCMouse's handlers stay silent.
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        HostIO.trace.update { $0.hover += 1 }
    }

    required init?(coder: NSCoder) { fatalError("GameSurfaceView is created in code") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else { return }
        // UIKit does not automatically give a custom CAMetalLayer-backed view
        // the screen's pixel scale. Vulkan WSI measures bounds * contentsScale;
        // leaving it at 1 makes a native-pixel swapchain permanently suboptimal
        // (912x420 points versus 2736x1260 pixels on a 3x screen).
        contentScaleFactor = window.screen.nativeScale
        // Landscape before the runtime starts, so the swap chain is made at the final size.
        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        window.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        if !registered, let layer = layer as? CAMetalLayer {
            registered = true
            HostIO.shared.gameLayer = layer
            MetalHUD.show(on: layer)
            madeira_display_set_layer(layer)
            HostIO.surfaceReady.signal()
        }
        becomeFirstResponder()   // hardware keys come here
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches) }

    /// Finger touches only: a connected mouse arrives through GCMouse, and its
    /// indirect-pointer touches would click twice.
    private func forward(_ touches: Set<UITouch>) {
        let indirect = touches.filter { $0.type != .direct }.count
        HostIO.trace.update { $0.touches += touches.count - indirect; $0.pointerTouches += indirect }
        var origin = CGPoint.zero, size = bounds.size
        if let d = (layer as? CAMetalLayer)?.drawableSize {
            let r = Display.aspectFit(contentWidth: d.width, contentHeight: d.height, width: size.width, height: size.height)
            origin = CGPoint(x: r.0, y: r.1)
            size = CGSize(width: r.2, height: r.3)
        }
        for t in touches where t.type == .direct {
            let p = t.location(in: self)
            HostIO.shared.touch(at: CGPoint(x: p.x - origin.x, y: p.y - origin.y), in: size, phase: t.phase)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { p in !(p.key.map { HostIO.shared.key(hidUsage: $0.keyCode.rawValue, down: true) } ?? false) }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) { release(presses, event, cancelled: false) }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { release(presses, event, cancelled: true) }

    private func release(_ presses: Set<UIPress>, _ event: UIPressesEvent?, cancelled: Bool) {
        let rest = presses.filter { p in !(p.key.map { HostIO.shared.key(hidUsage: $0.keyCode.rawValue, down: false) } ?? false) }
        guard !rest.isEmpty else { return }
        if cancelled { super.pressesCancelled(rest, with: event) } else { super.pressesEnded(rest, with: event) }
    }
}

struct GameSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> GameSurfaceView { GameSurfaceView() }
    func updateUIView(_ view: GameSurfaceView, context: Context) {}
}
#endif
