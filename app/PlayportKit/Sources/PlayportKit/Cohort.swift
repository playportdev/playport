// SPDX-License-Identifier: GPL-3.0-or-later
// The pinned title cohort (docs/decisions/0005-title-cohort.md) as the app
// ships it: Titles/titles.json at the app root, with each title's sha256sum
// list beside it. Adoption matches a folder of C:\Games to an entry by its
// install directory, so a title staged from the workstation is known exactly
// (app ID, build, executable, arguments, size, checksums) with no Steam session.

import Foundation

public struct CohortTitle: Codable, Equatable, Sendable {
    public struct Depot: Codable, Equatable, Sendable {
        public var depotID: UInt32
        /// A decimal string: JSON numbers lose a 64-bit manifest ID's low digits.
        public var manifestGID: String
    }

    public var appID: UInt32
    public var name: String
    public var developer: String?
    public var installDir: String
    /// Relative to the install directory, `\` or `/` separated (`bin\x64\witcher3.exe`).
    public var executable: String
    public var arguments: [String]
    public var buildID: UInt32?
    public var depots: [Depot]
    public var installedSize: UInt64?
    public var files: Int?
    /// A sha256sum list beside titles.json.
    public var checksums: String?
    /// madeira.cfg keys this title launches with, over the shared file (TitleConfig).
    public var config: [String: String]?
    /// The guest's screen for a library Play, a screen spec (HostIOKit Display.guestSize; `720`:
    /// the panel's aspect at 720 rows); absent for the panel's native pixels.
    public var screen: String?
    /// The memory footprint (MB) the title reached on the reference phone, pool included:
    /// a Play under a lower limit is refused (MemoryNeed); absent for an unmeasured title.
    public var memoryMB: Int?
    public var note: String?
}

public struct Cohort: Equatable, Sendable {
    public var titles: [CohortTitle]
    /// Where titles.json was read from; checksum lists are beside it.
    public var directory: URL?

    public init(titles: [CohortTitle], directory: URL? = nil) {
        self.titles = titles
        self.directory = directory
    }

    private struct File: Codable {
        var titles: [CohortTitle]
    }

    /// Reads `<directory>/titles.json`.
    public static func load(directory: URL) throws -> Cohort {
        let data = try Data(contentsOf: directory.appendingPathComponent("titles.json"))
        return Cohort(titles: try JSONDecoder().decode(File.self, from: data).titles, directory: directory)
    }

    /// The entry for an install directory; Windows compares names without case.
    public func title(installDir: String) -> CohortTitle? {
        titles.first { $0.installDir.lowercased() == installDir.lowercased() }
    }

    /// A title's checksum list (`checksums`), beside titles.json.
    public func checksumList(named name: String?) -> URL? {
        guard let name, let directory else { return nil }
        return directory.appendingPathComponent(name)
    }
}
