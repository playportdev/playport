// SPDX-License-Identifier: GPL-3.0-or-later
/// The title's screen: the display mode the guest is offered, and where its
/// swap chain lands on the phone. A title runs landscape; the guest gets one
/// mode with the panel's aspect (MADEIRA_SCREEN_W/H, which the runtime's
/// virtual monitor, metrics and mode list follow), and whatever size the game
/// then renders is aspect-fitted, so no aspect ratio is stretched.
public enum Display {
    /// The guest's screen for a panel of `long` × `short` native pixels, from
    /// a screen spec: nil, "" or "native" gives the panel itself, "<rows>" (for
    /// example "720") the panel's aspect at that many rows, "4:3" the runtime's
    /// old 1024×768, and "WxH" exactly that. Width and height are even. nil
    /// for a spec it cannot read.
    public static func guestSize(panelLong long: Int, panelShort short: Int, spec: String?) -> (Int, Int)? {
        guard long > 0, short > 0 else { return nil }
        let (w, h) = (max(long, short), min(long, short))
        switch spec?.lowercased() ?? "" {
        case "", "native":
            return (even(Double(w)), even(Double(h)))
        case let s where Int(s) != nil:
            guard let rows = Int(s), (200...h).contains(rows) else { return nil }
            return (even(Double(rows) * Double(w) / Double(h)), even(Double(rows)))
        case "4:3":
            return (1024, 768)
        case let s:
            let parts = s.split(separator: "x")
            guard parts.count == 2, let sw = Int(parts[0]), let sh = Int(parts[1]),
                  (320...8192).contains(sw), (200...8192).contains(sh) else { return nil }
            return (sw, sh)
        }
    }

    /// The rectangle a picture of content size fills inside a view of
    /// width × height when fitted without stretching and centred
    /// (CAMetalLayer contentsGravity resizeAspect): x, y, width, height.
    public static func aspectFit(contentWidth cw: Double, contentHeight ch: Double,
                                 width: Double, height: Double) -> (Double, Double, Double, Double) {
        guard cw > 0, ch > 0, width > 0, height > 0 else { return (0, 0, width, height) }
        let s = min(width / cw, height / ch)
        let (fw, fh) = (cw * s, ch * s)
        return ((width - fw) / 2, (height - fh) / 2, fw, fh)
    }

    /// Unity's own screen switches, to append to a Unity title's arguments so
    /// it opens full screen at the guest's screen size instead of the window
    /// size it saved last time; none when the launch already sets any of them.
    public static func unityScreenArgs(existing: [String], width: Int, height: Int) -> [String] {
        let own = ["-screen-", "-window-mode", "-popupwindow"]
        if existing.contains(where: { a in own.contains { a.lowercased().hasPrefix($0) } }) { return [] }
        return ["-screen-fullscreen", "1", "-screen-width", String(width), "-screen-height", String(height)]
    }

    private static func even(_ v: Double) -> Int { Int((v / 2).rounded()) * 2 }
}
