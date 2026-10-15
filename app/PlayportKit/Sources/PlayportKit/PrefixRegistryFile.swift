// SPDX-License-Identifier: GPL-3.0-or-later
// Registry values Playport writes into the prefix for a store, as the store's client would on
// Windows: Steam's install-script `Registry` entries and the HasRunKey it writes after a
// prerequisite ran (decision 0081). They go into a file beside the prefix's hives in wineserver's
// format, every section marked for top-up, which the runtime merges into the hive before its
// wineserver starts (wine_host.c seed_registry, app/Sources/WineHost/prefix_registry.c): a key or
// value the hive lacks is added; one it holds is never changed. A value written during a session
// (a HasRunKey after its installer) reaches the hive at the next start of the runtime.

import Foundation

public struct PrefixRegistryValue: Equatable, Sendable {
    public enum Hive: String, Sendable { case system, user }
    public enum Data: Equatable, Sendable {
        case string(String)
        case dword(UInt32)
    }

    public var hive: Hive
    /// Inside the hive, backslash-separated (`Software\Valve\Steam`).
    public var key: String
    /// Empty for the key's default value.
    public var name: String
    public var data: Data

    public init(hive: Hive, key: String, name: String, data: Data) {
        self.hive = hive
        self.key = key
        self.name = name
        self.data = data
    }

    /// A value under a Windows key path (`HKEY_LOCAL_MACHINE\Software\...`, `HKLM\...`, HKCU's
    /// forms); nil for another root or an empty path. A trailing backslash is dropped.
    public init?(windowsKey: String, name: String, data: Data) {
        let parts = windowsKey.split(separator: "\\").map(String.init)
        guard let root = parts.first?.uppercased(), parts.count > 1 else { return nil }
        switch root {
        case "HKEY_LOCAL_MACHINE", "HKLM": hive = .system
        case "HKEY_CURRENT_USER", "HKCU": hive = .user
        default: return nil
        }
        key = parts.dropFirst().joined(separator: "\\")
        self.name = name
        self.data = data
    }
}

public struct PrefixRegistryFile: Sendable {
    public let prefix: URL

    public init(prefix: URL) {
        self.prefix = prefix
    }

    /// The marker app/tools/prefix-registry.py writes before a section to top up (prefix_registry.c).
    static let marker = ";; playport:top-up"

    /// The file for a hive (wine_host.c reads the same names).
    public func url(_ hive: PrefixRegistryValue.Hive) -> URL {
        prefix.appendingPathComponent("playport-registry-\(hive.rawValue).reg")
    }

    /// Adds the values to their hives' files, a value of the same key and name replaced.
    public func add(_ values: [PrefixRegistryValue]) throws {
        for hive in [PrefixRegistryValue.Hive.system, .user] {
            let mine = values.filter { $0.hive == hive }
            guard !mine.isEmpty else { continue }
            var all = Self.parse((try? String(contentsOf: url(hive), encoding: .utf8)) ?? "", hive: hive)
            for v in mine {
                all.removeAll { $0.key.lowercased() == v.key.lowercased() && $0.name.lowercased() == v.name.lowercased() }
                all.append(v)
            }
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
            try Data(Self.render(all).utf8).write(to: url(hive), options: .atomic)
        }
    }

    /// The values in a file this type wrote, in order.
    public func values(_ hive: PrefixRegistryValue.Hive) -> [PrefixRegistryValue] {
        Self.parse((try? String(contentsOf: url(hive), encoding: .utf8)) ?? "", hive: hive)
    }

    /// Wineserver's text: one marked section per key, keys in first-seen order.
    static func render(_ values: [PrefixRegistryValue]) -> String {
        var order: [String] = [], byKey: [String: (String, [PrefixRegistryValue])] = [:]
        for v in values {
            let k = v.key.lowercased()
            if byKey[k] == nil {
                order.append(k)
                byKey[k] = (v.key, [])
            }
            byKey[k]!.1.append(v)
        }
        var out = ""
        for k in order {
            let (key, vs) = byKey[k]!
            out += "\(marker)\n[\(escape(key, "[]"))]\n"
            for v in vs {
                out += v.name.isEmpty ? "@=" : "\"\(escape(v.name, "\"\""))\"="
                switch v.data {
                case .string(let s): out += "\"\(escape(s, "\"\""))\"\n"
                case .dword(let d): out += String(format: "dword:%08x\n", d)
                }
            }
            out += "\n"
        }
        return out
    }

    static func parse(_ text: String, hive: PrefixRegistryValue.Hive) -> [PrefixRegistryValue] {
        var out: [PrefixRegistryValue] = [], key: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("[") {
                key = line.hasSuffix("]") ? unescape(String(line.dropFirst().dropLast())) : nil
                continue
            }
            guard let key, let eq = valueSeparator(line) else { continue }
            let rawName = String(line[..<eq]), rawData = String(line[line.index(after: eq)...])
            let name = rawName == "@" ? "" : unescape(String(rawName.dropFirst().dropLast()))
            if rawData.hasPrefix("dword:"), let d = UInt32(rawData.dropFirst(6), radix: 16) {
                out.append(PrefixRegistryValue(hive: hive, key: key, name: name, data: .dword(d)))
            } else if rawData.hasPrefix("\""), rawData.hasSuffix("\""), rawData.count >= 2 {
                out.append(PrefixRegistryValue(hive: hive, key: key, name: name, data: .string(unescape(String(rawData.dropFirst().dropLast())))))
            }
        }
        return out
    }

    /// The `=` after a value's name (`@` or a quoted name).
    static func valueSeparator(_ line: String) -> String.Index? {
        if line.hasPrefix("@=") { return line.index(after: line.startIndex) }
        guard line.hasPrefix("\"") else { return nil }
        var i = line.index(after: line.startIndex), escaped = false
        while i < line.endIndex {
            let c = line[i]
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" {
                let next = line.index(after: i)
                return next < line.endIndex && line[next] == "=" ? next : nil
            }
            i = line.index(after: i)
        }
        return nil
    }

    /// Wineserver's dump_strW: a backslash and the two escape characters get a backslash,
    /// a control character octal, anything past ASCII `\x` and four hex digits.
    static func escape(_ s: String, _ chars: String) -> String {
        var out = ""
        for u in s.utf16 {
            if u > 127 {
                out += String(format: "\\x%04x", u)
            } else if u < 32 {
                out += String(format: "\\%03o", u)
            } else {
                let c = Character(UnicodeScalar(UInt8(u)))
                if c == "\\" || chars.contains(c) { out.append("\\") }
                out.append(c)
            }
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        var units: [UInt16] = [], it = Array(s.utf16), i = 0
        while i < it.count {
            guard it[i] == 0x5C, i + 1 < it.count else {
                units.append(it[i])
                i += 1
                continue
            }
            let c = it[i + 1]
            if c == 0x78 {   // \x and up to four hex digits
                var j = i + 2, v: UInt16 = 0
                while j < it.count, j < i + 6, let h = Character(UnicodeScalar(it[j]) ?? " ").hexDigitValue {
                    v = v * 16 + UInt16(h)
                    j += 1
                }
                units.append(v)
                i = j
            } else if c >= 0x30, c <= 0x37 {   // octal
                var j = i + 1, v: UInt16 = 0
                while j < it.count, j < i + 4, it[j] >= 0x30, it[j] <= 0x37 {
                    v = v * 8 + (it[j] - 0x30)
                    j += 1
                }
                units.append(v)
                i = j
            } else {
                let map: [UInt16: UInt16] = [0x6E: 0x0A, 0x72: 0x0D, 0x74: 0x09, 0x61: 0x07, 0x62: 0x08, 0x76: 0x0B, 0x66: 0x0C, 0x65: 0x1B]
                units.append(map[c] ?? c)
                i += 2
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// A string value (REG_SZ) in a hive's text, as `dword(inHive:)` reads one.
    public static func string(inHive text: String, key: String, name: String) -> String? {
        let header = "[" + escape(key, "[]").lowercased() + "]"
        let prefix = (name.isEmpty ? "@" : "\"" + escape(name, "\"\"") + "\"").lowercased() + "=\""
        var inKey = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("[") {
                inKey = line.lowercased().hasPrefix(header)
                continue
            }
            guard inKey, line.lowercased().hasPrefix(prefix), line.hasSuffix("\"") else { continue }
            let data = line.dropFirst(prefix.count).dropLast()
            return unescape(String(data))
        }
        return nil
    }

    /// A DWORD value in a hive's text (system.reg or user.reg as wineserver saves it, the
    /// runtime stopped): any section of the key holding a `dword:` value of that name.
    public static func dword(inHive text: String, key: String, name: String) -> UInt32? {
        let header = "[" + escape(key, "[]").lowercased() + "]"
        let prefix = (name.isEmpty ? "@" : "\"" + escape(name, "\"\"") + "\"").lowercased() + "=dword:"
        var inKey = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("[") {
                inKey = line.lowercased().hasPrefix(header)
                continue
            }
            guard inKey else { continue }
            let l = line.lowercased()
            if l.hasPrefix(prefix) { return UInt32(l.dropFirst(prefix.count).prefix(8), radix: 16) }
        }
        return nil
    }
}
