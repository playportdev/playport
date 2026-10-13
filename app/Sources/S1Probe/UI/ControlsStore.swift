// SPDX-License-Identifier: GPL-3.0-or-later
// The on-screen controls' settings (PlayportKit Controls.swift): Settings ›
// Controls' defaults under their own UserDefaults keys (ControlsDefaults), and
// each game's own (GameControls) as JSON under one key, by catalogue id. Gyro
// aim (PlayportKit GyroSettings.swift) is stored the same way: its defaults under
// the `gyro.*` keys, a game's own (GameGyro) in its GameControls record.
// Unlike launch settings, a change applies at once while the game runs
// (UI/TouchControlsView.swift, OnScreenControls, and GyroSensors.swift read them
// on every change).

import Combine
import Foundation
import PlayportKit

@MainActor
final class ControlsStore: ObservableObject {
    static let shared = ControlsStore()

    /// Every game's own controls, JSON [title id: GameControls].
    static let gamesKey = "controls.games"

    @Published private(set) var defaults = ControlsDefaults(.standard)
    /// Settings › Controls › Gyro aim (the `gyro.*` keys).
    @Published private(set) var gyroDefaults = GyroSettings(.standard)
    @Published private var games: [String: GameControls] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(games), forKey: Self.gamesKey) }
    }
    private var observer: NSObjectProtocol?

    private init() {
        games = Self.loadGames()
        // Settings' rows and the driver's set: write the keys themselves.
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { ControlsStore.shared.reload() }
        }
    }

    private static func loadGames() -> [String: GameControls] {
        UserDefaults.standard.data(forKey: gamesKey)
            .flatMap { try? JSONDecoder().decode([String: GameControls].self, from: $0) } ?? [:]
    }

    private func reload() {
        let d = ControlsDefaults(.standard)
        if d != defaults { defaults = d }
        let gd = GyroSettings(.standard)
        if gd != gyroDefaults { gyroDefaults = gd }
        let g = Self.loadGames()
        if g != games { games = g }
    }

    func game(_ id: String) -> GameControls { games[id] ?? GameControls() }

    /// A game's gyro aim: its own over the defaults.
    func gyro(_ id: String) -> GyroSettings { game(id).gyroSettings(over: gyroDefaults) }

    /// A game's own controls; one left with nothing set is dropped.
    func setGame(_ id: String, _ c: GameControls) {
        games[id] = c.isEmpty ? nil : c.normalized
    }
}
