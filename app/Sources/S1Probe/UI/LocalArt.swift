// SPDX-License-Identifier: GPL-3.0-or-later
// Tile art for a game no store draws (docs/plans/2026-10-06-pc-import-gog-epic.md, 1.6):
// the icon its executable carries (PlayportKit PEIcon), on the name's colour, or the
// name's initials when it has none. Icons are read once off the main thread and kept
// as PNGs under Caches/Playport/art/local, keyed by the title and its executable, so a
// picked executable brings its own icon.

import PlayportKit
import SteamClientKit
import SwiftUI
import UIKit

@MainActor
final class LocalArt: ObservableObject {
    static let shared = LocalArt()
    nonisolated static let directory = SteamPaths.art.appendingPathComponent("local", isDirectory: true)

    /// By cache key; NSNull-like `nil` entries are remembered as "no icon".
    @Published private var images: [String: UIImage?] = [:]
    private var loading = Set<String>()

    static func key(_ t: InstalledTitle) -> String? {
        guard let exe = t.executable else { return nil }
        let tag = SHA1.hash(Array("\(t.id)\n\(exe)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return tag
    }

    /// The icon if it is known; starts reading it otherwise.
    func icon(for t: InstalledTitle) -> UIImage? {
        guard let key = Self.key(t), let exe = t.executable else { return nil }
        if let known = images[key] { return known }
        guard loading.insert(key).inserted else { return nil }
        let exeURL = LibraryModel.paths.games.appendingPathComponent(t.installDir, isDirectory: true)
            .appendingPathComponent(exe.replacingOccurrences(of: "\\", with: "/"))
        let cached = Self.directory.appendingPathComponent(key + ".png")
        Task.detached(priority: .utility) {
            var image: UIImage?
            if let data = try? Data(contentsOf: cached) {
                image = UIImage(data: data)
            } else if let ico = PEIcon.ico(of: exeURL), let decoded = UIImage(data: ico), let png = decoded.pngData() {
                try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                try? png.write(to: cached, options: .atomic)
                image = decoded
            }
            await MainActor.run {
                LocalArt.shared.images[key] = .some(image)
                LocalArt.shared.loading.remove(key)
            }
        }
        return nil
    }
}

/// A local game's art: its icon centred on the name's colour, or its initials.
struct LocalGameArt: View {
    let title: InstalledTitle
    @ObservedObject private var art = LocalArt.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [PP.tile(for: title.name), PP.tile(for: title.name).opacity(0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let icon = art.icon(for: title) {
                    Image(uiImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(height: min(geo.size.height * 0.62, 128))
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                } else {
                    Text(Self.initials(title.name))
                        .font(PP.display(min(geo.size.height * 0.42, 72))).foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// `Hollow Knight` → `HK`; one word → its first two letters.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2 { return words.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased() }
        return String(words.first?.prefix(2) ?? "?").uppercased()
    }
}
