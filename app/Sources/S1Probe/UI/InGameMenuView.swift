// SPDX-License-Identifier: GPL-3.0-or-later
// Playport's in-game menu (QuickMenu.dc.html; decision 0034, the plan's Hard
// problem 2): a long press of the controller's Home button over a running game
// (HostIO, HostIOKit.QuickMenuControl), or a three-finger tap on the game
// (HostIO.menuGesture), opens it, and the game is paused behind it:
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
// Its rows: Resume (also B, ≡ and Home), Controls (a panel beside the rows,
// QuickMenuControls.dc.html: the game's on-screen controls, Off or Gamepad, the
// Gamepad layout's d-pad and right stick, their opacity, gyro aim's output
// and sensitivity, and with a controller connected its controller map's mode,
// saved for the game and applied at once; UI/TouchControlsView.swift,
// GyroSensors.swift, ControllerMapView.swift; A on the Controller row, a tap on
// its "Edit controller…", or choosing Custom there opens the full Controller
// page and its ActionPicker over the paused game, InGameControllerPage, B back
// to the panel),
// Screenshot (the frame on screen to
// Photos; a dev build also keeps a PNG in Documents/Screenshots), Performance
// overlay (the Metal HUD on the game layer, now and for this game only), the
// controller with its battery, and Quit game (TitleLaunch.quit: WM_CLOSE to
// the game's windows, so it saves as when its window is closed, then the
// restart after the game, decision 0029, returns to Home).

import CoreImage
import HostIOKit
import Metal
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
    /// The Controller page is up over the panel (InGameControllerPage): the game's own map, edited
    /// while the game stays paused and the menu keeps its input (the guest's pads held).
    @Published private(set) var editor = false

    private static func log(_ line: String) { HostIO.log("menu: " + line) }

    /// Home held on a pad (HostIO), or a three-finger tap on the game (HostIO.menuGesture). False when there is no game to pause yet.
    @discardableResult
    func open() -> Bool {
        let launch = TitleLaunch.shared
        guard !isOpen else { return true }
        // A web page the game opened holds the game's input already; it closes first.
        guard !GameWebSheet.shared.isUp else {
            Self.log("Home held, but a web page is up over \(launch.title)")
            return false
        }
        guard launch.acceptsMenu else {
            Self.log("Home held, but no game is running yet (step \(launch.step.map { "\($0)" } ?? "none"))")
            return false
        }
        isOpen = true
        menu = QuickMenu()
        shot = nil
        HostIO.shared.menuOpened()
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
        if editor {
            editorPress(b)
            #if !PLAYPORT_RELEASE
            Self.log("pad \(b.rawValue): controller page, \(editorSummary)")
            #endif
            return
        }
        if let row = menu.panel {
            let rows = QuickMenuControlsRow.shown(controller: OnScreenControls.shared.controllers > 0)
            switch b {
            case .up: menu.move(down: false, rows: rows)
            case .down: menu.move(down: true, rows: rows)
            case .left: changeControls(row, by: -1)
            case .right: changeControls(row, by: 1)
            case .a where row == .controllerMap: openEditor()
            case .a: changeControls(row, by: 1, wrapping: true)
            case .b: menu.closePanel()
            case .menu: resume()
            default: return
            }
            #if !PLAYPORT_RELEASE
            Self.log("pad \(b.rawValue): controls panel \(menu.panel?.rawValue ?? "closed"), \(OnScreenControls.shared.state.summary)")
            #endif
            return
        }
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
        case .controls: menu.openPanel()
        case .screenshot: screenshot()
        case .overlay: toggleOverlay()
        case .controller: PadRouter.shared.refreshControllers()
        case .quit: quit()
        }
    }

    /// The Controls panel's row `row` moved `by` steps (left -1, right +1; A
    /// goes round): saved as the game's own, and the controls change at once.
    func changeControls(_ row: QuickMenuControlsRow, by: Int, wrapping: Bool = false) {
        guard isOpen, !quitting, let id = TitleLaunch.shared.titleID else { return }
        menu.openPanel(row)
        let now = OnScreenControls.shared.state
        var mine = ControlsStore.shared.game(id)
        var intoEditor = false
        switch row {
        case .layout:
            mine.layout = Self.step(now.layout, by: by, wrapping: wrapping)
        case .dpad:
            mine.dpad = Self.step(now.dpad, by: by, wrapping: wrapping)
        case .rightStick:
            mine.rightStick = Self.step(now.rightStick, by: by, wrapping: wrapping)
        case .opacity:
            let next = ControlsOpacity.step(now.opacity, by: by)
            mine.opacity = wrapping && next == now.opacity ? ControlsOpacity.steps[0] : next
        case .gyro:
            mine.gyro = GyroRow.output.setting(GyroRow.output.step(ControlsStore.shared.gyro(id), by: by, wrapping: wrapping),
                                               in: mine.gyro)
        case .gyroSensitivity:
            mine.gyro = GyroRow.sensitivity.setting(GyroRow.sensitivity.step(ControlsStore.shared.gyro(id), by: by, wrapping: wrapping),
                                                    in: mine.gyro)
        case .controllerMap:
            // The mode only; Custom plays the game's own table (a copy of Keyboard & mouse until it is edited).
            var map = mine.controllerMap(over: ControlsStore.shared.defaults)
            let was = map.mode
            map.mode = Self.step(map.mode, by: by, wrapping: wrapping)
            mine.controllerMap = map
            // Custom chosen: straight into its editor (owner, 2026-10-13: it changed nothing visible).
            intoEditor = map.mode == .custom && was != .custom
        }
        ControlsStore.shared.setGame(id, mine)
        Self.log("controls for \(id): layout \(mine.layout?.rawValue ?? "default") dpad \(mine.dpad?.rawValue ?? "default") "
                 + "rightStick \(mine.rightStick?.rawValue ?? "default") opacity \(mine.opacity.map(ControlsOpacity.label) ?? "default") "
                 + "gyro \(mine.gyro?.output?.rawValue ?? "default") sensitivity \(mine.gyro?.sensitivity.map { String($0) } ?? "default") "
                 + "controllerMap \(mine.controllerMap?.mode.rawValue ?? "default")")
        if intoEditor { openEditor() }
    }

    // MARK: the Controller page over the paused game

    /// Edit controller…: the game's Controller page over the panel, its ring on the mode switch.
    func openEditor() {
        guard isOpen, !quitting, !editor, let id = TitleLaunch.shared.titleID else { return }
        menu.openPanel(.controllerMap)
        PadFocus.shared.reset(start: ControllerMapView.modeID)
        editor = true
        Self.log("controller page open for \(id): \(ControlsStore.shared.game(id).controllerMap(over: ControlsStore.shared.defaults).summary)")
    }

    /// B on the page: back to the panel's Controller row (a picker over it closes first, as in the shell).
    func closeEditor() {
        guard editor else { return }
        PadModal.shared.close()
        editor = false
        Self.log("controller page closed; back to the controls panel")
    }

    /// A press on the page, as the shell routes it there (AppShell.press): a picker's first, then
    /// the page's (ControllerMapRing.pagePress), B back to the panel.
    private func editorPress(_ b: NavButton) {
        if PadModal.shared.isUp { return PadModal.shared.press(b) }
        ControllerMapRing.pagePress(b) { closeEditor() }
    }

    #if !PLAYPORT_RELEASE
    /// The page's state for the driver's log: the ringed item, a picker over it, the map.
    var editorSummary: String {
        "focus \(PadFocus.shared.focused ?? "none")" + (PadModal.shared.summary.map { ", \($0)" } ?? "")
            + ", controller map \(TitleLaunch.shared.titleID.map { ControlsStore.shared.game($0).controllerMap(over: ControlsStore.shared.defaults).summary } ?? "none")"
    }
    #endif

    /// The value `by` steps from `value` along its cases, stopping at the ends (going round with `wrapping`).
    static func step<T: CaseIterable & Equatable>(_ value: T, by: Int, wrapping: Bool) -> T where T.AllCases == [T] {
        let all = T.allCases
        let i = all.firstIndex(of: value)! + by
        return wrapping ? all[(i % all.count + all.count) % all.count] : all[max(0, min(all.count - 1, i))]
    }

    /// Back to the game: its threads go on first, then its input and audio.
    func resume() {
        guard isOpen, !quitting else { return }
        if editor {
            PadModal.shared.close()
            editor = false
        }
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
        if editor { PadModal.shared.close() }
        editor = false
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
            Self.log(PacedMetalLayer.lastPresented.map { "screenshot: frame \($0.width)x\($0.height) not read" }
                     ?? "screenshot: no frame")
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
    /// A texture Core Image does not read (KosmicKrisp's swap chain images are
    /// render targets only, with no shader read usage) is read through a plain 2D
    /// copy of its first slice.
    private static func image(of texture: any MTLTexture) -> UIImage? {
        if let image = coreImage(of: texture) { return image }
        log("screenshot: Core Image did not read \(describe(texture)); trying a 2D copy")
        guard let copy = plainCopy(of: texture) else {
            log("screenshot: no 2D copy of \(describe(texture))")
            return nil
        }
        return coreImage(of: copy)
    }

    private static func coreImage(of texture: any MTLTexture) -> UIImage? {
        guard let ci = CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]) else { return nil }
        let context = CIContext(mtlDevice: texture.device)
        let flipped = ci.settingAlphaOne(in: ci.extent).oriented(.downMirrored)
        guard let cg = context.createCGImage(flipped, from: flipped.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Slice 0, level 0 of texture as a 2D, shader-readable texture of the same format,
    /// copied on the GPU now (the game is paused, so nothing writes it meanwhile).
    private static func plainCopy(of texture: any MTLTexture) -> (any MTLTexture)? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                         height: texture.height, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .private
        guard let copy = texture.device.makeTexture(descriptor: d),
              let queue = texture.device.makeCommandQueue(),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else {
            log("screenshot: the 2D copy failed: \(commands.error.map { "\($0)" } ?? "status \(commands.status.rawValue)")")
            return nil
        }
        return copy
    }

    private static func describe(_ t: any MTLTexture) -> String {
        "\(t.width)x\(t.height) type=\(t.textureType.rawValue) format=\(t.pixelFormat.rawValue) "
            + "usage=\(t.usage.rawValue) storage=\(t.storageMode.rawValue) framebufferOnly=\(t.isFramebufferOnly)"
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
        "menu \(isOpen ? "open" : "closed"), ring \(menu.ring.rawValue)" + (menu.panel.map { " (panel \($0.rawValue))" } ?? "")
            + (editor ? " (controller page: \(editorSummary))" : "")
            + ", paused=\(paused) overlay=\(overlay), controls \(OnScreenControls.shared.state.summary)"
            + ", gyro \(TitleLaunch.shared.titleID.map { GyroText.summary(ControlsStore.shared.gyro($0)) } ?? "none")"
            + ", controller map \(TitleLaunch.shared.titleID.map { ControlsStore.shared.game($0).controllerMap(over: ControlsStore.shared.defaults).summary } ?? "none")"
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
    @ObservedObject private var controls = OnScreenControls.shared
    @ObservedObject private var store = ControlsStore.shared

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
                Spacer(minLength: 0)
            }
            .padding(.top, 22).padding(.leading, lead).padding(.trailing, 20)
            .frame(width: 330 + lead - 44, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(PP.surface)
            .overlay(alignment: .trailing) { Rectangle().fill(PP.line).frame(width: 1) }
            .ignoresSafeArea()
            if let row = model.menu.panel {
                ControlsPanel(ring: row, state: controls.state,
                              gyro: launch.titleID.map { store.gyro($0) } ?? store.gyroDefaults,
                              map: launch.titleID.map { store.game($0).controllerMap(over: store.defaults) } ?? store.defaults.controllerMap,
                              rows: QuickMenuControlsRow.shown(controller: controls.controllers > 0))
                    .padding(.leading, 330 + lead - 44 + 24).padding(.top, 22)
                    // Clear of the footer: past this the rows scroll (ControlsPanel).
                    .padding(.bottom, safe.insets.bottom + 36 + 8)
            }
            if downloadsWaiting && model.menu.panel == nil {
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
                    PadFooter(hints: model.menu.panel == nil ? [
                        PadHint(button: .a, label: "Choose") { model.press(.a) },
                        PadHint(button: .b, label: "Back to game") { model.resume() },
                    ] : [
                        PadHint(button: .a, label: model.menu.panel == .controllerMap ? "Edit controller…" : "Change") { model.press(.a) },
                        PadHint(button: .b, label: "Back") { model.press(.b) },
                    ], leading: true)
                    .fixedSize()
                }
                .padding(.trailing, trail)
                .padding(.bottom, safe.insets.bottom)
            }
            if model.editor, let id = launch.titleID {
                InGameControllerPage(titleID: id, title: launch.title)
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
        case .resume: return nil
        case .controls: return controls.state.summary
        case .screenshot: return model.shot ?? "Saved to Photos"
        case .overlay: return model.overlay ? "On" : "Off"
        case .controller:
            #if !PLAYPORT_RELEASE
            // The dev build's scripted pad is no GameController pad, so the router has no name for it
            // ("None" with it connected: touch controls 3c).
            if router.controller == nil, VirtualPad.shared.connected { return "Scripted pad" }
            #endif
            return QuickMenu.controller(name: router.controller?.name, battery: router.controller?.battery)
        case .quit: return model.quitting ? "Closing…" : "Saves first"
        }
    }

    /// Downloads the launch held (SteamInstalls): they go on after the game.
    private var downloadsWaiting: Bool {
        !(SteamAccountModel.current?.installs.order.isEmpty ?? true)
    }
}

/// The Controls panel beside the menu's rows (QuickMenuControls.dc.html): the
/// game's on-screen layout, its d-pad and right stick, their opacity, and gyro
/// aim's output and sensitivity, and, while a controller is connected, its
/// controller map's mode. A tap does what left and right do. Rows are 36 pt;
/// on a screen too short for all of them (seven on a 375 pt tall one) the rows
/// scroll, and the ringed row is scrolled to.
private struct ControlsPanel: View {
    let ring: QuickMenuControlsRow
    let state: ControlsState
    /// The game's gyro aim, its own over the defaults.
    let gyro: GyroSettings
    /// The game's controller map, its own over the default.
    let map: ControllerMap
    /// The rows shown (QuickMenuControlsRow.shown).
    let rows: [QuickMenuControlsRow]
    private var model: InGameMenu { InGameMenu.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Controls").font(PP.display(20))
                Text("For this game · saved as you change them").font(.system(size: 12)).foregroundStyle(PP.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.bottom, 6)
            ViewThatFits(in: .vertical) {
                rowList
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) { rowList }
                        .onAppear { proxy.scrollTo(ring) }
                        .onChange(of: ring) { _, r in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(r) } }
                }
            }
        }
        .padding(12)
        .frame(width: 330, alignment: .leading)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PP.line, lineWidth: 1))
        .accessibilityIdentifier("menu-controls-panel")
    }

    private var rowList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.self) { r in
                rowView(r).id(r)
            }
            if !state.visible && state.layout != .off {
                Text("Hidden while a controller is connected.").font(.system(size: 12)).foregroundStyle(PP.muted)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ r: QuickMenuControlsRow) -> some View {
        switch r {
        case .layout: row(.layout) { choices(.layout, OnScreenLayout.allCases, state.layout, title: \.title) }
        case .dpad: row(.dpad) { choices(.dpad, OnScreenDpad.allCases, state.dpad, title: \.title) }
        case .rightStick: row(.rightStick) { choices(.rightStick, OnScreenRightStick.allCases, state.rightStick, title: \.shortTitle) }
        case .opacity: row(.opacity) { stepper(.opacity, ControlsOpacity.label(state.opacity)) }
        case .gyro: row(.gyro, subtitle: gyroSource) { choices(.gyro, GyroOutput.allCases, gyro.output, title: \.gyroTitle) }
        case .gyroSensitivity: row(.gyroSensitivity) { stepper(.gyroSensitivity, GyroText.sensitivity(gyro.sensitivity)) }
        case .controllerMap:
            // "Edit controller…" under the title: the full page over the paused game (A on the row too).
            row(.controllerMap, subtitle: "Edit controller…", edit: { model.openEditor() }) {
                choices(.controllerMap, ControllerMap.Mode.allCases, map.mode, title: \.shortTitle, compact: true)
            }
        }
    }

    /// Under Gyro aim: the gyro it reads (QuickMenuControls.dc.html's "iPhone gyro").
    private var gyroSource: String {
        let use = GyroText.sourceInUse(gyro.source, device: GyroSensors.shared.device(for: gyro))
        guard gyro.output != .off else { return "Moves the view as you turn" }
        return use.why ?? "Always on · " + use.value + " gyro"
    }

    /// `edit`: the title and subtitle are a tap target too, the subtitle a link (the Controller row's Edit controller…).
    private func row<V: View>(_ r: QuickMenuControlsRow, subtitle: String? = nil, edit: (() -> Void)? = nil,
                              @ViewBuilder value: () -> V) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                // One line: "Controller" wrapped beside its three modes (touch controls 3c).
                Text(r.title).font(.system(size: 14, weight: .medium)).lineLimit(1).fixedSize()
                if let subtitle {
                    Text(subtitle + (edit == nil ? "" : " ›")).font(.system(size: 10, weight: edit == nil ? .regular : .semibold))
                        .foregroundStyle(edit == nil ? PP.muted : PP.accent).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { edit?() }
            .accessibilityIdentifier(edit == nil ? "menu-controls-\(r.rawValue)-title" : "menu-controls-\(r.rawValue)-edit")
            Spacer(minLength: 8)
            value()
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(PP.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ring == r ? PP.accent : .clear, lineWidth: 2))
        .accessibilityIdentifier("menu-controls-\(r.rawValue)")
    }

    /// A row's values side by side, the current one filled; a tap chooses one.
    /// `compact`: narrower, so a long title fits beside three of them (the Controller row).
    private func choices<T: Hashable & RawRepresentable>(_ r: QuickMenuControlsRow, _ all: [T], _ current: T,
                                                          title: KeyPath<T, String>, compact: Bool = false) -> some View
    where T.RawValue == String {
        HStack(spacing: 2) {
            ForEach(all, id: \.self) { v in
                Text(v[keyPath: title]).font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).fixedSize()   // the subtitle beside it gives way, never a value
                    .foregroundStyle(v == current ? PP.background : PP.muted)
                    .padding(.horizontal, compact ? 6 : 9).padding(.vertical, 5)
                    .background(v == current ? PP.text : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { model.changeControls(r, by: all.firstIndex(of: v)! - all.firstIndex(of: current)!) }
                    .accessibilityIdentifier("menu-controls-\(r.rawValue)-\(v.rawValue)")
            }
        }
        .padding(2)
        .background(PP.background, in: RoundedRectangle(cornerRadius: 10))
    }

    /// ‹ value ›: a tap on an arrow steps the row.
    private func stepper(_ r: QuickMenuControlsRow, _ value: String) -> some View {
        HStack(spacing: 8) {
            arrow(r, "‹", by: -1)
            Text(value).font(.system(size: 14, weight: .semibold))
            arrow(r, "›", by: 1)
        }
    }

    private func arrow(_ r: QuickMenuControlsRow, _ s: String, by: Int) -> some View {
        Text(s).font(.system(size: 16)).foregroundStyle(PP.muted)
            .frame(minWidth: 18, minHeight: 30)
            .contentShape(Rectangle())
            .onTapGesture { model.changeControls(r, by: by) }
    }
}

/// The Controller page over the paused game (the Controls panel's Edit controller…, or Custom
/// chosen there): the game's own map as Game options › Controls › Controller shows it, saved at
/// once (ControlsStore) and applied on Resume. The shell is not up while a game runs, so the page
/// brings what the shell gives it there: the focus ring's root, the footer, and the pickers
/// (PadModalHost, the ActionPicker among them). Its presses come from the in-game menu
/// (InGameMenu.press: the pads stay held from the guest), B back to the panel.
private struct InGameControllerPage: View {
    let titleID: String
    let title: String
    @ObservedObject private var model = InGameMenu.shared
    @ObservedObject private var focus = PadFocus.shared
    @ObservedObject private var modal = PadModal.shared
    @ObservedObject private var safe = WindowInsets.shared

    var body: some View {
        VStack(spacing: 0) {
            ControllerMapView(target: .game(titleID), context: title)
            // A picker draws its own footer; hidden, not removed, so the page keeps its height (as the shell's).
            PadFooter(hints: ControllerMapRing.hints { model.closeEditor() })
                .opacity(modal.isUp ? 0 : 1)
                .padding(.bottom, AppShell.footerBottom)
        }
        // The game surface ignores the safe area, so the window's insets are given back here
        // (WindowInsets); the footer sits low, in the home indicator's inset, as in the shell.
        .safeAreaPadding(EdgeInsets(top: safe.insets.top, leading: safe.insets.leading, bottom: 0, trailing: safe.insets.trailing))
        .background(PP.background)
        .padFocusRoot()
        .overlay {
            PadModalHost().safeAreaPadding(safe.insets).animation(.easeOut(duration: 0.15), value: modal.isUp)
        }
        .accessibilityIdentifier("in-game-controller-page")
    }
}

private extension GyroOutput {
    /// The panel's short word for it: "Stick", so Off, Mouse and Stick fit beside the gyro's source.
    var gyroTitle: String { self == .rightStick ? "Stick" : GyroText.output(self) }
}
