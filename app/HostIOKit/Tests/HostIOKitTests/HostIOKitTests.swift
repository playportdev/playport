// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import HostIOKit

final class KeyMapTests: XCTestCase {
    func testLettersDigitsAndTheSessionKey() {
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x04), 0x41)   // A
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x1A), 0x57)   // W
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x1D), 0x5A)   // Z
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x1E), 0x31)   // 1
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x26), 0x39)   // 9
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x27), 0x30)   // 0
    }

    func testNamedKeys() {
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x28), 0x0D)
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x29), 0x1B)
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x2C), 0x20)
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x3A), 0x70)   // F1
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x45), 0x7B)   // F12
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x68), 0x7C)   // F13
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x73), 0x87)   // F24
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x50), 0x25)   // Left
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x52), 0x26)   // Up
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x59), 0x61)   // keypad 1
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0x62), 0x60)   // keypad 0
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0xE1), 0xA0)   // left Shift
        XCTAssertEqual(KeyMap.virtualKey(hidUsage: 0xE7), 0x5C)   // right GUI
    }

    func testUnmappedKeysAreNotForwarded() {
        XCTAssertNil(KeyMap.virtualKey(hidUsage: 0))
        XCTAssertNil(KeyMap.virtualKey(hidUsage: 0x66))   // Power
        XCTAssertNil(KeyMap.virtualKey(hidUsage: 0x7F))   // Mute
    }

    func testNoTwoPrintableKeysShareAVK() {
        var seen: [UInt8: Int] = [:]
        for u in 0x04...0x38 where u != 0x32 {   // 0x32 (non-US #) is the backslash position on purpose
            let vk = KeyMap.virtualKey(hidUsage: u)!
            XCTAssertNil(seen[vk], "usage \(u) and \(seen[vk] ?? 0) both map to \(vk)")
            seen[vk] = u
        }
    }
}

final class PointerTests: XCTestCase {
    func testClientFraction() {
        XCTAssertEqual(Pointer.clientFraction(x: 0, y: 0, width: 640, height: 360).map { [$0.0, $0.1] }, [0, 0])
        XCTAssertEqual(Pointer.clientFraction(x: 320, y: 180, width: 640, height: 360).map { [$0.0, $0.1] }, [32768, 32768])
        XCTAssertEqual(Pointer.clientFraction(x: 639.999, y: 359.999, width: 640, height: 360).map { [$0.0, $0.1] }, [65535, 65535])
        XCTAssertNil(Pointer.clientFraction(x: 640, y: 10, width: 640, height: 360))
        XCTAssertNil(Pointer.clientFraction(x: -1, y: 10, width: 640, height: 360))
        XCTAssertNil(Pointer.clientFraction(x: 1, y: 1, width: 0, height: 360))
    }

    /// Winios turns the fraction back into a client pixel as fx * width / 65536
    /// (patches/madeira-winios/0002-Winios-accept-pointer-and-focus-events-posted-by-the.patch): a touch lands on the pixel under it.
    func testRoundTripToClientPixels() {
        for (w, h) in [(640, 360), (512, 288), (1170, 2532)] {
            for px in stride(from: 0, to: w, by: 7) {
                let f = Pointer.clientFraction(x: Double(px) + 0.5, y: 0.5, width: Double(w), height: Double(h))!
                XCTAssertEqual(Int(f.0) * w / 65536, px, "\(w)x\(h) x=\(px)")
            }
        }
    }

    func testRelativeMotionCarriesFractions() {
        var m = RelativeMotion()
        XCTAssertNil(m.add(dx: 0.4, dy: -0.4))
        XCTAssertEqual(m.add(dx: 0.7, dy: -0.7).map { [$0.0, $0.1] }, [1, -1])
        m.reset()
        var sx: Int32 = 0, sy: Int32 = 0
        for _ in 0..<1000 { if let d = m.add(dx: 0.25, dy: 0.5) { sx += d.0; sy += d.1 } }
        XCTAssertEqual(sx, 250)
        XCTAssertEqual(sy, 500)
        XCTAssertEqual(m.add(dx: -0.9, dy: -1.2).map { [$0.0, $0.1] }, [0, -1])   // toward zero, sign kept
        m.reset()
        XCTAssertNil(m.add(dx: 0.9, dy: 0))
    }
}

final class PadTests: XCTestCase {
    func testButtonsAreXInputBits() {
        var p = PadInput()
        p.a = true
        XCTAssertEqual(PadMapping.values(p).buttons, 0x1000)   // XINPUT_GAMEPAD_A: the session's controller stage
        p = PadInput()
        p.up = true; p.menu = true; p.options = true; p.rightShoulder = true; p.y = true
        XCTAssertEqual(PadMapping.values(p).buttons, 0x0001 | 0x0010 | 0x0020 | 0x0200 | 0x8000)
    }

    func testAxes() {
        var p = PadInput()
        p.lx = 1; p.ly = -1; p.rx = 0.5; p.ry = 0; p.leftTrigger = 1; p.rightTrigger = 0.5
        let v = PadMapping.values(p)
        XCTAssertEqual([v.lx, v.ly, v.rx, v.ry], [32767, -32768, 16384, 0])
        XCTAssertEqual([v.leftTrigger, v.rightTrigger], [255, 128])
        p.lx = 3; p.ly = -.infinity; p.leftTrigger = .nan
        let w = PadMapping.values(p)
        XCTAssertEqual([w.lx, w.ly], [32767, 0])
        XCTAssertEqual(w.leftTrigger, 0)
    }

    func testRestIsAllZero() {
        XCTAssertEqual(PadMapping.values(PadInput()), PadValues())
    }

    func testSlots() {
        var s = PadSlots<String>()
        XCTAssertEqual(s.connect("a"), 0)
        XCTAssertEqual(s.connect("b"), 1)
        XCTAssertEqual(s.connect("a"), 0)
        XCTAssertEqual(s.disconnect("a"), 0)
        XCTAssertEqual(s.connect("c"), 0)          // lowest free slot
        XCTAssertEqual(s.slot(of: "b"), 1)         // b did not move
        XCTAssertEqual(s.connect("d"), 2)
        XCTAssertEqual(s.connect("e"), 3)
        XCTAssertNil(s.connect("f"))               // XInput has four
        XCTAssertNil(s.disconnect("zz"))
    }
}

final class LifecycleTests: XCTestCase {
    /// Focus held: hold W and pad A, swipe home, come back.
    func testFocusLossComesBeforeTheReleases() {
        var l = Lifecycle()
        XCTAssertTrue(l.keyDown(0x57))
        XCTAssertFalse(l.keyDown(0x57))            // key repeat is not forwarded
        XCTAssertTrue(l.buttonDown(upFlag: Pointer.leftUp))
        XCTAssertEqual(l.handle(.resignActive), [.focus(false), .releaseKeys([0x57]), .releaseButtons([Pointer.leftUp])])
        XCTAssertEqual(l.handle(.resignActive), [])
        XCTAssertEqual(l.handle(.enterBackground), [.gpu(false), .suspendAudio(deactivate: true)])
        XCTAssertFalse(l.keyUp(0x57))              // UIKit's late pressesEnded is not sent twice
        XCTAssertEqual(l.handle(.enterForeground), [.gpu(true)])
        XCTAssertEqual(l.handle(.becomeActive), [.focus(true), .resumeAudio])
        XCTAssertEqual(l.handle(.becomeActive), [])
    }

    func testOverlayWithoutBackgroundKeepsAudio() {
        var l = Lifecycle()
        XCTAssertEqual(l.handle(.resignActive), [.focus(false)])   // Control Center, a notification
        XCTAssertEqual(l.handle(.becomeActive), [.focus(true)])
        XCTAssertFalse(l.audioSuspended)
        XCTAssertFalse(l.gpuHeld)                  // still on screen: the GPU stays usable
    }

    /// An audio interruption: Siri. The session is interrupted,
    /// and the app resigns active around it; audio returns when both have cleared.
    func testInterruptionResumesOnlyWhenActive() {
        var l = Lifecycle()
        XCTAssertEqual(l.handle(.resignActive), [.focus(false)])
        XCTAssertEqual(l.handle(.interruptionBegan), [.suspendAudio(deactivate: false)])
        XCTAssertEqual(l.handle(.becomeActive), [.focus(true)])   // still interrupted
        XCTAssertEqual(l.handle(.interruptionEnded), [.resumeAudio])
        XCTAssertFalse(l.audioSuspended)

        var m = Lifecycle()
        XCTAssertEqual(m.handle(.interruptionBegan), [.suspendAudio(deactivate: false)])
        XCTAssertEqual(m.handle(.resignActive), [.focus(false)])
        XCTAssertEqual(m.handle(.interruptionEnded), [])          // not active yet
        XCTAssertEqual(m.handle(.becomeActive), [.focus(true), .resumeAudio])
    }

    /// Lock: resign, background, then back.
    func testLockAndUnlock() {
        var l = Lifecycle()
        XCTAssertEqual(l.handle(.resignActive), [.focus(false)])
        XCTAssertEqual(l.handle(.enterBackground), [.gpu(false), .suspendAudio(deactivate: true)])
        XCTAssertEqual(l.handle(.interruptionBegan), [])           // already suspended
        XCTAssertEqual(l.handle(.enterForeground), [.gpu(true)])
        XCTAssertEqual(l.handle(.interruptionEnded), [])           // not active yet
        XCTAssertEqual(l.handle(.becomeActive), [.focus(true), .resumeAudio])
    }

    /// The 2026-09-24 pad session: three trips to the Home Screen, and on the
    /// third a readback of a copy iOS refused in the background. Every trip
    /// closes the gate once, before the audio, and every return opens it once.
    func testGpuGateFollowsTheBackground() {
        var l = Lifecycle()
        for _ in 0..<3 {
            XCTAssertEqual(l.handle(.resignActive), [.focus(false)])
            XCTAssertEqual(l.handle(.enterBackground).first, .gpu(false))
            XCTAssertTrue(l.gpuHeld)
            XCTAssertEqual(l.handle(.enterBackground), [])         // repeated: nothing again
            XCTAssertEqual(l.handle(.interruptionBegan), [])       // in the background: the gate is already shut
            XCTAssertEqual(l.handle(.enterForeground), [.gpu(true)])
            XCTAssertEqual(l.handle(.enterForeground), [])
            XCTAssertEqual(l.handle(.interruptionEnded), [])
            XCTAssertEqual(l.handle(.becomeActive), [.focus(true), .resumeAudio])
            XCTAssertFalse(l.gpuHeld)
        }
    }

    func testMediaServicesResetWhileActiveResumes() {
        var l = Lifecycle()
        XCTAssertEqual(l.handle(.mediaServicesReset), [.suspendAudio(deactivate: false), .resumeAudio])
    }

    func testKeysReleasedInPressOrder() {
        var l = Lifecycle()
        _ = l.keyDown(0xA0); _ = l.keyDown(0x57); _ = l.keyDown(0x41)
        XCTAssertTrue(l.keyUp(0x57))
        XCTAssertEqual(l.handle(.resignActive).first(where: { if case .releaseKeys = $0 { return true }; return false }),
                       .releaseKeys([0xA0, 0x41]))
        XCTAssertEqual(l.heldKeys, [])
    }
}

final class InputTraceTests: XCTestCase {
    func testMouseSummaryShowsCallsAgainstPushes() {
        var t = InputTrace()
        let start = t
        XCTAssertNil(t.summary(since: start))
        var m = RelativeMotion()
        for _ in 0..<4 {
            let d = m.add(dx: 0.5, dy: -0.25)
            t.mouseMoved(dx: 0.5, dy: -0.25, pushed: d)
        }
        XCTAssertEqual(t.summary(since: start), "hostio: input mouse moves=4 d=(2,-1) pushes=2 px=(2,-1) buttons=0 wheel=0")
        let mid = t
        XCTAssertNil(t.summary(since: mid))
        t.touches += 2; t.pointerTouches += 1
        XCTAssertEqual(t.summary(since: mid), "hostio: input touches finger=2 pointer=1 hover=0")
    }

    func testPadLinesOnButtonAndTriggerChangesOnly() {
        var t = InputTrace()
        var v = PadValues()
        XCTAssertEqual(t.pad(slot: 0, v), "hostio: pad0 buttons=0x0000 lt=0 rt=0 l=(0,0) r=(0,0)")   // the first write
        v.lx = 1200
        XCTAssertNil(t.pad(slot: 0, v))                                                            // a stick moved
        v.buttons = PadMapping.a
        XCTAssertEqual(t.pad(slot: 0, v), "hostio: pad0 buttons=0x1000 lt=0 rt=0 l=(1200,0) r=(0,0)")
        v.rightTrigger = 40
        XCTAssertNotNil(t.pad(slot: 0, v))                                                         // trigger pressed
        v.rightTrigger = 90
        XCTAssertNil(t.pad(slot: 0, v))                                                            // still pressed
        XCTAssertEqual(t.summary(since: InputTrace()), "hostio: input pad0 buttons=0x1000 lt=0 rt=90 l=(1200,0) r=(0,0) calls=5")
    }
}

final class DisplayTests: XCTestCase {
    func testGuestSize() {
        // iPhone Air: 1260 × 2736 native pixels, either way round.
        XCTAssertEqual(Display.guestSize(panelLong: 2736, panelShort: 1260, spec: nil).map { [$0.0, $0.1] }, [2736, 1260])
        XCTAssertEqual(Display.guestSize(panelLong: 1260, panelShort: 2736, spec: "").map { [$0.0, $0.1] }, [2736, 1260])
        XCTAssertEqual(Display.guestSize(panelLong: 2736, panelShort: 1260, spec: "native").map { [$0.0, $0.1] }, [2736, 1260])
        XCTAssertEqual(Display.guestSize(panelLong: 2736, panelShort: 1260, spec: "720").map { [$0.0, $0.1] }, [1564, 720])
        XCTAssertNil(Display.guestSize(panelLong: 2736, panelShort: 1260, spec: "2000"))
        XCTAssertEqual(Display.guestSize(panelLong: 2736, panelShort: 1260, spec: "4:3").map { [$0.0, $0.1] }, [1024, 768])
        XCTAssertEqual(Display.guestSize(panelLong: 2736, panelShort: 1260, spec: "1920x1080").map { [$0.0, $0.1] }, [1920, 1080])
        XCTAssertNil(Display.guestSize(panelLong: 2736, panelShort: 1260, spec: "wide"))
        XCTAssertNil(Display.guestSize(panelLong: 2736, panelShort: 1260, spec: "10x10"))
        XCTAssertNil(Display.guestSize(panelLong: 0, panelShort: 1260, spec: nil))
    }

    func testUnityScreenArgs() {
        XCTAssertEqual(Display.unityScreenArgs(existing: ["-logFile", "C:\\p.log"], width: 2736, height: 1260),
                       ["-screen-fullscreen", "1", "-screen-width", "2736", "-screen-height", "1260"])
        XCTAssertEqual(Display.unityScreenArgs(existing: ["-screen-width", "800"], width: 2736, height: 1260), [])
        XCTAssertEqual(Display.unityScreenArgs(existing: ["-Window-Mode", "borderless"], width: 2736, height: 1260), [])
        XCTAssertEqual(Display.unityScreenArgs(existing: ["-popupwindow"], width: 2736, height: 1260), [])
    }

    func testAspectFit() {
        // 4:3 in a 912 × 420 landscape view: pillarboxed, centred.
        let f = Display.aspectFit(contentWidth: 1024, contentHeight: 768, width: 912, height: 420)
        XCTAssertEqual(f.0, 176, accuracy: 1e-9); XCTAssertEqual(f.1, 0, accuracy: 1e-9)
        XCTAssertEqual(f.2, 560, accuracy: 1e-9); XCTAssertEqual(f.3, 420, accuracy: 1e-9)
        // Wider than the view: letterboxed.
        let g = Display.aspectFit(contentWidth: 2000, contentHeight: 500, width: 1000, height: 500)
        XCTAssertEqual(g.1, 125, accuracy: 1e-9); XCTAssertEqual(g.3, 250, accuracy: 1e-9)
        // Unknown content size: the whole view, as a stretched layer.
        let h = Display.aspectFit(contentWidth: 0, contentHeight: 0, width: 912, height: 420)
        XCTAssertEqual([h.0, h.1, h.2, h.3], [0, 0, 912, 420])
    }
}

final class PadScriptTests: XCTestCase {
    func testParsesStepsControlsAndComments() throws {
        let s = try PadScript.parse("""
            # walk, jump, rest
            2000 RIGHT
            300  right a lt=0.5 LX=-1   # jump
            500  -

            """)
        XCTAssertEqual(s.steps.count, 3)
        XCTAssertFalse(s.loops)
        XCTAssertEqual(s.totalMs, 2800)
        XCTAssertTrue(s.steps[0].input.right)
        var jump = PadInput(); jump.right = true; jump.a = true; jump.leftTrigger = 0.5; jump.lx = -1
        XCTAssertEqual(s.steps[1].input, jump)
        XCTAssertEqual(s.steps[2].input, PadInput())
        XCTAssertEqual(PadMapping.values(s.steps[1].input).buttons, PadMapping.dpadRight | PadMapping.a)
    }

    func testTimeline() throws {
        let s = try PadScript.parse("100 A\n200 B\n")
        XCTAssertEqual(s.at(ms: 0).step, 0)
        XCTAssertEqual(s.at(ms: 99).step, 0)
        XCTAssertEqual(s.at(ms: 100).step, 1)
        XCTAssertTrue(s.at(ms: 299).input.b)
        XCTAssertNil(s.at(ms: 300).step)
        XCTAssertEqual(s.at(ms: 5000).input, PadInput())
        let l = try PadScript.parse("100 A\n200 B\nloop")
        XCTAssertEqual(l.at(ms: 300).step, 0)
        XCTAssertEqual(l.at(ms: 450).step, 1)
        XCTAssertNil(PadScript().at(ms: 0).step)
    }

    func testRejectsWhatItCannotPlay() {
        for bad in ["x A", "-5 A", "100 Z", "100 A=1", "100 LX", "100 LX=2", "100 LT=-1", "100 - =", "loop now", "0 A\nloop"] {
            XCTAssertThrowsError(try PadScript.parse(bad), bad)
        }
        XCTAssertEqual((try? PadScript.parse("100 A\n100 Q")) == nil, true)
        do { _ = try PadScript.parse("100 A\n100 Q") } catch let e as PadScript.ParseError { XCTAssertEqual(e.line, 2) } catch { XCTFail("\(error)") }
    }
}

final class FramePacerTests: XCTestCase {
    func testThePacerHoldsFramesToTheLimitAndResyncsAfterALateOne() {
        var p = FramePacer(fps: 50)
        XCTAssertEqual(p.delay(now: 10), 0)
        XCTAssertEqual(p.delay(now: 10.005), 0.015, accuracy: 1e-9)
        XCTAssertEqual(p.delay(now: 10.021), 0.019, accuracy: 1e-9)
        // Late by 60 ms: no burst to catch up.
        XCTAssertEqual(p.delay(now: 10.12), 0)
        XCTAssertEqual(p.delay(now: 10.13), 0.01, accuracy: 1e-9)
        var off = FramePacer(fps: 0)
        XCTAssertEqual(off.delay(now: 1), 0)
        XCTAssertEqual(off.delay(now: 1), 0)
    }
}

final class PadNavigationTests: XCTestCase {
    private func pad(_ set: (inout PadInput) -> Void) -> PadInput {
        var p = PadInput()
        set(&p)
        return p
    }

    func testAButtonCountsOnceAsItGoesDown() {
        var nav = PadNavigation()
        XCTAssertEqual(nav.update(pad { $0.a = true }, at: 0), [.a])
        XCTAssertEqual(nav.update(pad { $0.a = true; $0.lx = 0.1 }, at: 0.1), [])
        XCTAssertEqual(nav.tick(at: 5), [])
        XCTAssertEqual(nav.update(PadInput(), at: 0.2), [])
        XCTAssertEqual(nav.update(pad { $0.a = true }, at: 0.3), [.a])
    }

    func testShouldersAndMenu() {
        var nav = PadNavigation()
        XCTAssertEqual(nav.update(pad { $0.leftShoulder = true; $0.menu = true }, at: 0), [.lb, .menu])
    }

    func testAHeldDirectionRepeatsAfterTheDelay() {
        var nav = PadNavigation()
        XCTAssertEqual(nav.update(pad { $0.right = true }, at: 0), [.right])
        XCTAssertEqual(nav.tick(at: 0.3), [])
        XCTAssertEqual(nav.tick(at: 0.4), [.right])
        XCTAssertEqual(nav.tick(at: 0.45), [])
        XCTAssertEqual(nav.tick(at: 0.52), [.right])
        // A stalled clock gives one repeat, not a burst.
        XCTAssertEqual(nav.tick(at: 3), [.right])
        XCTAssertEqual(nav.tick(at: 3.01), [])
        XCTAssertEqual(nav.update(PadInput(), at: 3.1), [])
        XCTAssertFalse(nav.isRepeating)
        XCTAssertEqual(nav.tick(at: 9), [])
    }

    func testTheLastDirectionPressedRepeats() {
        var nav = PadNavigation()
        _ = nav.update(pad { $0.right = true }, at: 0)
        XCTAssertEqual(nav.update(pad { $0.right = true; $0.down = true }, at: 0.2), [.down])
        XCTAssertEqual(nav.tick(at: 0.61), [.down])
    }

    func testTheStickHasHysteresis() {
        var nav = PadNavigation()
        XCTAssertEqual(nav.update(pad { $0.lx = 0.45 }, at: 0), [])
        XCTAssertEqual(nav.update(pad { $0.lx = 0.6; $0.ly = 0.2 }, at: 0.1), [.right])
        XCTAssertEqual(nav.update(pad { $0.lx = 0.35 }, at: 0.2), [])       // still held
        XCTAssertEqual(nav.update(pad { $0.lx = 0.2 }, at: 0.3), [])        // let go
        XCTAssertEqual(nav.update(pad { $0.lx = 0.6 }, at: 0.4), [.right])  // again
        XCTAssertEqual(nav.update(pad { $0.ly = -0.9 }, at: 0.5), [.down])  // +y is up
    }

    func testResetLetsEverythingGo() {
        var nav = PadNavigation()
        _ = nav.update(pad { $0.a = true; $0.up = true }, at: 0)
        nav.reset()
        XCTAssertEqual(nav.tick(at: 1), [])
        XCTAssertEqual(nav.update(pad { $0.a = true; $0.up = true }, at: 1), [.a, .up])
    }
}

final class InGameMenuTests: XCTestCase {
    private func input(_ set: (inout PadInput) -> Void = { _ in }) -> PadInput {
        var p = PadInput()
        set(&p)
        return p
    }

    func testAHeldHomeOpensTheMenuAndAShortPressDoesNot() {
        var c = QuickMenuControl()
        XCTAssertEqual(c.update(input { $0.home = true }, at: 0), [])
        XCTAssertTrue(c.needsClock)
        XCTAssertEqual(c.tick(at: 0.3), [])
        XCTAssertEqual(c.update(input(), at: 0.4), [])          // let go too soon
        XCTAssertFalse(c.needsClock)
        XCTAssertEqual(c.tick(at: 1), [])
        XCTAssertFalse(c.isOpen)

        XCTAssertEqual(c.update(input { $0.home = true }, at: 2), [])
        XCTAssertEqual(c.tick(at: 2.5), [.open])
        XCTAssertTrue(c.isOpen)
        XCTAssertEqual(c.update(input(), at: 2.9), [])          // letting go of that hold keeps it open
        XCTAssertTrue(c.isOpen)
    }

    func testTheMenuTakesPressesAndHomeClosesIt() {
        var c = QuickMenuControl()
        _ = c.update(input { $0.home = true; $0.a = true }, at: 0)
        XCTAssertEqual(c.update(input { $0.home = true; $0.a = true }, at: 0.6), [.open])
        XCTAssertEqual(c.update(input { $0.a = true }, at: 0.7), [])   // A was down before: not a press
        XCTAssertEqual(c.update(input(), at: 0.8), [])
        XCTAssertEqual(c.update(input { $0.down = true }, at: 0.9), [.press(.down)])
        XCTAssertTrue(c.needsClock)                                      // the held direction repeats
        XCTAssertEqual(c.tick(at: 1.35), [.press(.down)])
        XCTAssertEqual(c.update(input { $0.b = true }, at: 1.4), [.press(.b)])
        XCTAssertEqual(c.update(input { $0.home = true }, at: 1.5), [.close])
        XCTAssertFalse(c.isOpen)
        XCTAssertEqual(c.update(input(), at: 1.6), [])
        XCTAssertEqual(c.tick(at: 3), [])                                // that press was not a new hold
    }

    func testClosedFromTheUIStartsOver() {
        var c = QuickMenuControl()
        _ = c.update(input { $0.home = true }, at: 0)
        XCTAssertEqual(c.tick(at: 0.5), [.open])
        _ = c.update(input(), at: 0.6)
        c.closed()
        XCTAssertFalse(c.isOpen)
        XCTAssertEqual(c.update(input { $0.a = true }, at: 0.7), [])
        _ = c.update(input { $0.home = true }, at: 1)
        XCTAssertEqual(c.update(input { $0.home = true; $0.x = true }, at: 1.6), [.open])
    }

    func testTheGuestSeesNothingWhileHeldAndNotTheButtonThatClosedTheMenu() {
        var g = GuestPadGate()
        var a = PadValues(); a.buttons = PadMapping.a
        var rest = PadValues()
        XCTAssertEqual(g.input(slot: 0, rest), rest)
        XCTAssertEqual(g.hold(), [0])
        XCTAssertEqual(g.hold(), [])
        XCTAssertNil(g.input(slot: 0, a))                  // the menu's A
        var left = PadValues(); left.lx = -32768
        XCTAssertNil(g.input(slot: 1, left))                // a pad that connected while the menu was up
        let back = g.release()
        XCTAssertEqual(back.map(\.slot), [0, 1])
        XCTAssertEqual(back[0].values, rest)                 // A still down: kept up for the game
        XCTAssertEqual(back[1].values, left)
        var ab = a; ab.buttons |= PadMapping.b
        XCTAssertEqual(g.input(slot: 0, ab).map(\.buttons), PadMapping.b)
        XCTAssertEqual(g.input(slot: 0, rest), rest)       // A let go
        XCTAssertEqual(g.input(slot: 0, a), a)              // and pressed again: the game's
        g.disconnect(slot: 1)
        _ = g.hold()
        XCTAssertEqual(g.release().map(\.slot), [0])
        XCTAssertNil(g.input(slot: 7, a))
    }

    func testTheMenuHoldsAudioAsLongAsItIsUp() {
        var l = Lifecycle()
        XCTAssertEqual(l.handle(.menuOpened), [.suspendAudio(deactivate: false)])
        XCTAssertEqual(l.handle(.menuOpened), [])
        XCTAssertEqual(l.handle(.resignActive), [.focus(false)])
        XCTAssertEqual(l.handle(.becomeActive), [.focus(true)])        // the menu is still up
        XCTAssertEqual(l.handle(.menuClosed), [.resumeAudio])
        XCTAssertEqual(l.handle(.menuClosed), [])

        var m = Lifecycle()
        XCTAssertEqual(m.handle(.enterBackground), [.gpu(false), .suspendAudio(deactivate: true)])
        XCTAssertEqual(m.handle(.menuOpened), [])
        XCTAssertEqual(m.handle(.enterForeground), [.gpu(true)])        // the menu holds it
        XCTAssertEqual(m.handle(.menuClosed), [.resumeAudio])
    }

    func testTheScriptedPadHasHome() throws {
        let s = try PadScript.parse("600 HOME\n100 -\n")
        XCTAssertTrue(s.steps[0].input.home)
        XCTAssertEqual(PadMapping.values(s.steps[0].input), PadValues())   // never the guest's
    }
}
