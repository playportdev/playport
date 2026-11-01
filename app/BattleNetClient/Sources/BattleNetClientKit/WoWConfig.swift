// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit

/// World of Warcraft's own settings file, `<product folder>/WTF/Config.wtf`: lines of
/// `SET name "value"`, names in any case. Playport writes the few values a phone launch needs
/// and keeps every other line (docs/evidence/2026-10-30-wow-desktop-baseline.md).
public enum WoWConfig {
    /// Before Play: the install's text and voice locales and its region's portal where the file
    /// names none (without them WoW opens a Win32 language and region box before its login),
    /// `GamePadEnable` on where the file names none (WoW's default is off, and then it looks for
    /// no controller at all; a line already there keeps its value), `HardwareCursor` off where
    /// the file names none (WoW then draws its cursor into its frames: the phone draws no Windows
    /// cursor over a game, and at the login and character select a controller moves that cursor
    /// with the right stick and clicks with A; docs/evidence/2026-11-01-wow-controller.md), and
    /// `GxApi` pinned to Direct3D 12 (after one failed Direct3D 12 start WoW saves Direct3D 11, and
    /// Play starts the x64 client for Direct3D 12 through vkd3d-proton, decision 0177), and for
    /// retail `playIntroMovie` where the file names none: the client records the intro cinematic as
    /// seen only in the settings it saves on a clean exit, which a phone launch rarely has, so the
    /// cinematic (about 265 s on the phone, before the login screen; runs 20261101T195434 and
    /// 200342) played on every Play; 14 is the value 12.1.5 saves after it. The file
    /// and its folder are made when missing.
    public static func prepareForPlay(_ product: BattleNetProduct, root: URL) throws {
        let info = try BuildInfo.read([UInt8](try Data(contentsOf: root.appendingPathComponent(".build.info"))), product: product.code)
        guard let wtf = file(product, root: root) else { throw BattleNetError.damaged("\(product.code): no product folder names it") }
        let old = (try? String(contentsOf: wtf, encoding: .utf8)) ?? ""
        var text = old
        if let locale = info.locale {
            text = set(text, [("textLocale", locale), ("audioLocale", locale)], replacing: false)
        }
        text = set(text, [("portal", info.region.tag), ("GamePadEnable", "1"), ("HardwareCursor", "0")], replacing: false)
        if product == .wow {
            text = set(text, [("playIntroMovie", introMovieSeen)], replacing: false)
        }
        text = set(text, [("GxApi", "D3D12")], replacing: true)
        guard text != old else { return }
        try InstallFS.makeDirectory(wtf.deletingLastPathComponent())
        try InstallFS.writeAtomically(wtf, Data(text.utf8))
    }

    /// The `playIntroMovie` retail 12.1.5 (70688) saves once its intro cinematic has played: the
    /// login screen follows with no cinematic (docs/evidence/2026-10-30-wow-desktop-baseline.md).
    static let introMovieSeen = "14"

    /// The settings file of the install at `root`: in the product folder whose `.flavor.info`
    /// names `product` (the installer writes it); nil when none does.
    public static func file(_ product: BattleNetProduct, root: URL) -> URL? {
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(atPath: root.path))?.sorted() ?? [] {
            let flavor = root.appendingPathComponent(folder).appendingPathComponent(".flavor.info")
            guard let text = try? String(contentsOf: flavor, encoding: .utf8),
                  text.split(whereSeparator: \.isNewline).dropFirst().contains(where: { $0 == product.code }) else { continue }
            return root.appendingPathComponent(folder).appendingPathComponent("WTF/Config.wtf")
        }
        return nil
    }

    /// The settings with the text and voice locales set to `locale`.
    static func locale(_ text: String, _ locale: String) -> String {
        set(text, [("textLocale", locale), ("audioLocale", locale)], replacing: true)
    }

    /// The settings with the portal (the region WoW signs in to) set to `region`'s.
    static func portal(_ text: String, _ region: StoreRegion) -> String {
        set(text, [("portal", region.tag)], replacing: true)
    }

    /// `text` with each value set: a line naming it is replaced (or, unless `replacing`, kept),
    /// a missing one added at the end, in the file's own line ending; every other line stays.
    static func set(_ text: String, _ values: [(name: String, value: String)], replacing: Bool) -> String {
        let ending = text.contains("\r\n") ? "\r" : ""
        // By the byte: "\r\n" is one Character, which a split on the Character "\n" passes over.
        var lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if lines.last == "" { lines.removeLast() }
        for (name, value) in values {
            if let i = lines.firstIndex(where: { names($0, name) }) {
                guard replacing else { continue }
                let spelled = lines[i].split(separator: " ", maxSplits: 2)[1]
                lines[i] = "SET \(spelled) \"\(value)\"" + ending
            } else {
                lines.append("SET \(name) \"\(value)\"" + ending)
            }
        }
        return lines.map { $0 + "\n" }.joined()
    }

    /// Whether `line` sets `name` (`SET name …`, any case).
    static func names(_ line: String, _ name: String) -> Bool {
        let words = line.split(separator: " ", maxSplits: 2)
        return words.count >= 2 && words[0].caseInsensitiveCompare("SET") == .orderedSame
            && words[1].caseInsensitiveCompare(name) == .orderedSame
    }
}
