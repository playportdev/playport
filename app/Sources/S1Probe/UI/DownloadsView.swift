// SPDX-License-Identifier: GPL-3.0-or-later
// Downloads (docs/design/2026-09-28-gamepad-ui/Downloads.dc.html): the job
// that runs first, with its speed and time left, then Up next in the order
// they start (SteamInstalls, PlayportKit DownloadQueue); at the right, While
// you wait with Dim now, and Done today. The storage bar is in the top bar
// (AppShell.swift). Every job is on the focus ring: A pauses or resumes it,
// Y ("Download next") moves it to the front, behind the one running, and X
// cancels it after a confirmation.
//
// Download mode (DownloadMode.dc.html): after a minute without input while a
// download runs, and when Settings › Downloads' dim switch is on, a black
// page with the progress covers the app and the screen's brightness goes
// down; any button or tap wakes it and puts the brightness back
// (DownloadDimmer). Dim now does the same at once.

import PlayportKit
import SteamClientKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct DownloadsPage: View {
    @ObservedObject var installs: Downloads
    @ObservedObject private var focus = PadFocus.shared

    /// `dl:job:<appID>` for a Steam job (as before), `dl:job:<title ID>` for any other.
    static func item(_ key: StoreGameKey) -> String { "dl:job:" + (key.steamAppID.map(String.init) ?? key.titleID) }

    static func key(item id: String) -> StoreGameKey? {
        guard id.hasPrefix("dl:job:") else { return nil }
        let rest = String(id.dropFirst("dl:job:".count))
        return UInt32(rest).map(StoreGameKey.steam) ?? StoreGameKey(titleID: rest)
    }
    static let dimItem = "dl:dim"

    var body: some View {
        let order = installs.order
        HStack(alignment: .top, spacing: 16) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let first = order.first {
                            FirstJobCard(job: first, installs: installs)
                        } else {
                            nothing
                        }
                        if order.count > 1 {
                            Text("Up next").font(.system(size: 11, weight: .semibold)).tracking(1.1).textCase(.uppercase)
                                .foregroundStyle(PP.muted).padding(.top, 4)
                            ForEach(order.dropFirst()) { job in
                                JobRow(job: job, installs: installs)
                            }
                        }
                    }
                    // Room for the ring, which draws outside each item.
                    .padding(6)
                }
                .padding(-6)
                .onChange(of: focus.focused) { _, id in
                    if let id, id.hasPrefix("dl:job:") { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 10) {
                whileYouWait
                doneToday
            }
            .frame(width: 240)
        }
        .padding(.top, 6)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var nothing: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing downloading").font(PP.display(22)).foregroundStyle(PP.text)
            Text("Games you install from the Library download here, one at a time. Updates queue by themselves.")
                .font(.system(size: 13)).foregroundStyle(PP.muted)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var whileYouWait: some View {
        VStack(alignment: .leading, spacing: 8) {
            SmallCaps("While you wait")
            Text("Downloads need Playport open. After a minute the screen dims to save power; plug in for big games.")
                .font(.system(size: 13)).foregroundStyle(PP.soft).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "moon.fill").font(.system(size: 11))
                Text("Dim now").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(PP.text)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PP.line, in: RoundedRectangle(cornerRadius: 8))
            .padItem(Self.dimItem, hint: "Dim now", cornerRadius: 8) { DownloadDimmer.shared.dimNow() }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var doneToday: some View {
        VStack(alignment: .leading, spacing: 4) {
            SmallCaps("Done today")
            if installs.doneToday.isEmpty {
                Text("Nothing yet").font(.system(size: 13)).foregroundStyle(PP.muted)
            } else {
                ForEach(Array(installs.doneToday.prefix(4).enumerated()), id: \.offset) { _, d in
                    Text(d.line).font(.system(size: 13)).foregroundStyle(PP.soft).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: buttons

    /// The footer's Y and X for the ringed job (the shell adds A, B and ≡).
    @MainActor
    static func hints(_ installs: Downloads, focused: String?) -> [PadHint] {
        guard let id = focused, let app = key(item: id), let job = installs.jobs[app] else { return [] }
        var h: [PadHint] = []
        if app != installs.order.first?.key, !installs.suspended {
            h.append(PadHint(button: .y, label: "Download next") { installs.downloadNext(app) })
        }
        h.append(PadHint(button: .x, label: "Cancel") { confirmCancel(job, installs) })
        return h
    }

    /// A on a job: Pause, or Resume.
    @MainActor
    static func toggle(_ job: Downloads.Job, _ installs: Downloads) {
        if job.isRunning || job.phase == .queued {
            installs.pause(job.key)
        } else if !installs.suspended {
            installs.resume(job.key)
        }
    }

    static func toggleHint(_ job: Downloads.Job) -> String {
        job.isRunning || job.phase == .queued ? "Pause" : "Resume"
    }

    /// X: cancel, confirmed in a picker whose default keeps the download.
    @MainActor
    static func confirmCancel(_ job: Downloads.Job, _ installs: Downloads) {
        let what = job.kind == .repair ? "repair" : job.kind == .update ? "update" : job.kind == .import ? "import" : "download"
        let got = job.progress.map { " · deletes \(ByteCount.format($0.bytesDone))" } ?? ""
        PadModal.shared.picker(
            title: "Cancel the \(what)?", context: job.name,
            note: job.record.automatic ? "It is not queued again until Steam has a newer version." : "What was downloaded is deleted.",
            options: [PadOption(id: "keep", label: "Keep it"), PadOption(id: "cancel", label: "Cancel the \(what)" + got)],
            selected: "keep") { picked in
            if picked == "cancel" { installs.discard(job.key) }
        }
    }
}

/// The small grey capitals over a card's text.
private struct SmallCaps: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).tracking(1.1).textCase(.uppercase).foregroundStyle(PP.muted)
    }
}

/// The job that runs first: art, name and time left, the bar, what it does and its speed.
private struct FirstJobCard: View {
    let job: Downloads.Job
    @ObservedObject var installs: Downloads

    var body: some View {
        HStack(spacing: 14) {
            Color.clear.overlay { GameArt(appID: job.appID, name: job.name, kind: .header) }
                .frame(width: 120, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.name).font(PP.display(22)).foregroundStyle(PP.text).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(job.timeLeft ?? topRight).font(.system(size: 13)).foregroundStyle(PP.soft).lineLimit(1)
                }
                ProgressBar(fraction: job.fraction ?? 0, height: 8)
                HStack {
                    Text(line).lineLimit(1)
                    Spacer(minLength: 8)
                    if job.phase == .downloading, let r = job.rate { Text(DownloadRate.speed(r)).monospacedDigit() }
                }
                .font(.system(size: 12)).foregroundStyle(PP.muted)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 14))
        .padItem(DownloadsPage.item(job.key), hint: DownloadsPage.toggleHint(job), cornerRadius: 14) {
            DownloadsPage.toggle(job, installs)
        }
    }

    private var topRight: String {
        job.fraction.map { "\(Int($0 * 100))%" } ?? ""
    }

    /// `Downloading · 3.4 of 5.4 GB`, `Paused · Steam can't be reached.`
    private var line: String {
        if case let .paused(reason) = job.phase { return ["Paused", reason].compactMap { $0 }.joined(separator: " · ") }
        let what = job.phase == .downloading ? job.kind == .repair ? "Repairing" : job.kind == .update ? "Updating" : "Downloading" : job.status
        if let p = job.progress, job.phase == .downloading {
            return "\(what) · \(ByteCount.format(p.bytesDone)) of \(ByteCount.format(p.bytesTotal))"
        }
        return [what, job.record.bytes.map(ByteCount.format)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A job in Up next: art, name, what it is, and Y on the ringed one.
private struct JobRow: View {
    let job: Downloads.Job
    @ObservedObject var installs: Downloads
    @ObservedObject private var focus = PadFocus.shared

    var body: some View {
        let id = DownloadsPage.item(job.key)
        HStack(spacing: 12) {
            Color.clear.overlay { GameArt(appID: job.appID, name: job.name, kind: .header) }
                .frame(width: 64, height: 30).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(job.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(PP.text)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(PP.muted)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if focus.focused == id, !installs.suspended { PadGlyph(button: .y) }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .frame(maxWidth: .infinity)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 10))
        .padItem(id, hint: DownloadsPage.toggleHint(job), cornerRadius: 10) { DownloadsPage.toggle(job, installs) }
    }

    /// `Update · 1.2 GB · queued by itself`, `Install · 1.8 GB · Paused`
    private var subtitle: String {
        var parts = [job.kind.label]
        if let p = job.progress, p.bytesTotal > p.bytesDone {
            parts.append("\(ByteCount.format(p.bytesTotal - p.bytesDone)) left")
        } else if let b = job.record.bytes {
            parts.append(ByteCount.format(b))
        }
        if job.record.automatic { parts.append("queued by itself") }
        switch job.phase {
        case let .paused(reason): parts.append(reason ?? "Paused")
        case .queued: if let w = job.waitingFor { parts.append(w) }
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

/// The top bar's storage on Downloads: free of the phone's total, the games and the rest used.
struct StorageBar: View {
    @ObservedObject private var library = LibraryModel.shared

    var body: some View {
        let total = library.totalBytes ?? 0
        let free = library.freeBytes ?? 0
        let games = library.catalog.titles.compactMap(\.sizeBytes).reduce(0, +)
        let used = total > free ? total - free : 0
        let other = used > games ? used - games : 0
        VStack(spacing: 3) {
            HStack {
                Text("Storage")
                Spacer()
                Text(total > 0 ? "\(ByteCount.format(free)) free of \(ByteCount.format(total))" : "Unknown")
            }
            .font(.system(size: 11)).foregroundStyle(PP.muted)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(PP.progress).frame(width: part(games, total) * geo.size.width)
                    Rectangle().fill(Color(hex: 0x4A5667)).frame(width: part(other, total) * geo.size.width)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 5)
            .background(PP.line)
            .clipShape(Capsule())
        }
        .frame(width: 200)
    }

    private func part(_ bytes: UInt64, _ total: UInt64) -> CGFloat {
        total == 0 ? 0 : CGFloat(min(1, Double(bytes) / Double(total)))
    }
}

// MARK: Download mode

/// Download mode's state: when the app last had input, and the brightness to put back.
@MainActor
final class DownloadDimmer: ObservableObject {
    static let shared = DownloadDimmer()

    @Published private(set) var dimmed = false
    private var lastInput = Date()
    private var saved: CGFloat?
    private var clock: Timer?
    private weak var installs: Downloads?

    /// Once, when the product UI appears.
    func start(installs: Downloads) {
        self.installs = installs
        watchTouches()
        guard clock == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { DownloadDimmer.shared.check() }
        }
    }

    /// A button or a touch: the minute starts again.
    func input() { lastInput = Date() }

    /// Any button or tap while dimmed: the app again, at the player's brightness.
    func wake() {
        lastInput = Date()
        guard dimmed else { return }
        dimmed = false
        if let saved, let screen = Self.screen { screen.brightness = saved }
        saved = nil
        LibraryModel.log("download mode: woken")
    }

    /// Dim now (Downloads' While you wait).
    func dimNow() { dim() }

    /// Leaving the screen: the brightness goes back at once.
    func sceneLeftActive() { wake() }

    private func check() {
        guard !dimmed, UIApplication.shared.applicationState == .active, !TitleLaunch.shared.running,
              !AppRestart.shared.restarting else { return }
        watchTouches()
        if DownloadMode.shouldDim(idleFor: Date().timeIntervalSince(lastInput), downloading: installs?.isBusy == true,
                                  enabled: DownloadPreferences.current.dim) {
            dim()
        }
    }

    private func dim() {
        guard !dimmed else { return }
        dimmed = true
        if let screen = Self.screen {
            saved = screen.brightness
            screen.brightness = CGFloat(DownloadMode.dimmed(from: Double(screen.brightness)))
        }
        LibraryModel.log("download mode: dimmed")
    }

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    /// Every touch anywhere counts as input (InputWatch), without taking it from the view under it.
    private func watchTouches() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for w in scene.windows where !(w.gestureRecognizers ?? []).contains(where: { $0 is InputWatch }) {
                w.addGestureRecognizer(InputWatch())
            }
        }
    }
}

/// Sees every touch begin in its window and lets it through.
private final class InputWatch: UIGestureRecognizer {
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        MainActor.assumeIsolated { DownloadDimmer.shared.input() }
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// The black page over the app while dimmed: the running job's progress and the queue's time.
struct DownloadModeView: View {
    @ObservedObject var installs: Downloads
    @ObservedObject private var dimmer = DownloadDimmer.shared

    var body: some View {
        if dimmer.dimmed {
            ZStack {
                Color.black
                VStack(alignment: .leading, spacing: 10) {
                    if let job = installs.order.first {
                        HStack(alignment: .firstTextBaseline) {
                            Text(job.name).font(PP.display(24, .semibold)).lineLimit(1)
                            Spacer(minLength: 8)
                            if let f = job.fraction { Text("\(Int(f * 100))%").font(.system(size: 14)) }
                        }
                        .foregroundStyle(Color(hex: 0x8A94A3))
                        ProgressBar(fraction: job.fraction ?? 0, height: 4, track: Color(hex: 0x1A1F27))
                            .opacity(0.75)
                        Text(queueLine).font(.system(size: 13)).foregroundStyle(Color(hex: 0x6F7885))
                    } else {
                        Text(installs.doneToday.isEmpty ? "Nothing downloading" : "Downloads finished")
                            .font(PP.display(24, .semibold)).foregroundStyle(Color(hex: 0x8A94A3))
                    }
                }
                .frame(width: 300)
                VStack {
                    Spacer()
                    Text("Press any button or tap to wake").font(.system(size: 13)).foregroundStyle(PP.accent.opacity(0.8))
                        .padding(.bottom, 24)
                }
            }
            .ignoresSafeArea()
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .contentShape(Rectangle())
            .onTapGesture { dimmer.wake() }
        }
    }

    /// `2 more in the queue · about 9 min for all`
    private var queueLine: String {
        let order = installs.order
        let more = order.count - 1
        let rate = order.first?.rate
        let remaining = order.compactMap(\.remaining).reduce(0, +)
        let time = DownloadRate.seconds(remaining: remaining, rate: rate).map(DownloadRate.duration)
        let head = more == 0 ? "Last in the queue" : more == 1 ? "1 more in the queue" : "\(more) more in the queue"
        guard let time else { return head }
        return head + " · " + time + (more == 0 ? " left" : " for all")
    }
}
