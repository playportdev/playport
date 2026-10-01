// SPDX-License-Identifier: GPL-3.0-or-later
// Keeps the pairing code in view while the person is in iOS Settings, and
// takes them there. The code floats in a picture-in-picture window (a
// sample-buffer layer fed a rendered image of it), which also keeps Playport
// running while the listener waits (Info.plist UIBackgroundModes audio, the
// documented requirement for picture in picture). Open Settings opens
// Settings' top level.
import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Settings, as close to Developer Mode as an app can get. On iOS 27.0
/// (24A437) every `App-prefs:` link with a page (Privacy, DEVELOPER_MODE,
/// DEVELOPER_SETTINGS) lands on Settings' Apps list, `prefs:` is refused, and
/// the bare `App-prefs:` opens Settings' top level, from which Privacy &
/// Security is one tap (docs/evidence/2026-09-30-on-device-pairing.md). None of
/// these is public API; Playport's own Settings page is the public fallback.
enum SettingsLink {
    static let top = URL(string: "App-prefs:")!

    #if !PLAYPORT_RELEASE
    /// What the dev probe (`probe:settings-url-N`) tried; kept to re-check a new iOS.
    static let probed: [URL] = [
        "App-prefs:Privacy&path=DEVELOPER_MODE",
        "App-prefs:root=Privacy&path=DEVELOPER_MODE",
        "prefs:root=Privacy&path=DEVELOPER_MODE",
        "App-prefs:DEVELOPER_SETTINGS",
        "App-prefs:Privacy",
        "App-prefs:",
    ].compactMap(URL.init(string:))
    #endif

    @MainActor static func open() async -> Bool {
        if await UIApplication.shared.open(top) { return true }
        BuiltInJitStatus.log("on-device pairing: Settings' top level did not open; opening Playport's page")
        return await UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
    }
}

private final class CodeLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// Live playback with no controls: nothing to pause or seek.
private final class LivePlayback: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize size: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval interval: CMTime) async {}
}

@MainActor
final class PairingCodeWindow {
    private let view = CodeLayerView()
    private let playback = LivePlayback()
    private var controller: AVPictureInPictureController?
    private var timer: Timer?
    private var code: String?

    init() {
        view.displayLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        view.layer.cornerRadius = 12
        view.clipsToBounds = true
    }

    /// The inline view the sheet shows; picture in picture needs it on screen.
    var inlineView: UIView { view }

    func show(_ code: String) {
        self.code = code
        do {
            // Mixes with the person's audio; the app plays nothing.
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { BuiltInJitStatus.log("on-device pairing: audio session for the code window: \(error)") }
        if controller == nil, AVPictureInPictureController.isPictureInPictureSupported() {
            let c = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: view.displayLayer,
                                                                      playbackDelegate: playback))
            c.canStartPictureInPictureAutomaticallyFromInline = true
            c.requiresLinearPlayback = true
            controller = c
        }
        enqueue()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.enqueue() }
        }
    }

    /// Back in Playport (or done): the inline view is enough.
    func dock() { controller?.stopPictureInPicture() }

    func close() {
        code = nil
        timer?.invalidate()
        timer = nil
        controller?.stopPictureInPicture()
        view.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func enqueue() {
        guard let code, let frame = Self.frame(code) else { return }
        let renderer = view.displayLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
        renderer.enqueue(frame)
    }

    /// The code as one BGRA frame, displayed at once (no timebase).
    private static func frame(_ code: String) -> CMSampleBuffer? {
        let w = 720, h = 270
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { CVPixelBufferUnlockBaseAddress(pb, []); return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        UIColor.black.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        func centred(_ s: String, _ font: UIFont, _ color: UIColor, y: CGFloat) {
            let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            let size = a.size()
            a.draw(at: CGPoint(x: (CGFloat(w) - size.width) / 2, y: y))
        }
        centred("Playport pairing code", .systemFont(ofSize: 34, weight: .medium), .lightGray, y: 28)
        let spaced = code.prefix(3) + " " + code.suffix(3)
        centred(String(spaced), .monospacedDigitSystemFont(ofSize: 120, weight: .semibold), .white, y: 92)
        UIGraphicsPopContext()
        CVPixelBufferUnlockBaseAddress(pb, [])

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let list = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(list) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(list, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// The code, inline in the setup sheet; the same layer floats over Settings.
struct PairingCodeView: UIViewRepresentable {
    let window: PairingCodeWindow
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        let v = window.inlineView
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(v)
        NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                                     v.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                                     v.topAnchor.constraint(equalTo: host.topAnchor),
                                     v.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
        return host
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

extension OnDevicePairing {
    /// Opens Settings; the code window floats over it as Playport leaves the
    /// front. The code is not copied: the pairing field in Settings refused
    /// paste on iOS 27.0 (24A437).
    func openSettings() {
        guard code != nil else { return }
        Task { _ = await SettingsLink.open() }
    }
}
