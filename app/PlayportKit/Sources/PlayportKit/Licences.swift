// SPDX-License-Identifier: GPL-3.0-or-later
// The licences and notices the app carries (docs/NOTICES.md, "The app's selection"):
// Licenses/ at the app root, staged by the pipeline's notices stage from
// `pp notices --app`. Its components.json lists each component, its licence and
// its files, the credit lines, and the selection's open review questions. Settings'
// licences page reads it rather than a list of its own; a bundle that does not load
// is shown as missing, never replaced by a placeholder.

import Foundation

public struct Licences: Equatable, Sendable {
    public struct Component: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        public var licence: String
        /// The IPA parts it covers (artifacts.tsv provenance keys and build/app-notices.json parts).
        public var covers: [String]
        /// Relative to Licenses/.
        public var files: [String]
        public var id: String { name }
    }

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case schema(Int)
        case unsafeName(String)
        case missingFile(String)
        case empty

        public var description: String {
            switch self {
            case .unreadable(let why): return "components.json could not be read: \(why)"
            case .schema(let n): return "components.json has schema \(n), not \(Licences.schema)"
            case .unsafeName(let name): return "components.json names an unsafe path: \(name)"
            case .missingFile(let name): return "\(name) is listed but not in Licenses/"
            case .empty: return "components.json lists no component"
            }
        }
    }

    public static let schema = 1
    /// The status a reviewed selection carries (build/notices-bundle.py RELEASE_STATUS).
    public static let reviewedStatus = "release-reviewed"
    /// Playport's own licence and additional permission, as the selection names them.
    public static let playportLicence = "Playport-LICENSE.txt"
    public static let playportException = "Playport-LICENSE-EXCEPTION.md"

    public var directory: URL
    public var status: String
    public var components: [Component]
    public var credits: [String]
    /// The selection's review questions; empty once it is reviewed.
    public var open: [String]

    public var reviewed: Bool { status == Licences.reviewedStatus && open.isEmpty }

    private struct File: Codable {
        var schema: Int
        var status: String
        var components: [Component]
        var credits: [String]
        var open: [String]
    }

    /// Reads `<directory>/components.json` and checks that every file it lists is a
    /// regular file inside the directory.
    public static func load(directory: URL) throws -> Licences {
        let file: File
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("components.json"))
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw LoadError.unreadable(String(describing: error))
        }
        guard file.schema == schema else { throw LoadError.schema(file.schema) }
        guard !file.components.isEmpty else { throw LoadError.empty }
        for name in file.components.flatMap(\.files) {
            guard safe(name) else { throw LoadError.unsafeName(name) }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path,
                                                 isDirectory: &isDirectory), !isDirectory.boolValue
            else { throw LoadError.missingFile(name) }
        }
        return Licences(directory: directory, status: file.status, components: file.components,
                        credits: file.credits, open: file.open)
    }

    /// Whether a listed file is part of the bundle.
    public func contains(_ name: String) -> Bool {
        components.contains { $0.files.contains(name) }
    }

    /// A listed file's text. Notices are mostly UTF-8; one that is not is read as Latin-1,
    /// which keeps every byte, rather than shown empty.
    public func text(of name: String) throws -> String {
        guard Licences.safe(name), contains(name) else { throw LoadError.unsafeName(name) }
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return String(data: data, encoding: .utf8) ?? String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) }))
    }

    /// Splits a text at blank lines, so a long licence renders lazily, one paragraph a row.
    public static func paragraphs(_ text: String) -> [String] {
        var out: [String] = []
        var current: [Substring] = []
        // isNewline: "\r\n" is one Character, which a split at "\n" would not see.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                if !current.isEmpty { out.append(current.joined(separator: "\n")); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { out.append(current.joined(separator: "\n")) }
        return out
    }

    /// A relative name with no empty, `.` or `..` component.
    static func safe(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/") else { return false }
        return name.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

