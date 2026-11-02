// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import HostIOKit

/// The touch keyboard (TouchKeyboard.dc.html; PLA-13,
/// phase 4 item 2): its keys, where they are, and its sticky modifiers.
final class TouchKeyboardTests: XCTestCase {
    /// The board's screen: 874 × 402 with 44 pt either side for the island and the home indicator under it.
    let area = TouchRect(x: 44, y: 0, width: 786, height: 381)

    func p(_ x: Double, _ y: Double) -> TouchPoint { TouchPoint(x: x, y: y) }

    func key(_ id: String, _ l: TouchKeyboard.Layout) -> TouchTarget {
        l.targets.first { $0.id == id }!
    }

    func assertRect(_ r: TouchRect, _ x: Double, _ y: Double, _ w: Double, _ h: Double, line: UInt = #line) {
        for (a, b) in [(r.x, x), (r.y, y), (r.width, w), (r.height, h)] { XCTAssertEqual(a, b, accuracy: 0.001, line: line) }
    }

    func testTheBoardsRowsWithTheirKeys() {
        let labels = TouchKeyboard.rows.map { $0.map(\.label) }
        XCTAssertEqual(labels, [
            ["Esc", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "Del"],
            ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=", "⌫"],
            ["Tab", "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "[", "]", "\\"],
            ["Caps", "A", "S", "D", "F", "G", "H", "J", "K", "L", ";", "'", "Enter"],
            ["⇧ Shift", "Z", "X", "C", "V", "B", "N", "M", ",", ".", "/", "⇧"],
            ["Ctrl", "Win", "Alt", "Space", "Alt", "◀", "▼", "▲", "▶"],
        ])
    }

    /// The VKs a US keyboard's keys have (KeyMap, as a hardware keyboard sends them).
    func testEachKeyPressesItsVirtualKey() {
        let l = TouchKeyboard.layout(in: area)
        let vks: [String: UInt8] = [
            "kb-esc": 0x1B, "kb-f1": 0x70, "kb-f12": 0x7B, "kb-del": 0x2E, "kb-grave": 0xC0, "kb-1": 0x31, "kb-0": 0x30,
            "kb-minus": 0xBD, "kb-equals": 0xBB, "kb-backspace": 0x08, "kb-tab": 0x09, "kb-q": 0x51, "kb-lbracket": 0xDB,
            "kb-rbracket": 0xDD, "kb-backslash": 0xDC, "kb-caps": 0x14, "kb-a": 0x41, "kb-semicolon": 0xBA, "kb-quote": 0xDE,
            "kb-enter": 0x0D, "kb-z": 0x5A, "kb-comma": 0xBC, "kb-period": 0xBE, "kb-slash": 0xBF, "kb-win": 0x5B,
            "kb-space": 0x20, "kb-left": 0x25, "kb-down": 0x28, "kb-up": 0x26, "kb-right": 0x27,
        ]
        for (id, vk) in vks { XCTAssertEqual(key(id, l).kind, .key(vk), id) }
        let mods: [String: UInt8] = ["kb-shift": 0xA0, "kb-rshift": 0xA1, "kb-ctrl": 0xA2, "kb-alt": 0xA4, "kb-ralt": 0xA5]
        for (id, vk) in mods { XCTAssertEqual(key(id, l).kind, .modifier(vk), id) }
        XCTAssertEqual(key("kb-close", l).kind, .button(.playport(.keyboard), .hold))
        let ids = l.targets.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.count, 14 + 14 + 14 + 13 + 12 + 9 + 1)
    }

    /// The panel sits on the safe area's bottom edge, across it; the keys' faces
    /// are the board's (flex widths, 4 pt apart, 8 pt in), and what a touch hits
    /// tiles the panel, so no touch in a gap falls through to the game.
    func testKeysTileThePanelAndTheirFacesKeepTheBoardsGaps() {
        let l = TouchKeyboard.layout(in: area)
        XCTAssertEqual(l.panel, TouchRect(x: 44, y: 381 - 210, width: 786, height: 210))
        let esc = l.keys.first { $0.target.id == "kb-esc" }!
        // The F row: 14 keys, flex 1.3 + 12 + 1.3 over 770 - 13 × 4.
        let unit = (770.0 - 52) / 14.6
        XCTAssertEqual(esc.face.x, 52, accuracy: 0.001)
        XCTAssertEqual(esc.face.y, 179, accuracy: 0.001)
        XCTAssertEqual(esc.face.width, 1.3 * unit, accuracy: 0.001)
        XCTAssertEqual(esc.face.height, 24, accuracy: 0.001)
        assertRect(esc.target.frame, 44, 171, 8 + 1.3 * unit + 2, 8 + 24 + 2)
        let space = l.keys.first { $0.target.id == "kb-space" }!
        XCTAssertEqual(space.face.maxY, 373, accuracy: 0.001)
        XCTAssertEqual(space.target.frame.maxY, 381, accuracy: 0.001)
        // Every point of the panel is some key's.
        var t = TouchControls(targets: l.targets)
        for x in stride(from: 44.0, to: 830, by: 3) {
            for y in stride(from: 171.0, to: 381, by: 3) { XCTAssertNotNil(t.target(at: p(x, y)), "\(x),\(y)") }
        }
        // Above it the game's: the close key only.
        XCTAssertNil(t.target(at: p(400, 150)))
        let close = key("kb-close", l)
        XCTAssertEqual(close.frame.maxX, 830, accuracy: 0.001)
        XCTAssertEqual(close.frame.maxY, 171 - 4, accuracy: 0.001)
        XCTAssertTrue(t.began(1, at: close.frame.center, time: 0))
        XCTAssertEqual(t.output.playport, [.keyboard])
    }

    // MARK: sticky modifiers

    func controls() -> (TouchControls, TouchKeyboard.Layout) {
        let l = TouchKeyboard.layout(in: area)
        return (TouchControls(targets: l.targets), l)
    }

    func tap(_ t: inout TouchControls, _ id: String, _ l: TouchKeyboard.Layout, at time: Double, finger: Int = 1) {
        XCTAssertTrue(t.began(finger, at: key(id, l).frame.center, time: time), id)
        t.ended(finger, time: time + 0.05)
    }

    func keys(_ t: TouchControls) -> Set<InputAction> { t.output.keys }

    /// A tap on Shift holds it down until the next key goes up: Shift, then A, types "A".
    func testATappedModifierStaysDownForTheNextKey() {
        var (t, l) = controls()
        tap(&t, "kb-shift", l, at: 0)
        XCTAssertEqual(keys(t), [.key(0xA0, [])])
        XCTAssertEqual(t.sticky, ["kb-shift": .latched])
        XCTAssertEqual(t.held, ["kb-shift"])
        XCTAssertTrue(t.began(1, at: key("kb-a", l).frame.center, time: 1))
        XCTAssertEqual(keys(t), [.key(0xA0, []), .key(0x41, [])])
        t.ended(1, time: 1.1)
        XCTAssertEqual(keys(t), [])
        XCTAssertEqual(t.sticky, [:])
        XCTAssertEqual(t.held, [])
        // The next key is itself again.
        XCTAssertTrue(t.began(1, at: key("kb-b", l).frame.center, time: 2))
        XCTAssertEqual(keys(t), [.key(0x42, [])])
    }

    /// Two taps within doubleTapWindow lock it until it is tapped again; a second tap later lets go.
    func testADoubleTapLocksAModifierAndATapUnlocksIt() {
        var (t, l) = controls()
        tap(&t, "kb-shift", l, at: 0)
        tap(&t, "kb-shift", l, at: 0.2)
        XCTAssertEqual(t.sticky, ["kb-shift": .locked])
        tap(&t, "kb-a", l, at: 1)
        tap(&t, "kb-b", l, at: 2)
        XCTAssertEqual(keys(t), [.key(0xA0, [])])
        XCTAssertEqual(t.held, ["kb-shift"])
        tap(&t, "kb-shift", l, at: 3)
        XCTAssertEqual(t.sticky, [:])
        XCTAssertEqual(keys(t), [])
        // A latched modifier tapped again after the window: off.
        tap(&t, "kb-ctrl", l, at: 4)
        tap(&t, "kb-ctrl", l, at: 5)
        XCTAssertEqual(t.sticky, [:])
        XCTAssertEqual(keys(t), [])
    }

    /// Ctrl and Alt tapped, then Delete: all three down together, both let go after it.
    func testSeveralModifiersLatchForTheSameKey() {
        var (t, l) = controls()
        tap(&t, "kb-ctrl", l, at: 0)
        tap(&t, "kb-alt", l, at: 1)
        XCTAssertTrue(t.began(1, at: key("kb-del", l).frame.center, time: 2))
        XCTAssertEqual(keys(t), [.key(0xA2, []), .key(0xA4, []), .key(0x2E, [])])
        t.ended(1, time: 2.1)
        XCTAssertEqual(keys(t), [])
        XCTAssertEqual(t.sticky, [:])
    }

    /// A modifier held by a finger while another key is pressed is a chord: it lets go with the finger.
    func testAModifierHeldThroughAKeyLetsGoWithItsFinger() {
        var (t, l) = controls()
        XCTAssertTrue(t.began(1, at: key("kb-shift", l).frame.center, time: 0))
        XCTAssertEqual(keys(t), [.key(0xA0, [])])
        tap(&t, "kb-a", l, at: 0.5, finger: 2)
        XCTAssertEqual(keys(t), [.key(0xA0, [])])   // still under the finger
        t.ended(1, time: 1)
        XCTAssertEqual(keys(t), [])
        XCTAssertEqual(t.sticky, [:])
    }

    /// A cancelled tap leaves the modifier as it was; releaseAll lets go of latched and locked ones.
    func testACancelledTapChangesNothingAndReleaseAllLetsGo() {
        var (t, l) = controls()
        tap(&t, "kb-shift", l, at: 0)
        XCTAssertTrue(t.began(1, at: key("kb-shift", l).frame.center, time: 0.1))
        t.cancelled(1, time: 0.15)
        XCTAssertEqual(t.sticky, ["kb-shift": .latched])
        tap(&t, "kb-alt", l, at: 1)
        tap(&t, "kb-alt", l, at: 1.1)
        XCTAssertEqual(t.sticky, ["kb-shift": .latched, "kb-alt": .locked])
        t.releaseAll()
        XCTAssertEqual(t.sticky, [:])
        XCTAssertEqual(t.output, TouchOutput())
        XCTAssertEqual(t.held, [])
    }

    /// The words beside the close key: what a sticky modifier does now.
    func testTheHintSaysHowLongAModifierStaysDown() {
        XCTAssertNil(TouchKeyboard.hint([:]))
        XCTAssertEqual(TouchKeyboard.hint(["kb-shift": .latched]), "Shift stays down until the next key")
        XCTAssertEqual(TouchKeyboard.hint(["kb-rshift": .locked]), "Shift stays down until you tap it again")
        XCTAssertEqual(TouchKeyboard.hint(["kb-alt": .latched, "kb-ctrl": .latched]), "Ctrl and Alt stay down until the next key")
        XCTAssertEqual(TouchKeyboard.hint(["kb-alt": .locked, "kb-ctrl": .latched]),
                       "Ctrl stays down until the next key, Alt until you tap it again")
    }
}

/// The keyboard's keys through InputMixer, as HostIO sends them on to Lifecycle and winios_post_key.
final class TouchKeyboardMixerTests: XCTestCase {
    let l = TouchKeyboard.layout(in: TouchRect(x: 44, y: 0, width: 786, height: 381))

    func at(_ id: String) -> TouchPoint { l.targets.first { $0.id == id }!.frame.center }

    /// Shift tapped, then A: Shift down, A down, A up, Shift up, in that order.
    func testShiftThenAIsAChordForTheGame() {
        var t = TouchControls(targets: l.targets), m = InputMixer()
        var sent: [MixerOutput] = []
        func step(_ body: (inout TouchControls) -> Void) {
            body(&t)
            sent += m.touch(t.takeOutput()).outputs
        }
        step { $0.began(1, at: at("kb-shift"), time: 0) }
        step { $0.ended(1, time: 0.05) }
        step { $0.began(1, at: at("kb-a"), time: 1) }
        step { $0.ended(1, time: 1.05) }
        XCTAssertEqual(sent, [.key(0xA0, down: true), .key(0x41, down: true), .key(0x41, down: false), .key(0xA0, down: false)])
    }

    /// A modifier and a key pressed at the same moment: the modifier goes down first and up last.
    func testAModifierKeyGoesDownBeforeAKeyPressedWithIt() {
        var m = InputMixer()
        var o = TouchOutput()
        o.keys = [.key(0x41, []), .key(0xA5, []), .key(0x26, []), .key(0xA2, [])]
        XCTAssertEqual(m.touch(o).outputs, [.key(0xA2, down: true), .key(0xA5, down: true),
                                            .key(0x26, down: true), .key(0x41, down: true)])
        XCTAssertEqual(m.touch(TouchOutput()).outputs, [.key(0x41, down: false), .key(0x26, down: false),
                                                        .key(0xA5, down: false), .key(0xA2, down: false)])
    }

    /// With a controller connected the controls' pad is not player 1, yet the keyboard types:
    /// its keys go through and slot 0 stays the physical pad's.
    func testTheKeyboardTypesWithoutTheControlsPad() {
        var m = InputMixer()
        var pad = PadValues()
        pad.buttons = PadMapping.a
        _ = m.physical(slot: 0, pad)
        var o = TouchOutput()
        o.keys = [.key(0x41, [])]
        var r = m.touch(o, padOn: false)
        XCTAssertEqual(r.slot0, .unchanged)
        XCTAssertEqual(r.outputs, [.key(0x41, down: true)])
        XCTAssertFalse(m.touchOn)
        r = m.touch(nil)
        XCTAssertEqual(r.slot0, .unchanged)
        XCTAssertEqual(r.outputs, [.key(0x41, down: false)])
        // With no pad at all, slot 0 stays disconnected.
        _ = m.physicalLeft(slot: 0)
        r = m.touch(o, padOn: false)
        XCTAssertEqual(m.slot0, nil)
        XCTAssertEqual(r.slot0, .unchanged)
    }
}
