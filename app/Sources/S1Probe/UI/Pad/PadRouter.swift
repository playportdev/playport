// SPDX-License-Identifier: GPL-3.0-or-later
// The controller in Playport's own screens. iOS gives SwiftUI no gamepad
// focus on iPhone, so the router reads every extended gamepad through
// GameController, turns its snapshots into presses (HostIOKit.PadNavigation:
// a button as it goes down, a held direction repeating) and publishes them;
// the shell (AppShell.swift) moves the focus ring (PadFocus.swift) or runs
// the footer's action for each. A footer tap and a dev build's `pad:` action
// send the same presses (`send`).
//
// While a game runs the pad is the guest's: HostIO.start hands it off
// (`handOff`), and HostIO sets its own valueChangedHandler on every pad. The
// app restarts after a game (decision 0029), so the router takes the pad back
// only when a launch ended before the runtime was used (`takeBack`).

import Combine
import GameController
import HostIOKit
import SwiftUI

@MainActor
final class PadRouter: ObservableObject {
    static let shared = PadRouter()

    /// The controller the top bar names, with its battery when it reports one.
    struct Controller: Equatable {
        var name: String
        var battery: Int?
        var charging: Bool
    }

    @Published private(set) var controller: Controller?
    /// Every controller connected, the current one first (Settings › Controllers).
    @Published private(set) var controllers: [Controller] = []
    let presses = PassthroughSubject<NavButton, Never>()
    private(set) var handedOff = false

    private var nav = PadNavigation()
    private var clock: Timer?
    private var batteryClock: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    /// Once, when the product UI first appears.
    func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect, .GCControllerDidBecomeCurrent] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PadRouter.shared.attachAll() }
            })
        }
        attachAll()
        batteryClock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { PadRouter.shared.readController() }
        }
    }

    /// A press from anywhere but a pad: a footer tap, the dev driver.
    func send(_ b: NavButton) {
        guard !handedOff else { return }
        presses.send(b)
    }

    /// A game starts: from here the pads are the guest's (HostIO).
    func handOff() {
        handedOff = true
        nav.reset()
        stopClock()
    }

    /// A launch ended before the runtime was used, so no restart follows.
    func takeBack() {
        guard handedOff else { return }
        handedOff = false
        attachAll()
    }

    private func attachAll() {
        readController()
        guard !handedOff else { return }
        let pads = GCController.controllers().compactMap(\.extendedGamepad)
        for pad in pads {
            pad.valueChangedHandler = { gp, _ in
                MainActor.assumeIsolated { PadRouter.shared.changed(gp) }
            }
        }
        if pads.isEmpty {
            nav.reset()
            stopClock()
        }
    }

    private func readController() {
        let pads = GCController.controllers().filter { $0.extendedGamepad != nil }
        let current = GCController.current.flatMap { c in pads.contains(c) ? c : nil } ?? pads.first
        let all = (current.map { [$0] } ?? []) + pads.filter { $0 !== current }
        let read = all.map(Self.describe)
        if read != controllers { controllers = read }
        if read.first != controller { controller = read.first }
    }

    private static func describe(_ c: GCController) -> Controller {
        let level = c.battery.map { Int(($0.batteryLevel * 100).rounded()) }
        return Controller(name: c.productCategory.isEmpty ? c.vendorName ?? "Controller" : c.productCategory,
                          battery: level.flatMap { (0...100).contains($0) ? $0 : nil },
                          charging: c.battery?.batteryState == .charging)
    }

    /// Reads the controllers and their batteries now (Settings › Controllers on appear).
    func refreshControllers() { readController() }

    private func changed(_ gp: GCExtendedGamepad) {
        guard !handedOff else { return }
        for b in nav.update(PadInput(gp), at: ProcessInfo.processInfo.systemUptime) { presses.send(b) }
        if nav.isRepeating, clock == nil {
            clock = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
                MainActor.assumeIsolated { PadRouter.shared.tick() }
            }
        } else if !nav.isRepeating {
            stopClock()
        }
    }

    private func tick() {
        guard !handedOff, nav.isRepeating else { return stopClock() }
        for b in nav.tick(at: ProcessInfo.processInfo.systemUptime) { presses.send(b) }
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
    }
}

extension PadInput {
    /// A GameController snapshot, by position on the Xbox layout (HostIOKit.PadInput).
    init(_ gp: GCExtendedGamepad) {
        self.init()
        a = gp.buttonA.isPressed; b = gp.buttonB.isPressed; x = gp.buttonX.isPressed; y = gp.buttonY.isPressed
        leftShoulder = gp.leftShoulder.isPressed; rightShoulder = gp.rightShoulder.isPressed
        menu = gp.buttonMenu.isPressed; options = gp.buttonOptions?.isPressed ?? false
        home = gp.buttonHome?.isPressed ?? false
        leftThumb = gp.leftThumbstickButton?.isPressed ?? false; rightThumb = gp.rightThumbstickButton?.isPressed ?? false
        up = gp.dpad.up.isPressed; down = gp.dpad.down.isPressed; left = gp.dpad.left.isPressed; right = gp.dpad.right.isPressed
        leftTrigger = gp.leftTrigger.value; rightTrigger = gp.rightTrigger.value
        lx = gp.leftThumbstick.xAxis.value; ly = gp.leftThumbstick.yAxis.value
        rx = gp.rightThumbstick.xAxis.value; ry = gp.rightThumbstick.yAxis.value
    }
}
