// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only destinations: row selection never activates the row's edit action.
enum UIDriverGameSection: String, CaseIterable {
    case graphics, controls, game, files, developer, ordering, steam, gyro, controller, runtime, graphicsoptions

    func row(firstOrdering: String) -> String? {
        switch self {
        case .graphics: "opt:aspect"
        case .controls: "opt:layout"
        case .game: "opt:version"
        case .files: "opt:files"
        case .developer, .ordering: "opt:ordering-\(firstOrdering)"
        case .steam: "opt:steamAPI"
        case .runtime: "opt:runtime"
        case .graphicsoptions: "opt:graphicsOptions"
        case .gyro, .controller: nil
        }
    }
}
