// SPDX-License-Identifier: GPL-3.0-or-later
// Whether a Play holds the Social Club layout (decisions 0169, 0183; PLA-840): a game's Play when its
// install folder holds a verified Rockstar bootstrap, the launcher's Open when the Launcher.exe it starts
// is verified (SocialClubBootstrap, PlayportKit). Checked at Play, before the runtime starts; the launch
// sets PLAYPORT_SC_LAYOUT for the runtime from it (LaunchCoordinator). The hashes are kept between Plays
// by path, size and modification time, so Rockstar's 111 MB installer is read once per version. A dev
// build also hashes a file of a size no entry has and logs every unverified hash, so the next run shows
// what to add to the table after a Steam update or a launcher self-update.

import Foundation
import PlayportKit

enum SocialClubLayout {
    private static let cacheKey = "socialClubBootstrapHashes"

    #if PLAYPORT_RELEASE
    private static let dev = false
    #else
    private static let dev = true
    #endif

    /// The folder's verdict and its log lines. Reads files: not on the main thread.
    static func check(folder: URL, place: SocialClubBootstrap.Place) -> (engaged: Bool, lines: [String]) {
        let defaults = UserDefaults.standard
        let kept = defaults.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode(SocialClubBootstrap.HashCache.self, from: $0) }
        var cache = kept ?? .init()
        let verdict = SocialClubBootstrap.check(folder: folder, place: place, cache: &cache, hashMismatches: dev)
        if cache != kept, let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: cacheKey) }
        return (verdict.engaged, verdict.logLines(hashes: dev))
    }
}
