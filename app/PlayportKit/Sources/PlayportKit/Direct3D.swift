// SPDX-License-Identifier: GPL-3.0-or-later
// Static, best-effort renderer evidence for the selected executable, not a
// statement about the API a dual-renderer game will actually choose at runtime.
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum Direct3D {
    public enum API: Int, Codable, Sendable, CaseIterable {
        case d3d8 = 8, d3d9 = 9, d3d10 = 10, d3d11 = 11, d3d12 = 12
        public var label: String { "Direct3D \(rawValue)" }
    }

    public struct Evidence: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case libraryImport, functionImport, dynamicReference
        }
        public var api: API
        /// Relative to the title root; never a host/container path.
        public var module: String
        public var kind: Kind
        public var name: String
    }

    public struct Detection: Codable, Equatable, Sendable {
        public var evidence: [Evidence]
        public var modulesScanned: Int
        /// A size, depth or file-count budget was reached. Absence is not proof,
        /// even when this is false (packed code and runtime choices remain unknown).
        public var limited: Bool
        public var apis: [API] { Array(Set(evidence.map(\.api))).sorted { $0.rawValue < $1.rawValue } }
        public var hasDirect3D12: Bool { apis.contains(.d3d12) }
        public var summary: String { apis.isEmpty ? "Unknown" : apis.map(\.label).joined(separator: ", ") }
    }

    /// Inspect normal/delay imports (including API exports from interposers),
    /// then reachable local DLLs. Never scan every DLL shipped with a game:
    /// an unused DX12 renderer next to the selected DX11 EXE must not count.
    /// No game IDs, launcher metadata, execution or network access is involved.
    public static func detect(executable: URL, root: URL) -> Detection {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let executable = executable.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        func contained(_ url: URL) -> Bool { url.path.hasPrefix(root.path + "/") }
        var result = Detection(evidence: [], modulesScanned: 0, limited: false)
        guard contained(executable) else { return result }
        var directories: [String: [String]] = [:]
        func localDLL(_ name: String, beside module: URL) -> URL? {
            // Imports are base names, not paths. Do not follow arbitrary PE paths
            // or symlinks outside the title, and never inspect Wine's system DLLs.
            guard name.lowercased().hasSuffix(".dll"), !name.contains("/"), !name.contains("\\"),
                  !name.contains(":"), name != ".", name != ".." else { return nil }
            for dir in [module.deletingLastPathComponent(), executable.deletingLastPathComponent(), root] {
                if directories[dir.path] == nil {
                    directories[dir.path] = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
                }
                guard let actual = directories[dir.path]?.first(where: { $0 == name })
                    ?? directories[dir.path]?.first(where: { $0.lowercased() == name.lowercased() }) else { continue }
                let url = dir.appendingPathComponent(actual).resolvingSymlinksInPath().standardizedFileURL
                if contained(url) { return url }
            }
            return nil
        }
        // Bound catalogue refresh cost, including for hostile or enormous PEs.
        let maxModules = 32, maxDepth = 4, maxFileBytes = 128 * 1024 * 1024, maxTotalBytes = 256 * 1024 * 1024
        var queue = [(executable, 0)], seen = Set<String>(), bytes = 0, index = 0
        while index < queue.count {
            let (url, depth) = queue[index]
            index += 1
            guard seen.insert(url.path).inserted else { continue }
            guard seen.count <= maxModules else { result.limited = true; break }
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  size.isRegularFile == true, let count = size.fileSize else { continue }
            guard count <= maxFileBytes, count <= maxTotalBytes - bytes else { result.limited = true; continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= maxFileBytes,
                  data.count <= maxTotalBytes - bytes else { continue }
            bytes += data.count
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard let inspection = inspect(data, module: relative) else { continue }
            result.modulesScanned += 1
            result.limited = result.limited || inspection.limited
            result.evidence += inspection.evidence
            for item in inspection.imports {
                // The renderer library import itself is evidence; inspecting a
                // local proxy of it adds cost but no useful routing information.
                guard libraryAPI(item.library) == nil, let child = localDLL(item.library, beside: url) else { continue }
                guard depth < maxDepth else { result.limited = true; continue }
                queue.append((child, depth + 1))
            }
        }
        return result
    }

    static func libraryAPI(_ name: String) -> API? {
        switch name.lowercased() {
        case "d3d8.dll": .d3d8
        case "d3d9.dll": .d3d9
        case "d3d10.dll", "d3d10_1.dll", "d3d10core.dll": .d3d10
        case "d3d11.dll": .d3d11
        case "d3d12.dll", "d3d12core.dll": .d3d12
        default: nil
        }
    }

    static func functionAPI(_ name: String) -> API? {
        // Recognise API exports regardless of the importing DLL's name. This
        // covers graphics interposers without vendor/game-specific rules.
        if name.hasPrefix("D3D12") { return .d3d12 }
        if name.hasPrefix("D3D11") { return .d3d11 }
        if name.hasPrefix("D3D10") { return .d3d10 }
        if ["Direct3DCreate9", "Direct3DCreate9Ex", "Direct3DCreate9On12", "Direct3DCreate9On12Ex"].contains(name) { return .d3d9 }
        if name == "Direct3DCreate8" { return .d3d8 }
        return nil
    }

    struct Import {
        var library: String
        var functions: [String]
    }
    struct Inspection {
        var imports: [Import]
        var evidence: [Evidence]
        var limited: Bool
    }

    static func inspect(_ data: Data, module: String = "executable") -> Inspection? {
        guard let pe = PE(data) else { return nil }
        var result = Inspection(imports: [], evidence: [], limited: false)
        var remaining = 65536
        func add(_ api: API, _ kind: Evidence.Kind, _ name: String) {
            // One example per API/kind/module suffices, rather than recording
            // hundreds of functions from an engine's import table.
            if !result.evidence.contains(where: { $0.api == api && $0.kind == kind }) {
                result.evidence.append(Evidence(api: api, module: module, kind: kind, name: name))
            }
        }
        for (directory, stride, nameOffset) in [(1, 20, 12), (13, 32, 4)] {
            guard let (rva, size) = pe.directory(directory), rva > 0 else { continue }
            let descriptors = min(size / stride, 4096)
            if size / stride > descriptors { result.limited = true }
            for i in 0..<descriptors {
                guard let at = pe.offset(rva + i * stride, size: stride), let nameAddress = pe.u32(at + nameOffset),
                      nameAddress != 0 else { break }
                let isRVA = directory == 1 || (pe.u32(at) ?? 0) & 1 != 0
                guard isRVA || !pe.plus else { continue }
                func address(_ value: Int) -> Int { isRVA ? value : value - pe.imageBase }
                guard let nameAt = pe.offset(address(nameAddress), size: 1), let library = pe.string(nameAt) else { continue }
                if let api = libraryAPI(library) { add(api, .libraryImport, library) }
                let original = pe.u32(at + (directory == 1 ? 0 : 16)) ?? 0
                let fallback = pe.u32(at + (directory == 1 ? 16 : 12)) ?? 0
                let thunk = address(original != 0 ? original : fallback)
                var functions: [String] = []
                if thunk > 0 {
                    let width = pe.plus ? 8 : 4
                    for n in 0..<16384 {
                        guard remaining > 0 else { result.limited = true; break }
                        remaining -= 1
                        guard let slot = pe.offset(thunk + n * width, size: width), let low = pe.u32(slot) else { break }
                        let high = pe.plus ? pe.u32(slot + 4) ?? 0 : 0
                        if low == 0 && high == 0 { break }
                        // Ordinal imports have no function name. PE32+ name RVAs
                        // must fit 32 bits; never convert an ordinal/VA to an offset.
                        if pe.plus ? high != 0 : low & 0x80000000 != 0 { continue }
                        if n == 16383 { result.limited = true }
                        guard let hint = pe.offset(address(low), size: 3), let function = pe.string(hint + 2) else { continue }
                        functions.append(function)
                        if let api = functionAPI(function) { add(api, .functionImport, "\(library)!\(function)") }
                    }
                }
                result.imports.append(Import(library: library, functions: functions))
            }
        }
        // Dynamic loading: require the loading APIs AND both exact NUL-terminated
        // renderer DLL and creation-function strings in initialized, non-code data.
        // A resource/readme string, or a renderer DLL merely shipped nearby, does
        // not count. This is still a heuristic, not a proof of runtime use.
        let functions = Set(result.imports.flatMap(\.functions))
        if !functions.isDisjoint(with: ["LoadLibraryA", "LoadLibraryW", "LoadLibraryExA", "LoadLibraryExW"]),
           functions.contains("GetProcAddress") {
            for (api, library, function) in [(API.d3d8, "d3d8.dll", "Direct3DCreate8"),
                                             (.d3d9, "d3d9.dll", "Direct3DCreate9"),
                                             (.d3d10, "d3d10.dll", "D3D10CreateDevice"),
                                             (.d3d11, "d3d11.dll", "D3D11CreateDevice"),
                                             (.d3d12, "d3d12.dll", "D3D12CreateDevice")] {
                if result.evidence.contains(where: { $0.api == api }) { continue }
                if pe.hasDataString(library, caseInsensitive: true) && pe.hasDataString(function) {
                    add(api, .dynamicReference, "\(library)!\(function)")
                }
            }
        }
        return result
    }

    /// Bounds-checked PE32/PE32+ reader. No loading or code execution.
    private struct PE {
        let data: Data
        let optional: Int
        let optionalSize: Int
        let sections: Int
        let sectionTable: Int
        let directories: Int
        let plus: Bool
        let imageBase: Int
        let headerSize: Int

        init?(_ data: Data) {
            guard data.startIndex == 0, data.count <= 128 * 1024 * 1024 else { return nil }
            self.data = data
            func word(_ at: Int, _ bytes: Int) -> Int? {
                guard at >= 0, at <= data.count, bytes <= data.count - at else { return nil }
                return (0..<bytes).reduce(0) { $0 | Int(data[at + $1]) << ($1 * 8) }
            }
            guard word(0, 2) == 0x5a4d, let start = word(0x3c, 4), word(start, 4) == 0x4550,
                  let count = word(start + 6, 2), let size = word(start + 20, 2),
                  start + 24 <= data.count, size <= data.count - (start + 24),
                  let magic = word(start + 24, 2), magic == 0x10b || magic == 0x20b else { return nil }
            optional = start + 24
            optionalSize = size
            sections = count
            sectionTable = optional + size
            plus = magic == 0x20b
            directories = plus ? 112 : 96
            guard size >= directories, count <= 96, sectionTable <= data.count,
                  count * 40 <= data.count - sectionTable else { return nil }
            headerSize = word(optional + 60, 4) ?? 0
            imageBase = plus ? 0 : word(optional + 28, 4) ?? 0
        }

        func fits(_ at: Int, _ size: Int) -> Bool { at >= 0 && at <= data.count && size >= 0 && size <= data.count - at }
        func u32(_ at: Int) -> Int? {
            guard fits(at, 4) else { return nil }
            return (0..<4).reduce(0) { $0 | Int(data[at + $1]) << ($1 * 8) }
        }
        func directory(_ index: Int) -> (Int, Int)? {
            guard index < (u32(optional + directories - 4) ?? 0),
                  directories + (index + 1) * 8 <= optionalSize,
                  let rva = u32(optional + directories + index * 8),
                  let size = u32(optional + directories + index * 8 + 4) else { return nil }
            return (rva, size)
        }
        func offset(_ rva: Int, size: Int) -> Int? {
            guard rva > 0 else { return nil }
            if rva < headerSize, size <= headerSize - rva, fits(rva, size) { return rva }
            for i in 0..<sections {
                let s = sectionTable + i * 40
                guard let va = u32(s + 12), let rawSize = u32(s + 16), let raw = u32(s + 20),
                      rva >= va, rva - va < rawSize, size <= rawSize - (rva - va) else { continue }
                let at = raw + rva - va
                if fits(at, size) { return at }
            }
            return nil
        }
        func string(_ at: Int) -> String? {
            guard fits(at, 1) else { return nil }
            var end = at
            while end < min(data.count, at + 512) && data[end] != 0 {
                guard data[end] >= 32 && data[end] < 127 else { return nil }
                end += 1
            }
            guard end > at, end < data.count, data[end] == 0 else { return nil }
            return String(bytes: data[at..<end], encoding: .ascii)
        }
        func hasDataString(_ value: String, caseInsensitive: Bool = false) -> Bool {
            let ascii = Data(value.utf8) + Data([0])
            let wide: [UInt8] = value.utf16.flatMap { unit -> [UInt8] in
                [UInt8(truncatingIfNeeded: unit), UInt8(unit >> 8)]
            } + [0, 0]
            let needles = [ascii, Data(wide)]
            for i in 0..<sections {
                let s = sectionTable + i * 40
                guard let flags = u32(s + 36), flags & 0x40 != 0, flags & 0x20000020 == 0,
                      let rawSize = u32(s + 16), let raw = u32(s + 20), fits(raw, rawSize) else { continue }
                let sectionName = String(bytes: data[s..<(s + 8)].prefix { $0 != 0 }, encoding: .ascii) ?? ""
                if [".rsrc", ".reloc"].contains(sectionName) || sectionName.hasPrefix(".debug") { continue }
                for (encoding, needle) in needles.enumerated() {
                    let pattern = Array(needle), boundary = encoding == 0 ? 1 : 2
                    // memchr skips bytes in native code. Do not copy/lowercase huge
                    // sections, or walk all their bytes in Swift at -Onone. Only
                    // candidate starts need the short ASCII case-folded comparison.
                    let found = data.withUnsafeBytes { buffer -> Bool in
                        let base = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        let first = pattern[0]
                        let starts = caseInsensitive ? [first, first - 32] : [first]
                        for initial in starts {
                            var at = raw
                            while at < raw + rawSize,
                                  let hit = memchr(base + at, Int32(initial), raw + rawSize - at) {
                                let match = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                                at = match + 1
                                guard pattern.count <= raw + rawSize - match else { break }
                                guard match == raw || (match >= raw + boundary && (1...boundary).allSatisfy({ base[match - $0] == 0 })) else { continue }
                                let equal = pattern.indices.allSatisfy { n in
                                    var byte = base[match + n]
                                    if caseInsensitive && byte >= 65 && byte <= 90 { byte += 32 }
                                    return byte == pattern[n]
                                }
                                if equal { return true }
                            }
                        }
                        return false
                    }
                    if found { return true }
                }
            }
            return false
        }
    }
}
