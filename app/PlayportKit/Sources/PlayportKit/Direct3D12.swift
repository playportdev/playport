// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum Direct3D12 {
    /// The last explicit API flag wins, including DX11 flags on dual-API games.
    /// Without a flag, use static evidence from the selected executable and DLLs.
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

    /// Direct normal/delay imports, by library OR API function name. Interposers
    /// can export D3D12CreateDevice under a DLL name other than d3d12.dll.
    /// Adoption uses Direct3D.detect for dependency and dynamic-reference evidence.
    public static func imports(in data: Data) -> Bool {
        Direct3D.inspect(data)?.evidence.contains { $0.api == .d3d12 && $0.kind != .dynamicReference } == true
    }
}
