// SPDX-License-Identifier: GPL-3.0-or-later
/// Point & click's side bar (TouchPointer.dc.html): one translucent plate
/// behind the column the tools are stacked in. A column is the controls with
/// the same left edge and width, each at most `gap` points under the last; a
/// side-bar tool's column (right click, hover, scroll: not the trackpad
/// switch) gets a plate `padX` × `padY` points larger than it.
public enum SideBar {
    public static let gap = 12.0, padX = 7.0, padY = 8.0

    public static func plates(_ targets: [TouchTarget]) -> [TouchRect] {
        var plates: [TouchRect] = []
        for t in targets {
            guard case .tool(let tool) = t.kind, tool != .trackpad else { continue }
            let column = targets.filter { $0.layer == 0 && $0.frame.x == t.frame.x && $0.frame.width == t.frame.width }
                .map(\.frame).sorted { $0.y < $1.y }
            guard var i = column.firstIndex(of: t.frame) else { continue }
            var j = i
            while i > 0, Self.follows(column[i], column[i - 1]) { i -= 1 }
            while j < column.count - 1, Self.follows(column[j + 1], column[j]) { j += 1 }
            let top = column[i].y, bottom = column[j].y + column[j].height
            let plate = TouchRect(x: t.frame.x - padX, y: top - padY, width: t.frame.width + 2 * padX, height: bottom - top + 2 * padY)
            if !plates.contains(plate) { plates.append(plate) }
        }
        return plates
    }

    /// b starts at most `gap` under a's bottom.
    private static func follows(_ b: TouchRect, _ a: TouchRect) -> Bool {
        let space = b.y - (a.y + a.height)
        return space >= 0 && space <= gap
    }
}
