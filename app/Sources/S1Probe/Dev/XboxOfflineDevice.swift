// SPDX-License-Identifier: GPL-3.0-only
// Xodus Nexus e0668a12f1da931aed13537ef04295599011317b src/renderer/OfflinePermissions.tsx
// and src/main/index.ts (settleOfflinePermissions); translated to Swift by the Playport
// authors, 2026-10-30. Modified: a Settings › Accounts › Xbox row with the pad's
// confirmation; dev only (decision 0166).
import ContentKit
import Foundation
import SwiftUI
import XboxClientKit

/// Settings › Accounts › Xbox's Offline device (PLA-504): off by default; turning it
/// on or off is Microsoft's change, after a confirmation that names the one-device
/// limit and that this phone replaces the current one.
@MainActor
final class XboxOfflineDeviceModel: ObservableObject {
    static let shared = XboxOfflineDeviceModel()
    @Published private(set) var isOn = false
    @Published private(set) var status: XboxOfflineDevice?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private var session: XboxSession { XboxAccount.shared.session }

    /// The stored setting, then Microsoft's answer.
    func load() async {
        isOn = await session.isOfflineDevice
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { settle(try await session.offlineDevice(), changed: false); error = nil }
        catch { self.error = Self.message(error) }
    }

    /// After an online licence on the offline device: Microsoft may have named another one.
    func check() {
        Task {
            guard await session.isOfflineDevice, !busy else { return }
            if let status = try? await session.offlineDevice() { settle(status, changed: false) }
        }
    }

    /// The row's action: the confirmation, then Microsoft's change.
    func toggle() {
        guard !busy else { return }
        let turningOn = !isOn
        let text = XboxOfflineDevice.confirmation(turningOn: turningOn, status: status)
        PadModal.shared.picker(title: text.title, context: "Settings · Accounts · Xbox", note: text.note,
                               options: [PadOption(id: "keep", label: "Cancel"), PadOption(id: "confirm", label: text.confirm)],
                               selected: "keep") { choice in
            guard choice == "confirm" else { return }
            Task { await self.set(turningOn) }
        }
    }

    func set(_ on: Bool) async {
        busy = true; defer { busy = false }
        do {
            settle(try await session.setOfflineDevice(on), changed: true)
            error = nil
        } catch let refused as XboxOfflineDeviceNotChanged {
            settle(refused.status, changed: false)
            error = refused.description
        } catch { self.error = Self.message(error) }
    }

    /// A change, or Microsoft saying another device took over, ends the runtime's
    /// cached identity too: offline sign-in ends with offline licensing.
    private func settle(_ status: XboxOfflineDevice, changed: Bool) {
        self.status = status
        isOn = status.isThisDevice
        if changed || !status.isThisDevice { Self.removeIdentities() }
    }

    static func removeIdentities() {
        do {
            let removed = try XboxOfflineIdentity.remove(prefix: WineHostRuntime.shared.prefixURL)
            if removed > 0 { AppLog.append("xbox: offline identity caches removed (\(removed))") }
        } catch { AppLog.append("xbox: offline identity caches not removed (\(error))") }
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? XboxSessionError { return error.description }
        if case ClientError.transport = error { return "Microsoft couldn't be reached. Connect to the internet to change the offline device." }
        if let error = error as? ClientError { return error.description }
        return "Microsoft couldn't be reached. Try again."
    }

    /// The row's subtitle: what the setting does, the changes left, or why it failed.
    var subtitle: String {
        if let error { return error }
        if busy { return "Asking Microsoft…" }
        let left = status?.changesLeft.map { " \($0) change(s) left this year." } ?? ""
        return isOn
            ? "This phone is your Xbox offline device: games played online once start without a connection for up to 30 days.\(left)"
            : "Off. Games need a connection to start. One offline device per Xbox account.\(left)"
    }
}

struct XboxOfflineDeviceSettings: View {
    @ObservedObject private var model = XboxOfflineDeviceModel.shared
    var body: some View {
        PadRow(id: "set:xbox:offline", title: "Offline device", subtitle: model.subtitle, subtitleLines: 3,
               accessory: .toggle(model.isOn), hint: model.isOn ? "Turn off" : "Turn on") { model.toggle() }
            .task { await model.load() }
    }
}
