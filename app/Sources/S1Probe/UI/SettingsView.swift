// SPDX-License-Identifier: GPL-3.0-or-later
// Settings (docs/design/2026-09-28-gamepad-ui/Settings.dc.html,
// SettingsGraphics.dc.html): the sections down the left (PlayportKit
// SettingsSection), the one the ring is on shown at the right. The ring moves
// down the list with up and down, which shows each section; right goes into
// it, left and B come back to the list, B there closes Settings (AppShell's
// `settingsPress`). Every row is on the ring, and a tap does what A does.
//
// - Steam account: SteamAccountSettings (AccountView.swift).
// - Graphics: what every game launches with unless its Game options change
//   it (LaunchSettingsStore.global): resolution, frame rate limit and
//   Direct3D, changed with left and right, each "Default · X" while it follows
//   Playport's default; and the Metal HUD.
// - Downloads: PlayportKit DownloadPreferences (the download queue reads
//   them) and Steam Cloud's switch (SteamAccountModel.cloudKey).
// - Controllers: every controller connected, with its battery (PadRouter).
// - Storage: free space and each game's size; A opens the game's page.
// - Setup check: JIT, LocalDevVPN and memory (SetupCheckSettings.swift).
// - About: the build, the copyright and the licences (LicencesView.swift),
//   whose pages show in its place; B on one of their rows goes back a page.
// - Developer, dev builds only (Dev/DeveloperSettings.swift, decision 0009).

import Combine
import HostIOKit
import PlayportKit
import SwiftUI
import UniformTypeIdentifiers
import WineHost

extension SettingsSection {
    /// The list entry's focus item.
    var navItem: String { "set:nav:" + rawValue }

    static func isNavItem(_ id: String) -> Bool { id.hasPrefix("set:nav:") }

    /// The sections this build shows.
    static var shown: [SettingsSection] {
        #if PLAYPORT_RELEASE
        all(developer: false)
        #else
        all(developer: true)
        #endif
    }
}

struct SettingsView: View {
    @ObservedObject private var navigation = AppNavigation.shared
    @ObservedObject private var focus = PadFocus.shared
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            sidebar.frame(width: 190)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 44).padding(.top, 12)
        // The height the shell offers, from the top: a sidebar a few points taller must
        // not push the shell's footer off its place.
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .task(id: navigation.pageSection) {
            // A dev build's `open:settings#SECTION`.
            guard navigation.settings, let name = navigation.pageSection else { return }
            if let s = SettingsSection.named(name), SettingsSection.shown.contains(s) {
                navigation.settingsSection = s
                try? await Task.sleep(for: .milliseconds(200))
                focus.ring(s.navItem)
            }
            navigation.pageSection = nil
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings").font(PP.display(26)).foregroundStyle(PP.text)
                .padding(.horizontal, 14).padding(.bottom, 10)
            ForEach(SettingsSection.shown, id: \.self) { s in
                let on = navigation.settingsSection == s
                Text(s.title)
                    .font(.system(size: 15, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? PP.background : PP.soft)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 37, alignment: .leading)
                    .background(on ? PP.text : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .padItem(s.navItem, hint: "Open", cornerRadius: 10) {
                        navigation.settingsSection = s
                        SettingsRing.enter()
                    }
            }
            Spacer(minLength: 0)
        }
    }

    private var content: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        section(navigation.settingsSection)
                    }
                    // Room for the ring, 6 pt outside a row, which the scroll view would clip.
                    .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 20)
                }
                .padding(.horizontal, -8)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                    scrollOffset = offset
                }
                // Another section starts at its top, however it was picked (touch or pad).
                .onChange(of: navigation.settingsSection) { scrollPosition.scrollTo(edge: .top) }
                .onChange(of: focus.focused) { _, id in
                    guard let id, id.hasPrefix("set:") else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        if SettingsSection.isNavItem(id) { proxy.scrollTo("set:top", anchor: .top) }
                        else if id.hasPrefix("set:lic") { scrollLicence(id, in: viewport.frame(in: .global)) }
                        else { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .task(id: navigation.licences) {
                    // A restored row may be offscreen. Its focus changes before the
                    // replacement page is laid out; scroll again once it is mounted,
                    // as the section-opening task above waits for its sidebar row.
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    guard let id = focus.focused, id.hasPrefix("set:lic") else { return }
                    scrollLicence(id, in: viewport.frame(in: .global))
                }
            }
        }
    }

    private func scrollLicence(_ id: String, in viewport: CGRect) {
        guard let frame = focus.items[id]?.frame else { return }
        // The focus geometry is the actual row, unlike a nested ForEach's
        // ScrollViewReader anchor (which can cover the whole licences page).
        scrollPosition.scrollTo(y: max(0, scrollOffset + frame.midY - viewport.midY))
    }

    @ViewBuilder
    private func section(_ s: SettingsSection) -> some View {
        Color.clear.frame(height: 0).id("set:top")
        switch s {
        case .steam: SteamAccountSettings()
        case .graphics: GraphicsSettings()
        case .downloads: DownloadSettings()
        case .controllers: ControllerSettings()
        case .storage: StorageSettings()
        case .setup: SetupCheckSettings()
        case .about:
            if let page = navigation.licences.last { LicencePageView(page: page) } else { AboutSettings() }
        case .developer:
            #if PLAYPORT_RELEASE
            EmptyView()
            #else
            DeveloperSettings()
            #endif
        }
    }
}

/// The ring inside Settings (AppShell sends its presses here): the list's entries
/// and the shown section's rows, kept apart so up and down in a section never
/// land on the list, and left from a row comes back to the section's entry.
@MainActor
enum SettingsRing {
    /// Handles a press in Settings; false leaves it to the shell's footer.
    static func press(_ b: NavButton) -> Bool {
        let focus = PadFocus.shared
        let nav = AppNavigation.shared
        let ringed = focus.focused ?? ""
        let onList = SettingsSection.isNavItem(ringed) || focus.items[ringed] == nil
        switch b {
        case .up, .down:
            if onList {
                let s = nav.settingsSection.step(b == .up ? -1 : 1, developer: SettingsSection.shown.contains(.developer))
                nav.settingsSection = s
                focus.ring(s.navItem)
            } else {
                focus.move(b == .up ? .up : .down, within: isRow)
            }
        case .right:
            if onList { enter() } else { focus.move(.right, within: isRow) }
        case .left:
            if onList { return true }
            if focus.items[ringed]?.adjustable == true { focus.move(.left) } else { focus.ring(nav.settingsSection.navItem) }
        case .b:
            if onList { _ = nav.back() } else if !nav.licences.isEmpty { nav.closeLicence() } else { focus.ring(nav.settingsSection.navItem) }
        default:
            return false
        }
        return true
    }

    /// Into the shown section: its top row.
    static func enter() {
        let focus = PadFocus.shared
        let rows = focus.items.filter { isRow($0.key) }.mapValues(\.frame)
        if let top = FocusMove.first(among: rows) { focus.ring(top) }
    }

    private static func isRow(_ id: String) -> Bool { id.hasPrefix("set:") && !SettingsSection.isNavItem(id) }

    /// What B does here, for the footer.
    static var backLabel: String {
        if SettingsSection.isNavItem(PadFocus.shared.focused ?? "set:nav:") { return "Back" }
        return AppNavigation.shared.licences.isEmpty ? "Sections" : "Back"
    }
}

/// Asks the shell (AppShell) for the Files picker: Setup check's pairing file import, the checklist's step.
@MainActor
enum SettingsImport {
    static let requests = PassthroughSubject<Void, Never>()
}

// MARK: shared pieces

/// The grey line over a section's rows (SettingsGraphics.dc.html).
struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(PP.muted).lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2).padding(.top, 12).padding(.bottom, 2)
    }
}

/// A row that shows a fact: on the ring, A does nothing.
struct SettingsInfoRow: View {
    let id: String
    let title: String
    var subtitle: String?
    var value: String?

    var body: some View {
        PadRow(id: "set:" + id, title: title, subtitle: subtitle, value: value, hint: "") {}
    }
}

/// A switch row bound to a UserDefaults Bool.
struct SettingsSwitchRow: View {
    let id: String
    let title: String
    var subtitle: String?
    @Binding var on: Bool

    var body: some View {
        PadRow(id: "set:" + id, title: title, subtitle: subtitle, accessory: .toggle(on), hint: "Change") { on.toggle() }
    }
}

// MARK: Graphics

private struct GraphicsSettings: View {
    @ObservedObject private var launchSettings = LaunchSettingsStore.shared
    @AppStorage(MetalHUD.key) private var metalHUD = false

    var body: some View {
        SettingsNote(text: "What every game uses unless you change it on the game's page.")
        let global = $launchSettings.global
        // Left is lower, right higher: 540p … Native; 30 fps … Off.
        let screens = SettingSteps(values: LaunchSettingsText.screens.reversed(), defaultValue: LaunchSettings.defaultScreen)
        valueRow("screen", "Resolution", "Higher is sharper, lower saves battery", screens,
                 name: { LaunchSettingsText.screen($0, pixels: false) }, value: global.screen)
        let limits = SettingSteps(values: LaunchSettingsText.frameLimits + [0], defaultValue: LaunchSettings.defaultFrameLimit)
        valueRow("frameLimit", "Frame rate limit", "Lower saves battery and heat", limits,
                 name: LaunchSettingsText.frameLimit, value: global.frameLimit)
        let backends = SettingSteps(values: GraphicsBackend.allCases.filter { Manifest.has($0) || $0 == launchSettings.global.graphics },
                                    defaultValue: GraphicsBackend.default)
        valueRow("graphics", "Direct3D", "Vulkan is experimental", backends,
                 name: LaunchSettingsText.graphics, value: global.graphics)
        SettingsSwitchRow(id: "metalHUD", title: "Metal HUD", subtitle: "Frame rate, frame time and memory over a game",
                          on: $metalHUD)
        SettingsNote(text: "From each game's next start. 720p at 60 fps keeps the phone cool enough to hold its "
                     + "frame rate; Native is the screen's full resolution, and Off runs a game as fast as the screen "
                     + "allows. " + LaunchSettingsText.graphicsFooter)
    }

    private func valueRow<T: Equatable & Sendable>(_ id: String, _ title: String, _ subtitle: String, _ steps: SettingSteps<T>,
                                                   name: @escaping (T) -> String, value: Binding<T?>) -> some View {
        PadValueRow(id: "set:" + id, title: title, subtitle: subtitle, values: steps.labels(name),
                    index: steps.index(of: value.wrappedValue)) { value.wrappedValue = steps.stored(at: $0) }
    }
}

// MARK: Downloads

private struct DownloadSettings: View {
    @AppStorage(DownloadPreferences.autoUpdateKey) private var autoUpdate = true
    @AppStorage(DownloadPreferences.cellularKey) private var cellular = false
    @AppStorage(DownloadPreferences.dimKey) private var dim = true
    @AppStorage(SteamAccountModel.cloudKey) private var steamCloud = true
    @ObservedObject private var network = NetworkPath.shared

    var body: some View {
        Color.clear.frame(height: 42)
        SettingsSwitchRow(id: "autoUpdate", title: "Update games by themselves",
                          subtitle: "Queued when Steam has a new version", on: $autoUpdate)
        SettingsSwitchRow(id: "cellular", title: "Download over cellular",
                          subtitle: "Wi-Fi only when off · " + network.summary, on: $cellular)
        SettingsSwitchRow(id: "dim", title: "Dim the screen while downloading",
                          subtitle: "After a minute without input", on: $dim)
        SettingsSwitchRow(id: "steamCloud", title: "Sync saves with Steam Cloud",
                          subtitle: "For every game that supports it", on: $steamCloud)
        SettingsNote(text: "A game's saves come from Steam Cloud when its page opens, and go back after a play. "
                     + "A game's options can turn Steam Cloud off for that game alone.")
    }
}

// MARK: Controllers

private struct ControllerSettings: View {
    @ObservedObject private var router = PadRouter.shared

    var body: some View {
        SettingsNote(text: "Connect a controller in iOS Settings › Bluetooth. Playport and its games use the one you "
                     + "pressed last.")
        if router.controllers.isEmpty {
            SettingsInfoRow(id: "controller:none", title: "No controller", subtitle: "Touch works everywhere meanwhile")
        }
        ForEach(Array(router.controllers.enumerated()), id: \.offset) { i, c in
            SettingsInfoRow(id: "controller:\(i)", title: c.name, subtitle: i == 0 ? "In use" : nil, value: battery(c))
        }
        Color.clear.frame(height: 0).onAppear { router.refreshControllers() }
    }

    private func battery(_ c: PadRouter.Controller) -> String {
        guard let b = c.battery else { return c.charging ? "Charging" : "Battery not reported" }
        return "Battery \(b)%" + (c.charging ? ", charging" : "")
    }
}

// MARK: Storage

private struct StorageSettings: View {
    @ObservedObject private var library = LibraryModel.shared

    var body: some View {
        SettingsNote(text: "Games and their saves live inside Playport. Deleting the app deletes them.")
        SettingsInfoRow(id: "free", title: "Free on this phone", value: library.freeBytes.map(ByteCount.format) ?? "Unknown")
        let used = library.catalog.titles.compactMap(\.sizeBytes).reduce(0, +)
        SettingsInfoRow(id: "games", title: "Games", subtitle: "\(library.catalog.titles.count) installed",
                        value: ByteCount.format(used))
        ForEach(library.catalog.titles.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }) { t in
            PadRow(id: "set:title:\(t.id)", title: t.name, value: t.sizeBytes.map(ByteCount.format) ?? "Unknown",
                   accessory: .chevron, hint: "Open") {
                AppNavigation.shared.openTitle(t.id)
            }
        }
        // FEX's disk cache (decision 0056): its size, and the one way to clear it (decision 0012).
        PadRow(id: "set:emulator-cache", title: "Emulator cache",
               subtitle: "Speeds up later starts; cleared past 5 GB or when space is low",
               value: cacheBytes.map(ByteCount.format) ?? "…", hint: launch.running ? "" : "Clear") {
            guard !launch.running, !clearing else { return }
            clearing = true
            Task {
                cacheBytes = await Task.detached(priority: .userInitiated) { () -> UInt64 in
                    EmulatorCache.clear()
                    return EmulatorCache.size()
                }.value
                clearing = false
            }
        }
        .task { cacheBytes = await Task.detached(priority: .utility) { EmulatorCache.size() }.value }
    }

    @ObservedObject private var launch = TitleLaunch.shared
    @State private var cacheBytes: UInt64?
    @State private var clearing = false
}

// MARK: About

private struct AboutSettings: View {
    var body: some View {
        SettingsNote(text: "Playport runs Windows games on this iPhone. It is built on willfaust/Madeira: "
                     + "Wine, FEX-Emu and DXMT in one process.")
        SettingsInfoRow(id: "version", title: "Version", value: version)
        #if PLAYPORT_RELEASE
        SettingsInfoRow(id: "variant", title: "Build", value: "Release")
        #else
        SettingsInfoRow(id: "variant", title: "Build", value: "Development")
        #endif
        SettingsInfoRow(id: "abi", title: "Runtime interface", value: "wine_host ABI \(wine_host_abi_version())")
        PadRow(id: LicencePage.list.row, title: "Licences", subtitle: "GPL-3.0-or-later, and each component's own",
               accessory: .chevron, hint: "Open") {
            AppNavigation.shared.openLicence(.list)
        }
        SettingsNote(text: "\(BundledLicences.copyright). Playport is free software under the GNU GPL and comes "
                     + "with ABSOLUTELY NO WARRANTY.")
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        return [short, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "Unknown"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
