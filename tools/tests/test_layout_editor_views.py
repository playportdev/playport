# SPDX-License-Identifier: GPL-3.0-or-later
"""Run the editor's real view-cache update with a lightweight view hierarchy."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


class EditorViews(unittest.TestCase):
    def test_resize_move_removal_and_repeated_replacement_leave_one_view_per_control(self):
        if not shutil.which("swiftc"):
            self.skipTest("Swift compiler unavailable")
        source = (REPO / "app/Sources/S1Probe/UI/LayoutEditorView.swift").read_text()
        start = source.index("    private func place(_ e: LayoutEditor)")
        end = source.index("    /// The control as the game draws it", start)
        method = source[start:end]
        stub = r'''
import Foundation
enum ControlAnchor { case center, leading }
struct Control: Equatable {
    var id: String
    var anchor = ControlAnchor.leading
    var x = 0.0, y = 0.0, width = 48.0, height = 48.0
    var floatingZone: Int? = nil
}
struct TouchRect { var x: Double, y: Double, width: Double, height: Double }
extension CGRect {
    init(touch f: TouchRect) { self.init(x: f.x, y: f.y, width: f.width, height: f.height) }
}
class UIView {
    var frame = CGRect.zero
    weak var parent: UIView?
    var subviews: [UIView] = []
    func removeFromSuperview() {
        parent?.subviews.removeAll { $0 === self }
        parent = nil
    }
    func addSubview(_ view: UIView) {
        view.removeFromSuperview()
        subviews.append(view); view.parent = self
    }
}
struct Layout { var controls: [Control] }
struct LayoutEditor {
    var layout: Layout
    func frame(of id: String) -> TouchRect? {
        guard let c = layout.controls.first(where: { $0.id == id }) else { return nil }
        return TouchRect(x: c.x, y: c.y, width: c.width, height: c.height)
    }
}
class Canvas {
    let controlsLayer = UIView()
    var views: [String: (key: Control, view: UIView)] = [:]
    static func container(_ c: Control, frame: CGRect) -> UIView {
        let result = UIView(); result.frame = frame; return result
    }
    func show(_ controls: [Control]) { place(LayoutEditor(layout: Layout(controls: controls))) }
'''
        cases = r'''
}
let canvas = Canvas()
var button = Control(id: "button")
canvas.show([button])
let original = canvas.controlsLayer.subviews[0]
button.x = 100; canvas.show([button])
assert(canvas.controlsLayer.subviews.count == 1)
assert(canvas.controlsLayer.subviews[0] === original)
button.width = 96; button.height = 96; canvas.show([button])
assert(canvas.controlsLayer.subviews.count == 1)
assert(original.parent == nil)
let resized = canvas.controlsLayer.subviews[0]
assert(resized !== original)
var other = Control(id: "other")
for size in 24...100 {
    button.width = Double(size); other.width = Double(size + 10)
    canvas.show([button, other])
    assert(canvas.controlsLayer.subviews.count == 2)
    assert(canvas.controlsLayer.subviews[0] === canvas.views["button"]!.view)
    assert(canvas.controlsLayer.subviews[1] === canvas.views["other"]!.view)
}
assert(resized.parent == nil)
canvas.show([other]); assert(canvas.controlsLayer.subviews.count == 1)
assert(canvas.views["button"] == nil)
canvas.show([]); assert(canvas.controlsLayer.subviews.isEmpty)
'''
        work = REPO / ".work"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="editor-views-", dir=work) as tmp:
            root = Path(tmp)
            path = root / "test.swift"
            path.write_text(stub + method + cases)
            binary = root / "test"
            subprocess.run(["swiftc", str(path), "-o", str(binary)], check=True, timeout=120)
            subprocess.run([str(binary)], check=True, timeout=10)
