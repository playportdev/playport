// SPDX-License-Identifier: GPL-3.0-or-later
/// A controller on the guest's GDI windows (a launcher or a dialog, shown
/// until the game's swap chain presents; decision 0075): its presses as the
/// keys a dialog moves and answers with. The D-pad and left stick are the
/// arrow keys, A is Enter (the default button), B is Escape (Cancel), X is
/// Space (the focused button or check box), RB is Tab and LB Shift+Tab.
public enum WindowKeys {
    /// Whether a controller's presses are the windows' keys now: a window is
    /// shown and the in-game menu is not up. While they are, mapped pads hold
    /// nothing (InputMixer.hold(.windows)), so A is Enter alone, not Enter and
    /// the map's key for A too.
    public static func takesPads(windowsShown: Bool, menuUp: Bool) -> Bool { windowsShown && !menuUp }

    /// The key events for a press, in order: (virtual-key code, down).
    public static func events(for b: NavButton) -> [(vk: Int32, down: Bool)] {
        switch b {
        case .lb: return [(0x10, true), (0x09, true), (0x09, false), (0x10, false)]
        default: return key(b).map { [($0, true), ($0, false)] } ?? []
        }
    }

    private static func key(_ b: NavButton) -> Int32? {
        switch b {
        case .up: 0x26
        case .down: 0x28
        case .left: 0x25
        case .right: 0x27
        case .a: 0x0D
        case .b: 0x1B
        case .x: 0x20
        case .rb: 0x09
        default: nil
        }
    }
}
