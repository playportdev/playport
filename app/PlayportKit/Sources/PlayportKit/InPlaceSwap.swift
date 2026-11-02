// SPDX-License-Identifier: GPL-3.0-or-later
// A play's in-place swap (decision 0181): an Xbox copy keeps some files encrypted on
// disk, and its Play puts their plaintext under the original names in the copy's own
// folder, so a game that relaunches itself or looks beside its executable finds what
// it expects, with no Wine loader change. Each original is set aside beside itself
// until the play ends; the end puts it back over the plaintext. A marker per play,
// written before the first file changes and removed after the last is back, lets the
// next app start finish that after a crash (`restoreAfterCrash`).
//
// Per file: the plaintext is written to a part file, the original renamed aside, then
// the part file renamed to the original's name. Whatever step a crash stops at, the
// restore leaves the original under its name and no plaintext: an aside goes back over
// whatever has the name, and a part file is deleted; a name with no aside is the
// original and is never touched.

import Foundation
import SteamClientKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct InPlaceSwap: Sendable {
    /// The library's games folder (C:\Games); a marker names a copy's folder under it, so
    /// it survives the app container's path changing between installs.
    public let games: URL
    /// Where the plays' markers live (outside the game folders).
    public let markers: URL

    public init(games: URL, markers: URL) {
        self.games = games
        self.markers = markers
    }

    /// What a play swapped: the copy's folder under `games` and its files, `/`-separated.
    struct Marker: Codable, Equatable {
        var folder: String
        var files: [String]
    }

    static let asideSuffix = ".playport-original"
    static let partSuffix = ".playport-plain"

    /// The plays whose originals are not all back (their markers).
    public var pending: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: markers.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// Puts each of `files` (relative to the copy's `folder`) in plaintext under its own
    /// name for the play `play` (its title ID): `plaintext(path, original, out)` reads the
    /// original of `path` (as `files` names it) and writes its plaintext to `out`. An
    /// unfinished swap of the same play is undone first. On any failure what was swapped
    /// is put back and the error rethrown.
    public func swap(play: String, folder: String, files: [String],
                     plaintext: (_ path: String, _ original: URL, _ out: URL) throws -> Void) throws {
        let marker = try Marker(folder: SafePath.normalize(folder), files: files.map { try SafePath.normalize($0) })
        let file = try markerFile(play)
        let dir = games.appendingPathComponent(marker.folder, isDirectory: true)
        let urls = try marker.files.map { try InstallFS.resolveInside(dir, $0, createParents: false) }
        try restore(play: play)
        try InstallFS.makeDirectory(markers)
        try InstallFS.writeAtomically(file, JSONEncoder().encode(marker))
        do {
            for (path, url) in zip(files, urls) {
                let part = Self.sibling(url, Self.partSuffix), aside = Self.sibling(url, Self.asideSuffix)
                unlink(part.path)
                try plaintext(path, url, part)
                try Self.flush(part)
                try Self.move(url, aside)
                try Self.move(part, url)
            }
        } catch {
            try? restore(play: play)
            throw error
        }
    }

    /// Ends the play `play`: every original back over its plaintext, every part file
    /// deleted, then the marker. Nothing to do when the play has no marker.
    public func restore(play: String) throws {
        let file = try markerFile(play)
        guard let data = try? Data(contentsOf: file) else { return }
        let marker = try JSONDecoder().decode(Marker.self, from: data)
        let dir = games.appendingPathComponent(try SafePath.normalize(marker.folder), isDirectory: true)
        var failure: Error?
        for path in marker.files {
            do {
                let url = try InstallFS.resolveInside(dir, path, createParents: false)
                let aside = Self.sibling(url, Self.asideSuffix)
                if FileManager.default.fileExists(atPath: aside.path) { try Self.move(aside, url) }
                unlink(Self.sibling(url, Self.partSuffix).path)
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
        try FileManager.default.removeItem(at: file)
    }

    /// At the app's start: every play a crash left unfinished, restored. Returns the
    /// plays restored; one that cannot be keeps its marker for the next start.
    @discardableResult
    public func restoreAfterCrash() -> [String] {
        pending.filter { (try? restore(play: $0)) != nil }
    }

    private func markerFile(_ play: String) throws -> URL {
        try WindowsName.check(play)
        return markers.appendingPathComponent(play + ".json")
    }

    private static func sibling(_ url: URL, _ suffix: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + suffix)
    }

    private static func move(_ from: URL, _ to: URL) throws {
        guard rename(from.path, to.path) == 0 else {
            throw ClientError.transport("rename \(from.lastPathComponent) errno \(errno)")
        }
    }

    /// The plaintext is on disk before the original's name points at it.
    private static func flush(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ClientError.transport("open \(url.lastPathComponent) errno \(errno)") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw ClientError.transport("fsync \(url.lastPathComponent) errno \(errno)") }
    }
}
