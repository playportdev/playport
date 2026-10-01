// SPDX-License-Identifier: GPL-3.0-or-later
// Paths, the QR renderer and the redacted log sink of the Steam screens (UI/).

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SteamClientKit
import UIKit

/// Container paths for Steam's non-secret files, resolved once, at first use:
/// before any title launch, since wine_host_init moves HOME into the prefix.
enum SteamPaths {
    /// The service record (renewal) and the owned-games cache.
    static let state = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Playport/steam", isDirectory: true)
    /// The download queue (PlayportKit DownloadQueueStore), kept across the restart after a game.
    static let downloads = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Playport/downloads.json")
    /// Store art, re-fetchable, so under Caches.
    static let art = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Playport/art", isDirectory: true)
    static let home = NSHomeDirectory()

    /// The container path carries the install's UUID (an install identifier).
    static func maskContainer(_ line: String) -> String {
        line.replacingOccurrences(of: "/private" + home, with: "<container>").replacingOccurrences(of: home, with: "<container>")
    }
}

/// The Steam login QR code as an image. The payload goes only to CoreImage.
enum QRImage {
    static func make(_ payload: Secret<String>) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(payload.value.utf8)
        f.correctionLevel = "M"
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        guard let small = f.outputImage,
              let cg = CIContext().createCGImage(small.transformed(by: scale), from: small.extent.applying(scale))
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// The UI's Steam log: every line is already scrubbed by Logger; the
/// container path is masked too, then appended to SteamLog with a `[ui]` prefix.
enum SteamUILog {
    static let logger = Logger { line in SteamLog.append("[ui] " + SteamPaths.maskContainer(line)) }
}

/// Where Steam's redacted lines go. A dev build keeps them apart, in
/// Documents/steam-drive.log (pp ui pulls it after an install; Settings lists
/// it); a release build puts them in the app log (AppLog) as `steam:` lines,
/// under its size limit.
enum SteamLog {
    #if PLAYPORT_RELEASE
    static func append(_ line: String) { AppLog.append("steam: " + line) }
    #else
    static var url: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/steam-drive.log") }

    /// Serialised: the UI's service logs from several tasks at once.
    private static let lock = NSLock()

    static func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile()
        h.write(Data((line + "\n").utf8))
        try? h.close()
    }
    #endif
}
