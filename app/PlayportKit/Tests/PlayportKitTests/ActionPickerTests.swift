// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import HostIOKit
@testable import PlayportKit

/// ActionPicker (ActionPicker.dc.html): its tabs, what `accepts` lets through,
/// the cursor, the modifiers, the recent choices and a hardware key.
final class ActionPickerTests: XCTestCase {
    func ids(_ p: ActionPicker) -> [[String]] { p.rows.map { $0.map(\.id) } }

    func testAButtonGetsEveryTabAndAKeyboard() {
        let p = ActionPicker(for: .control(.a), title: "What A presses", current: .key(0x20, []))
        XCTAssertEqual(p.tabs, [.keyboard, .mouse, .controller, .playport])
        XCTAssertEqual(p.tab, .keyboard)
        // The cursor starts on the key bound now: Space, on the bottom key row.
        XCTAssertEqual(p.cell?.id, "key:0x20")
        XCTAssertEqual(p.cell?.label, "Space")
        let rows = ids(p)
        XCTAssertEqual(rows.count, 7)            // F-keys, digits, Q, A, Z, Space, then the chips
        XCTAssertEqual(rows[0].first, "key:0x1B")
        XCTAssertEqual(rows[1][1], "key:0x31")
        XCTAssertEqual(Array(rows[2][1...4]), ["key:0x51", "key:0x57", "key:0x45", "key:0x52"])
        XCTAssertEqual(rows[6], ["mod:shift", "mod:ctrl", "mod:alt"])
        // Mouse look and the pad's sticks are a whole stick's only.
        var m = p
        m.select(.mouse)
        XCTAssertEqual(ids(m).flatMap { $0 }, ["mouse:left", "mouse:right", "mouse:middle", "mouse:wheelUp", "mouse:wheelDown"])
        m.select(.controller)
        XCTAssertFalse(ids(m).flatMap { $0 }.contains("pad:leftStick"))
        XCTAssertTrue(ids(m).flatMap { $0 }.contains("pad:back"))
        m.select(.playport)
        XCTAssertEqual(ids(m), [["playport:menu", "nothing"]])
    }

    func testAWholeStickGetsOnlyAStickAction() {
        let input = ControllerInput.control(.rightStick)
        var p = ActionPicker(for: input, title: "What R stick presses", current: .mouse(.move))
        XCTAssertEqual(p.tabs, [.mouse, .controller, .playport])
        XCTAssertEqual(p.tab, .mouse)
        XCTAssertEqual(ids(p), [["mouse:move"]])
        XCTAssertEqual(p.cell?.label, "Mouse look")
        p.switchTab(by: 1)
        XCTAssertEqual(ids(p), [["pad:leftStick", "pad:rightStick"]])
        p.switchTab(by: 1)
        XCTAssertEqual(ids(p), [["nothing"]])
        p.switchTab(by: 1)                     // stops at the end
        XCTAssertEqual(p.tab, .playport)
        XCTAssertEqual(p.choose(), .chosen(nil))
        // Every choice a tab offers, the input takes.
        for t in p.tabs {
            p.select(t)
            for case .action(let a?) in p.rows.flatMap({ $0 }).map(\.kind) { XCTAssertTrue(input.accepts(a), a.name) }
        }
        // A stick's direction is a button: no stick actions.
        let d = ActionPicker(for: .stickDirection(.leftStick, .up), title: "", current: nil)
        XCTAssertEqual(d.tabs, [.keyboard, .mouse, .controller, .playport])
        XCTAssertEqual(d.tab, .keyboard)       // nothing bound: the first tab
    }

    func testTheCursorMovesLikeTheKeyboardsAndSwitchingTabsStartsAtTheTop() {
        var p = ActionPicker(for: .control(.a), title: "", current: .key(0x51, []))   // Q
        XCTAssertEqual(p.cell?.id, "key:0x51")
        p.move(.up)                             // over Q: 1
        XCTAssertEqual(p.cell?.id, "key:0x31")
        p.move(.down)                           // back to Q, not W
        XCTAssertEqual(p.cell?.id, "key:0x51")
        p.move(.left)
        XCTAssertEqual(p.cell?.id, "key:0x09")  // Tab
        p.move(.left)                           // stops at the end
        XCTAssertEqual(p.cell?.id, "key:0x09")
        for _ in 0..<10 { p.move(.down) }
        XCTAssertEqual(p.cell?.id, "mod:shift") // the chips' row, at the bottom
        p.switchTab(by: 1)
        XCTAssertEqual(p.tab, .mouse)
        XCTAssertEqual(p.cell?.id, "mouse:left")
        p.switchTab(by: -1)
        XCTAssertEqual(p.cell?.id, "key:0x1B")
    }

    func testModifiersComposeIntoTheKeysName() {
        var p = ActionPicker(for: .control(.a), title: "", current: .key(0x31, .shift))
        XCTAssertEqual(p.modifiers, .shift)    // the current key's modifiers start on
        XCTAssertEqual(p.choose(), .chosen(.key(0x31, .shift)))
        if case .chosen(let a?) = p.choose() { XCTAssertEqual(a.name, "key:shift+0x31") } else { XCTFail() }
        p.toggle(.control)
        p.toggle(.shift)
        XCTAssertEqual(p.choose(), .chosen(.key(0x31, .control)))
        // A chip with A: on and off, nothing chosen.
        for _ in 0..<10 { p.move(.down) }
        XCTAssertEqual(p.cell?.id, "mod:shift")
        XCTAssertEqual(p.choose(), .none)
        XCTAssertEqual(p.modifiers, [.shift, .control])
        // A modifier key never carries itself: Alt with Shift, Ctrl and Alt on is Shift+Ctrl+Alt.
        p.toggle(.alt)
        p.move(.up)
        XCTAssertEqual(p.cell?.id, "key:0xA4")   // left Alt, under the column the cursor came down
        XCTAssertEqual(p.choose(), .chosen(.key(0xA4, [.shift, .control])))
        // The mouse and the pad take no modifiers.
        p.select(.mouse)
        XCTAssertEqual(p.choose(), .chosen(.mouse(.left)))
        p.select(.controller)
        XCTAssertEqual(p.choose(), .chosen(.pad(.a)))
        XCTAssertEqual(ActionText.name(.key(0x31, [.shift, .control])), "Shift+Ctrl+1")
        XCTAssertEqual(InputAction.key(0x31, [.shift, .control]).name, "key:shift+ctrl+0x31")
    }

    func testRecentChoicesNewestFirstOnceAndAtMostTheLimit() {
        var list: [InputAction] = []
        for vk in [UInt8(0x45), 0x52, 0x46, 0x45] { list = ActionPickerRecent.adding(.key(vk, []), to: list) }
        XCTAssertEqual(list, [.key(0x45, []), .key(0x46, []), .key(0x52, [])])
        for vk in UInt8(0x30)...UInt8(0x39) { list = ActionPickerRecent.adding(.key(vk, []), to: list) }
        XCTAssertEqual(list.count, ActionPickerRecent.limit)
        XCTAssertEqual(list.first, .key(0x39, []))
        let d = UserDefaults(suiteName: "ActionPickerTests")!
        d.removePersistentDomain(forName: "ActionPickerTests")
        ActionPickerRecent.save([.key(0x45, .shift), .mouse(.move)], d)
        XCTAssertEqual(ActionPickerRecent.load(d), [.key(0x45, .shift), .mouse(.move)])
        d.removePersistentDomain(forName: "ActionPickerTests")
        // Shown after the chips, only those the input takes; chosen as they were saved.
        var p = ActionPicker(for: .control(.a), title: "", current: nil, recent: [.mouse(.move), .key(0x45, .shift), .pad(.b)])
        XCTAssertEqual(p.recentShown, [.key(0x45, .shift), .pad(.b)])
        XCTAssertEqual(p.rows.last?.map(\.id), ["mod:shift", "mod:ctrl", "mod:alt", "recent:0", "recent:1"])
        XCTAssertEqual(p.rows.last?[3].label, "Shift+E")
        let bottom = p.rows.count - 1
        XCTAssertEqual(p.tap(row: bottom, column: 3), .chosen(.key(0x45, .shift)))
        p.select(.mouse)                        // other tabs show the recent choices without the chips
        XCTAssertEqual(p.rows.last?.map(\.id), ["recent:0", "recent:1"])
        let stick = ActionPicker(for: .control(.leftStick), title: "", current: nil, recent: [.mouse(.move), .key(0x45, [])])
        XCTAssertEqual(stick.recentShown, [.mouse(.move)])
    }

    func testARealKeyWithHeldModifiers() {
        var c = RealKeyCapture()
        XCTAssertNil(c.down(0xA0, held: .shift))                  // Shift down: wait
        XCTAssertEqual(c.down(0x31, held: .shift), .key(0x31, .shift))
        XCTAssertNil(c.up(0x31))
        XCTAssertNil(c.up(0xA0))                                  // Shift was not alone
        XCTAssertNil(c.down(0xA2, held: .control))
        XCTAssertEqual(c.up(0xA2), .key(0xA2, []))                // Ctrl alone is itself
        XCTAssertEqual(c.down(0x20, held: []), .key(0x20, []))
        // The picker takes it only while listening (X), with its chips added.
        var p = ActionPicker(for: .control(.a), title: "", current: nil)
        XCTAssertEqual(p.realKey(.key(0x46, [])), .none)
        p.listen(true)
        XCTAssertTrue(p.listening)
        p.toggle(.alt)
        XCTAssertEqual(p.realKey(.key(0x46, .shift)), .chosen(.key(0x46, [.shift, .alt])))
        XCTAssertFalse(p.listening)
        // A whole stick takes no keys: nothing to listen for.
        var s = ActionPicker(for: .control(.rightStick), title: "", current: nil)
        s.listen(true)
        XCTAssertFalse(s.listening)
    }

    func testKeyNames() {
        XCTAssertEqual(ActionText.key(0x41), "A")
        XCTAssertEqual(ActionText.key(0x35), "5")
        XCTAssertEqual(ActionText.key(0x74), "F5")
        XCTAssertEqual(ActionText.key(0x1B), "Esc")
        XCTAssertEqual(ActionText.key(0x25), "←")
        XCTAssertEqual(ActionText.key(0xFF), "VK 0xFF")
        // Every key KeyMap gives a hardware key has a name.
        for u in 0...0xE7 { if let vk = KeyMap.virtualKey(hidUsage: u) { XCTAssertFalse(ActionText.key(vk).hasPrefix("VK"), "\(u)") } }
        XCTAssertEqual(ActionText.name(nil), "Nothing")
        XCTAssertEqual(ActionText.name(.pad(.start)), "Pad Menu")
        XCTAssertEqual(ActionText.name(.mouse(.move)), "Mouse look")
    }
}
