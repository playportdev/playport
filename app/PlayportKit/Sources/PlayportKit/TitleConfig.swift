// SPDX-License-Identifier: GPL-3.0-or-later
// Per-title runtime switches without touching the shared file. The runtime
// reads one madeira.cfg (Madeira build/madeira_cfg.h) from $MADEIRA_DOCS_DIR,
// else $HOME/Documents, which wine_host makes the prefix's Documents. A title
// whose cohort entry has `config` keys launches with
// MADEIRA_DOCS_DIR pointed at its own directory, whose madeira.cfg is the
// shared file followed by the title's keys: the reader takes the last line
// for a key, so the title's keys win and every other shared key still holds.
// The file is rewritten at every launch, so edits to the shared file carry
// over. That directory also receives what the runtime writes to
// MADEIRA_DOCS_DIR (madeira-retire-trace.txt; fex-jit-dump.bin only with
// Settings › Developer's JIT pool dump on, PLA-555). With no
// shared madeira.cfg the legacy madeira-<key>.txt files are not consulted
// for such a launch, since a madeira.cfg is then present.

import Foundation

public enum TitleConfig {
    public static let fileName = "madeira.cfg"
    /// Under the prefix's Documents: `title-cfg/<install folder>/madeira.cfg`.
    public static let rootName = "title-cfg"

    /// Keys no title may set (decision 0183): the memory plan's guest RAM and video figure are no
    /// game's own, every game takes its plan row's (MemoryPlan), so neither its madeira.cfg keys
    /// (`totalphys`, `vram-mb`, `vulkan-vram-plan`) nor its variables are a title's; the Social
    /// Club layout follows a verified Rockstar bootstrap (SocialClubBootstrap), never a key; and
    /// every Play gets the one JIT pool (JitPool.sizeMB, decision 0184), so `jitPoolMB` is no
    /// title's either. Refused here, so no cohort entry, compatibility entry, launcher, everyGame
    /// default, dev Runtime keys row or driven launch sets one. The shared madeira.cfg is the
    /// person's for every game alike and is not checked.
    public static let refusedKeys = Set([MemoryPlan.guestRAMKey, MemoryPlan.videoKey, MemoryPlan.vulkanKey, JitPool.titleKey]
        + [MemoryPlan.guestRAMVariable, MemoryPlan.videoVariable, MemoryPlan.vulkanHeapVariable,
           MemoryPlan.vulkanBudgetVariable, SocialClubBootstrap.layoutVariable].map { "env." + $0 })

    /// Memory keys whose mechanisms are gone (decision 0183): validate refuses them, so no cohort
    /// entry, compatibility entry, dev build's Runtime keys row or driven launch sets one again.
    public static let deletedKeys: Set<String> = ["jumbo-mb", "jumbo-keep-mb", "cage-hold", "short-reserve-mb"]

    /// Keys are the reader's names (`inproc-sync`, `env.NAME`); values are one line; no refused or
    /// deleted key. The keys are checked in order, so the error names the first.
    public static func validate(_ config: [String: String]) throws {
        let keyChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        for k in config.keys.sorted() {
            let v = config[k]!
            guard !k.isEmpty, k.unicodeScalars.allSatisfy({ keyChars.contains($0) && $0.isASCII }),
                  !v.contains(where: { $0 == "\n" || $0 == "\r" })
            else { throw LaunchPlanError.badConfig("\(k) = \(v)") }
            if refusedKeys.contains(k) { throw LaunchPlanError.refusedKey(k) }
            if deletedKeys.contains(k) { throw LaunchPlanError.deletedKey(k) }
        }
    }

    /// The shared file's text, then the title's keys in key order.
    public static func merged(shared: String?, config: [String: String], title: String) -> String {
        var out = shared ?? ""
        if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        out += "# Playport: \(title)'s own keys, after the shared file; the last line for a key wins.\n"
        for k in config.keys.sorted() { out += "\(k) = \(config[k]!)\n" }
        return out
    }

    /// The directory name for a launch: the install folder of a
    /// `Games\<folder>\...` DOS path (drive letter optional, `/` or `\`),
    /// else the executable's name, with anything but letters, digits,
    /// space, `.`, `_` and `-` replaced by `_`.
    public static func directoryName(exe: String) -> String {
        var parts = exe.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        if parts.first?.count == 2, parts.first?.last == ":" { parts.removeFirst() }
        let pick = parts.count >= 3 && parts[0].lowercased() == "games" ? parts[1] : (parts.last ?? "title")
        let name = String(pick.map { $0.isLetter || $0.isNumber || " ._-".contains($0) ? $0 : "_" })
        return name.isEmpty || name.allSatisfy({ $0 == "." }) ? "title" : name
    }

    /// Writes `<documents>/title-cfg/<name>/madeira.cfg` from `<shared>/madeira.cfg`
    /// (absent: empty) and the title's keys; returns the directory for MADEIRA_DOCS_DIR.
    @discardableResult
    public static func prepare(shared: URL, documents: URL, exe: String, config: [String: String],
                               title: String) throws -> URL {
        try validate(config)
        let dir = documents.appendingPathComponent(rootName, isDirectory: true)
            .appendingPathComponent(directoryName(exe: exe), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = (try? Data(contentsOf: shared.appendingPathComponent(fileName)))
            .map { String(decoding: $0, as: UTF8.self) }
        try Data(merged(shared: text, config: config, title: title).utf8)
            .write(to: dir.appendingPathComponent(fileName), options: .atomic)
        return dir
    }

    /// A driven launch's TITLE_CFG: comma-separated `key=value` items, each
    /// percent-decoded (%2C comma, %20 space, %25 percent); nil when malformed.
    public static func parse(_ raw: String?) -> [String: String]? {
        guard let raw, !raw.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for item in raw.split(separator: ",") {
            guard let eq = item.firstIndex(of: "="),
                  let k = String(item[..<eq]).removingPercentEncoding?.trimmingCharacters(in: .whitespaces),
                  let v = String(item[item.index(after: eq)...]).removingPercentEncoding?.trimmingCharacters(in: .whitespaces)
            else { return nil }
            out[k] = v
        }
        return (try? validate(out)) == nil ? nil : out
    }
}
