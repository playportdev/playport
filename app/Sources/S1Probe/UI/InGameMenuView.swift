// SPDX-License-Identifier: GPL-3.0-or-later
// Playport's in-game menu (QuickMenu.dc.html; decision 0034, the plan's Hard
// problem 2): a long press of the controller's Home button over a running game
// opens it (HostIO, HostIOKit.QuickMenuControl), and the game is paused behind
// it:
//
//   - input: the guest's pads rest, and keys, touches and the mouse stop
//     (HostIO.holdGuest; a button still down from the menu stays up for the
//     game after it closes, HostIOKit.GuestPadGate);
//   - audio: the RemoteIO units stop (HostIOKit.Lifecycle, menuOpened);
//   - threads: the session root suspends every thread of the game's
//     processes (PP_CONTROL_PAUSE, app/SessionRoot/playport-session.c), each
//     held by the wineserver only at a safe point (in guest code, outside a
//     server call: patches/madeira-unix 0010), and resumes them on Resume.
//
// Its rows: Resume (also B, ≡ and Home), Screenshot (the frame on screen to
// Photos; a dev build also keeps a PNG in Documents/Screenshots), Performance
// overlay (the Metal HUD on the game layer, now and for this game only), the
// controller with its battery, and Quit game (TitleLaunch.quit: WM_CLOSE to
// the game's windows, so it saves as when its window is closed, then the
// restart after the game, decision 0029, returns to Home).

import CoreImage
import HostIOKit
import Photos
import PlayportKit
import SwiftUI
import UIKit
import WineHost

@MainActor
final class InGameMenu: ObservableObject {
    static let shared = InGameMenu()

    @Published private(set) var isOpen = false
    @Published private(set) var menu = QuickMenu()
    /// The performance overlay as the game layer has it now.
    @Published private(set) var overlay = MetalHUD.enabled
    /// Screenshot's value: nil until one is taken, then what happened.
    @Published private(set) var shot: String?
    @Published private(set) var quitting = false
    /// The session root holds the game's threads.
    @Published private(set) var paused = false

    private static func log(_ line: String) { HostIO.log("menu: " + line) }

    /// Home held on a pad (HostIO). False when there is no game to pause yet.
    @discardableResult
    func open() -> Bool {
        let launch = TitleLaunch.shared
        guard !isOpen else { return true }
        guard launch.acceptsMenu else {
            Self.log("Home held, but no game is running yet (step \(launch.step.map { "\($0)" } ?? "none"))")
            return false
        }
        isOpen = true
        menu = QuickMenu()
        shot = nil
        HostIO.shared.holdGuest()
        Self.log("open over \(launch.title); \(WindowInsets.shared.read())")
        HostIO.sessionControl(Int(PP_CONTROL_PAUSE), "pause") { rc, _ in
            if rc == 0, InGameMenu.shared.isOpen { InGameMenu.shared.paused = true }
        }
        return true
    }

    /// A press from a pad (HostIO) or, in a dev build, the driver.
    func press(_ b: NavButton) {
        guard isOpen, !quitting else { return }
        switch b {
        case .up: menu.move(down: false)
        case .down: menu.move(down: true)
        case .a: choose(menu.ring)
        case .b, .menu: resume()
        default: return
        }
        #if !PLAYPORT_RELEASE
        Self.log("pad \(b.rawValue): ring \(menu.ring.rawValue)")
        #endif
    }

    /// A row chosen with A or a tap.
    func choose(_ item: QuickMenuItem) {
        guard isOpen, !quitting else { return }
        menu.ring(item)
        switch item {
        case .resume: resume()
        case .screenshot: screenshot()
        case .overlay: toggleOverlay()
        case .controller: PadRouter.shared.refreshControllers()
        case .quit: quit()
        }
    }

    /// Back to the game: its threads go on first, then its input and audio.
    func resume() {
        guard isOpen, !quitting else { return }
        isOpen = false
        paused = false
        HostIO.sessionControl(Int(PP_CONTROL_RESUME), "resume")
        HostIO.shared.releaseGuest()
        Self.log("closed; back to \(TitleLaunch.shared.title)")
    }

    private func quit() {
        quitting = true
        Self.log("quit game")
        TitleLaunch.shared.quit()
    }

    /// The launch ended (TitleLaunch.end): nothing is left to resume.
    func gameEnded() {
        isOpen = false
        paused = false
        quitting = false
    }

    private func toggleOverlay() {
        guard let layer = HostIO.shared.gameLayer else { return }
        overlay.toggle()
        MetalHUD.set(overlay, on: layer)
    }

    // MARK: Screenshot

    private func screenshot() {
        guard shot != "Saving…" else { return }
        guard let texture = PacedMetalLayer.lastPresented, let image = Self.image(of: texture) else {
            shot = "No frame to save"
            Self.log("screenshot: no frame")
            return
        }
        shot = "Saving…"
        Self.log("screenshot: \(Int(image.size.width))x\(Int(image.size.height))")
        #if !PLAYPORT_RELEASE
        Self.keepInDocuments(image)
        #endif
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in InGameMenu.shared.saved("Photos access is off", "not allowed (\(status.rawValue))") }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { ok, error in
                let why = error.map { "\($0.localizedDescription)" } ?? "failed"
                Task { @MainActor in InGameMenu.shared.saved(ok ? "Saved to Photos" : "Not saved", ok ? "saved to Photos" : why) }
            }
        }
    }

    private func saved(_ value: String, _ line: String) {
        shot = value
        Self.log("screenshot: " + line)
    }

    /// The texture as the player sees it: Core Image reads a Metal texture
    /// upside down, and the layer is opaque, so whatever alpha the game left
    /// in it is not the picture's (a PNG with it came out washed grey).
    private static func image(of texture: any MTLTexture) -> UIImage? {
        guard let ci = CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]) else { return nil }
        let context = CIContext(mtlDevice: texture.device)
        let flipped = ci.settingAlphaOne(in: ci.extent).oriented(.downMirrored)
        guard let cg = context.createCGImage(flipped, from: flipped.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    #if !PLAYPORT_RELEASE
    /// Dev builds: a copy the workstation can pull (`pp phone pull Documents/Screenshots`),
    /// which does not wait for the Photos permission a person has to give.
    private static func keepInDocuments(_ image: UIImage) {
        let dir = WineHostRuntime.documents.appendingPathComponent("Screenshots", isDirectory: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        let url = dir.appendingPathComponent("\(f.string(from: Date())).png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try image.pngData()?.write(to: url)
            log("screenshot: Documents/Screenshots/\(url.lastPathComponent)")
        } catch {
            log("screenshot: not kept in Documents: \(error)")
        }
    }
    #endif

    #if !PLAYPORT_RELEASE
    /// The driver's summary line (Dev/UIDriver.swift).
    var summary: String {
        "menu \(isOpen ? "open" : "closed"), ring \(menu.ring.rawValue), paused=\(paused) overlay=\(overlay)"
            + (shot.map { ", screenshot: \($0)" } ?? "") + (quitting ? ", quitting" : "")
    }
    #endif
}

/// The menu over the paused game (QuickMenu.dc.html): the game dimmed, a
/// panel down the left with the rows, the downloads' note at the top right,
/// and the footer. It lies over the game surface, which ignores the safe
/// area, so the panel's background runs to the screen's edge while its rows,
/// the note and the footer keep the design's 44 pt margin or, where the
/// Dynamic Island is (left or right, as the phone is turned), clear of it
/// (WindowInsets).
struct InGameMenuView: View {
    @ObservedObject private var model = InGameMenu.shared
    @ObservedObject private var launch = TitleLaunch.shared
    @ObservedObject private var router = PadRouter.shared
    @ObservedObject private var safe = WindowInsets.shared
    #if !PLAYPORT_RELEASE
    @ObservedObject private var memory = SharedMemoryProbe.shared
    #endif

    var body: some View {
        let lead = safe.side(44, safe.insets.leading), trail = safe.side(44, safe.insets.trailing)
        ZStack(alignment: .topLeading) {
            Color(red: 5 / 255, green: 7 / 255, blue: 10 / 255).opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture {}   // the game behind takes no touches
            VStack(alignment: .leading, spacing: 3) {
                Text(QuickMenu.playing(seconds: Date().timeIntervalSince(launch.startedAt)).uppercased())
                    .font(.system(size: 11, weight: .semibold)).tracking(1.1).foregroundStyle(PP.muted)
                    .padding(.horizontal, 14)
                Text(launch.title).font(PP.display(24)).lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, 14).padding(.bottom, 10)
                ForEach(QuickMenuItem.allCases, id: \.self) { item in
                    row(item)
                }
                #if !PLAYPORT_RELEASE
                Text(memory.status).font(.system(size: 11)).foregroundStyle(PP.muted)
                    .padding(.horizontal, 14).padding(.top, 8)
                    .task { await memory.reportRuntime() }
                #endif
                Spacer(minLength: 0)
            }
            .padding(.top, 22).padding(.leading, lead).padding(.trailing, 20)
            .frame(width: 330 + lead - 44, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(PP.surface)
            .overlay(alignment: .trailing) { Rectangle().fill(PP.line).frame(width: 1) }
            .ignoresSafeArea()
            if downloadsWaiting {
                HStack(spacing: 8) {
                    Circle().fill(PP.muted).frame(width: 8, height: 8)
                    Text("Downloads paused while you play")
                }
                .font(.system(size: 13)).foregroundStyle(PP.soft)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(PP.surface, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, trail).padding(.top, 22)
            }
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    PadFooter(hints: [
                        PadHint(button: .a, label: "Choose") { model.press(.a) },
                        PadHint(button: .b, label: "Back to game") { model.resume() },
                    ], leading: true)
                    .fixedSize()
                }
                .padding(.trailing, trail)
                .padding(.bottom, safe.insets.bottom)
            }
        }
        // The margins above come from the window's insets themselves: laid out over the
        // whole screen, or the note and the footer would be inset twice (the overlay
        // keeps the safe area although the game surface under it ignores it).
        .ignoresSafeArea()
        .foregroundStyle(PP.text)
        .statusBarHidden()
        .accessibilityIdentifier("in-game-menu")
    }

    private func row(_ item: QuickMenuItem) -> some View {
        let ringed = model.menu.ring == item
        return Button { model.choose(item) } label: {
            HStack(spacing: 12) {
                Text(item.title).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ringed ? PP.background : item == .quit ? Color(hex: 0xFF9A8A) : PP.text)
                Spacer(minLength: 0)
                if let v = value(item) {
                    Text(v).font(.system(size: 13)).foregroundStyle(ringed ? PP.background.opacity(0.7) : PP.muted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(ringed ? PP.text : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("menu-\(item.rawValue)")
    }

    private func value(_ item: QuickMenuItem) -> String? {
        switch item {
        case .resume: nil
        case .screenshot: model.shot ?? "Saved to Photos"
        case .overlay: model.overlay ? "On" : "Off"
        case .controller: QuickMenu.controller(name: router.controller?.name, battery: router.controller?.battery)
        case .quit: model.quitting ? "Closing…" : "Saves first"
        }
    }

    /// Downloads the launch held (SteamInstalls): they go on after the game.
    private var downloadsWaiting: Bool {
        !(SteamAccountModel.current?.installs.order.isEmpty ?? true)
    }
}
