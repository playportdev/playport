// SPDX-License-Identifier: GPL-3.0-or-later
// Best-effort detection from the selected executable, not a compatibility claim.
import Foundation

public enum Direct3D12 {
    /// The last explicit API flag wins, including DX11 flags on dual-API games.
    /// Without a flag, use the executable's normal or delay-loaded imports.
    public static func requested(arguments: [String], imported: Bool) -> Bool {
        var result = imported
        for arg in arguments.map({ $0.lowercased() }) {
            switch arg {
            case "-dx12", "-d3d12", "-force-d3d12": result = true
            case "-dx11", "-d3d11", "-force-d3d11", "-dx10", "-d3d10", "-force-d3d9", "-vulkan", "-opengl", "-force-glcore": result = false
            default: break
            }
        }
        return result
    }

    public static func imports(in executable: URL) -> Bool {
        guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe) else { return false }
        return imports(in: data)
    }

    /// PE32 / PE32+, with all file offsets checked before reading. Only an
    /// actual imported d3d12.dll counts, not a DLL shipped next to the game or
    /// a string in its resources. Dynamic LoadLibrary and imports in engine
    /// DLLs are not detected; the player can select Vulkan for those games.
    public static func imports(in data: Data) -> Bool {
        func fits(_ at: Int, _ size: Int) -> Bool {
            at >= 0 && size >= 0 && at <= data.count && size <= data.count - at
        }
        func u16(_ at: Int) -> Int? {
            guard fits(at, 2) else { return nil }
            return Int(data[at]) | Int(data[at + 1]) << 8
        }
        func u32(_ at: Int) -> Int? {
            guard fits(at, 4) else { return nil }
            return (0..<4).reduce(0) { $0 | Int(data[at + $1]) << ($1 * 8) }
        }
        guard u16(0) == 0x5a4d, let pe = u32(0x3c), u32(pe) == 0x4550,
              let sections = u16(pe + 6), let optionalSize = u16(pe + 20),
              fits(pe + 24, optionalSize) else { return false }
        let optional = pe + 24
        let directories: Int
        let imageBase: Int
        switch u16(optional) {
        case 0x10b:
            directories = 96
            imageBase = u32(optional + 28) ?? 0
        case 0x20b:
            directories = 112
            // VA-based delay imports are only valid for PE32. PE32+ uses RVAs.
            imageBase = 0
        default: return false
        }
        guard optionalSize >= directories, let count = u32(optional + directories - 4),
              let headerSize = u32(optional + 60), fits(optional + optionalSize, sections * 40)
        else { return false }
        func offset(_ rva: Int, size: Int) -> Int? {
            guard rva > 0 else { return nil }
            if rva < headerSize, size <= headerSize - rva, fits(rva, size) { return rva }
            for i in 0..<sections {
                let s = optional + optionalSize + i * 40
                guard let va = u32(s + 12), let rawSize = u32(s + 16), let raw = u32(s + 20),
                      rva >= va, rva - va < rawSize, size <= rawSize - (rva - va) else { continue }
                let at = raw + rva - va
                if fits(at, size) { return at }
            }
            return nil
        }
        func isD3D12(_ rva: Int) -> Bool {
            let name = Array("d3d12.dll".utf8) + [0]
            guard let at = offset(rva, size: name.count) else { return false }
            return name.indices.allSatisfy { i in
                let byte = data[at + i]
                return (byte >= 65 && byte <= 90 ? byte + 32 : byte) == name[i]
            }
        }
        for (index, stride, nameOffset) in [(1, 20, 12), (13, 32, 4)] {
            guard index < count, directories + (index + 1) * 8 <= optionalSize,
                  let rva = u32(optional + directories + index * 8),
                  let size = u32(optional + directories + index * 8 + 4), rva > 0 else { continue }
            // A malformed directory must not cause unbounded work.
            for i in 0..<min(size / stride, data.count / stride) {
                guard let at = offset(rva + i * stride, size: stride), let name = u32(at + nameOffset)
                else { break }
                if name == 0 { break }
                let isRVA = index == 1 || (u32(at) ?? 0) & 1 != 0
                if isD3D12(isRVA ? name : name - imageBase) { return true }
            }
        }
        return false
    }
}
