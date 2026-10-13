// SPDX-License-Identifier: GPL-3.0-or-later
// The on-screen controls' settings (PlayportKit Controls.swift): Settings ›
// Controls' defaults under their own UserDefaults keys (ControlsDefaults), and
// each game's own (GameControls) as JSON under one key, by catalogue id, read
// record by record (PlayportKit GameControlsRecords: a record this build cannot
// read is written back as it came; a value that is not a JSON object at all is
// never written over). Gyro
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

    /// Every game's own controls, JSON [title id: GameControls] (GameControlsRecords).
    static let gamesKey = "controls.games"

    @Published private(set) var defaults = ControlsDefaults(.standard)
    /// Settings › Controls › Gyro aim (the `gyro.*` keys).
    @Published private(set) var gyroDefaults = GyroSettings(.standard)
    @Published private var games: GameControlsRecords
    /// What is stored under `gamesKey` could not be read at all: a change applies, but is not saved over it.
    private var gamesUnreadable = false
    private var observer: NSObjectProtocol?

    private init() {
        let loaded = Self.loadGames()
        games = loaded ?? GameControlsRecords()
        gamesUnreadable = loaded == nil
        // Settings' rows and the driver's set: write the keys themselves.
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { ControlsStore.shared.reload() }
        }
    }

    /// The stored records; none stored is empty, nil when what is stored is not a JSON object.
    private static func loadGames() -> GameControlsRecords? {
        guard let stored = UserDefaults.standard.object(forKey: gamesKey) else { return GameControlsRecords() }
        return (stored as? Data).flatMap(GameControlsRecords.init(json:))
    }

    private func reload() {
        let d = ControlsDefaults(.standard)
        if d != defaults { defaults = d }
        let gd = GyroSettings(.standard)
        if gd != gyroDefaults { gyroDefaults = gd }
        // Reading never writes: an unreadable value keeps what this session holds.
        let g = Self.loadGames()
        gamesUnreadable = g == nil
        if let g, g != games { games = g }
    }

    func game(_ id: String) -> GameControls { games[id] ?? GameControls() }

    /// A game's gyro aim: its own over the defaults.
    func gyro(_ id: String) -> GyroSettings { game(id).gyroSettings(over: gyroDefaults) }

    /// A game's own controls; one left with nothing set is dropped.
    func setGame(_ id: String, _ c: GameControls) {
        games.set(id, c)
        guard !gamesUnreadable, let json = try? games.json() else { return }
        UserDefaults.standard.set(json, forKey: Self.gamesKey)
    }
}
