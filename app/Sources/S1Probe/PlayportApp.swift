// SPDX-License-Identifier: GPL-3.0-or-later
// Playport's app (docs/ARCHITECTURE.md): the product UI (UI/AppShell.swift).
// A dev build can also be driven through that UI from the workstation
// (S1_MODE=ui, Dev/UIDriver.swift); a release build cannot (decisions 0009, 0012).

import Foundation
import SwiftUI
import UIKit

@main
struct PlayportApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // Both fix the container's Documents before anything can move HOME.
        _ = WineHostRuntime.documents
        AppLog.start()
        #if !PLAYPORT_RELEASE
        // A driven run that restarted Playport goes on in this process (its
        // environment, before anything reads it), then settings an earlier
        // driver session changed go back before anything reads them.
        DriverContinuation.adoptAtStart()
        DriverUndo.restoreAtStart()
        #endif
        // A restart after a game (AppRestart): why that game did not end cleanly, once.
        TitleLaunch.shared.message = AppRestart.noteLaunch()
        MetalHUD.loadAtStart()
        #if !PLAYPORT_RELEASE
        GPUCapture.loadAtStart()
        MetalValidation.loadAtStart()
        RuntimeCounters.loadAtStart()
        #endif
        MemoryLimit.logAtStart()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @ObservedObject private var launch = TitleLaunch.shared
    @ObservedObject private var menu = InGameMenu.shared
    @ObservedObject private var restart = AppRestart.shared
    @ObservedObject private var setup = JitSetup.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if launch.running {
                // A title started from the library: the whole screen is the guest's swap chain (HostIO.swift).
                GameSurface().ignoresSafeArea()
                    // Under the launch screen, black and a little small; on the first frame it
                    // settles in as the launch screen flies off (UI/LaunchTransition.swift). A cover,
                    // not the Metal layer's own opacity: the game presents into it all along.
                    .scaleEffect(launch.showsSheet && !reduceMotion ? LaunchMotion.gameFrom : 1)
                    .overlay { Color.black.opacity(launch.showsSheet ? 1 : 0).ignoresSafeArea().allowsHitTesting(false) }
                    .animation(LaunchMotion.gameIn, value: launch.showsSheet)
                    // The launch screen covers it until the game is up (UI/LaunchViews.swift).
                    .overlay {
                        ZStack {
                            if launch.showsSheet {
                                LaunchScreen().transition(LaunchMotion.dive(scale: 1.3, blur: 10, reduceMotion: reduceMotion))
                            }
                        }
                        .animation(LaunchMotion.sheetOut, value: launch.showsSheet)
                    }
                    // Playport's menu over the paused game, on a long press of Home (UI/InGameMenuView.swift).
                    .overlay { if menu.isOpen || menu.quitting { InGameMenuView() } }
                    .statusBarHidden().persistentSystemOverlays(.hidden)
                    .transition(.identity)
            } else if restart.restarting {
                // After a game, until the phone replaces this process (AppRestart): black
                // as the game left the screen, with nothing to read (decision 0034).
                Color.black.ignoresSafeArea().statusBarHidden().persistentSystemOverlays(.hidden)
                    .transition(.identity)
            } else {
                // On Play the page dives away over the launch screen (UI/LaunchTransition.swift).
                AppShell()
                    .zIndex(1)
                    .transition(LaunchMotion.dive(scale: 1.25, blur: 8, reduceMotion: reduceMotion))
            }
        }
        .animation(LaunchMotion.pageOut, value: launch.running)
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: Binding(get: { setup.presented }, set: { if !$0 && setup.phase != .ready && setup.phase != .cancelled { setup.cancel() } }),
               onDismiss: { setup.dismissed() }) { JitSetupSheet() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                restart.sceneBecameActive()
                setup.sceneBecameActive()
            }
            // Back from LocalDevVPN after Playport turned it on (LocalDevVPN.swift).
            LocalDevVPN.scenePhaseChanged(phase)
        }
        // `playport://` only brings Playport back to the front (LocalDevVPN's
        // return); what a URL carries does nothing (decision 0012).
        .onOpenURL { _ in }
        // Why a launch did not end cleanly (here, or in the process before a restart),
        // or why Playport could not restart itself (UI/LaunchViews.swift, LaunchMessage).
        // A step that failed shows on the launch failure screen instead (PadModal).
        .alert(item: Binding(get: { launch.message?.step == nil ? launch.message : nil }, set: { launch.message = $0 })) { m in
            Alert(title: Text(m.title), message: Text(m.text), dismissButton: .default(Text("OK")))
        }
    }
}

/// The whole app is landscape, a title (TitleScreen.swift) and the gamepad UI
/// alike (UI/AppShell.swift), whichever way the phone is held.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .landscape
    }
}
