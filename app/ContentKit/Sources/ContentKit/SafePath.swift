// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Path policy for everything the client writes under an install root.
public enum SafePath {
    public static let maxPathBytes = 1024
    public static let maxComponentBytes = 255

    /// Normalises a manifest path (Windows separators) to a relative,
    /// "/"-separated path, or throws `unsafeContent`.
    public static func normalize(_ raw: String) throws -> String {
        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        guard !unified.isEmpty, unified.utf8.count <= maxPathBytes else { throw ClientError.unsafeContent("path length \(unified.utf8.count)") }
        guard !unified.hasPrefix("/") else { throw ClientError.unsafeContent("absolute path \(unified)") }
        guard !unified.unicodeScalars.contains(where: { $0.value < 0x20 || $0 == ":" }) else {
            throw ClientError.unsafeContent("control character, drive or stream separator in \(unified.debugDescription)")
        }
        var parts: [Substring] = []
        for c in unified.split(separator: "/", omittingEmptySubsequences: true) {
            guard c != "..", c != "." else { throw ClientError.unsafeContent("traversal component in \(unified)") }
            guard c.utf8.count <= maxComponentBytes else { throw ClientError.unsafeContent("component too long in \(unified)") }
            parts.append(c)
        }
        guard !parts.isEmpty else { throw ClientError.unsafeContent("empty path") }
        return parts.joined(separator: "/")
    }

    /// A symlink entry may only point at a location inside the root.
    public static func checkLink(from path: String, target: String) throws {
        let t = target.replacingOccurrences(of: "\\", with: "/")
        guard !t.hasPrefix("/"), !t.contains(":") else { throw ClientError.unsafeContent("symlink \(path) -> absolute target") }
        var stack = path.split(separator: "/").dropLast().map(String.init)
        for c in t.split(separator: "/") {
            if c == "." { continue }
            if c == ".." {
                guard !stack.isEmpty else { throw ClientError.unsafeContent("symlink \(path) escapes the install root") }
                stack.removeLast()
            } else {
                stack.append(String(c))
            }
        }
    }
}
