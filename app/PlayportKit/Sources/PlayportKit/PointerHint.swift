// SPDX-License-Identifier: GPL-3.0-or-later
import HostIOKit

/// The note Point & click shows at the bottom of the screen as a side-bar tool
/// or the Tap to click / Trackpad switch is pressed (TouchPointer.dc.html): what
/// a finger on the game does now. A tool turned off says nothing.
public enum PointerHint {
    /// The tool and the trackpad mode before and after the press.
    public static func text(from before: (tool: PointerTool?, trackpad: Bool),
                            to after: (tool: PointerTool?, trackpad: Bool)) -> String? {
        if after.trackpad != before.trackpad {
            return after.trackpad ? "Trackpad: drag to move the pointer, tap to click" : "Tap to click: the pointer goes where you touch"
        }
        guard after.tool != before.tool, let tool = after.tool else { return nil }
        return switch tool {
        case .rightClick: "Right click is on: your next tap right-clicks"
        case .hover: "Hover is on: your finger moves the pointer without clicking"
        case .scroll: "Scroll is on: drag to scroll"
        case .trackpad: nil
        }
    }
}
