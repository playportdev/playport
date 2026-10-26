// SPDX-License-Identifier: GPL-3.0-or-later
// The virtual gamepad's layouts (S1Probe VirtualGamepad.swift; a game's option on a
// foldable): where each control sits on the pad's half of the panel, how big it is,
// whether it shows, and whether a press buzzes. Settings › Virtual gamepad lists and
// edits them; a game gets the default one when its virtual gamepad is turned on and
// can change to another in its in-game menu. Positions are the control's centre as
// fractions of the pad's area, sizes a factor over the control's own size in a
// 670x470 pt area (scaled with the area).

import Foundation

/// A control of the pad, the face buttons and the d-pad each as one.
public enum PadControl: String, Codable, CaseIterable, Sendable {
    case leftTrigger = "lt", leftBumper = "lb", rightBumper = "rb", rightTrigger = "rt"
    case back, home, start
    case leftStick, rightStick, dpad, face

    public var title: String {
        switch self {
        case .leftTrigger: "LT"
        case .leftBumper: "LB"
        case .rightBumper: "RB"
        case .rightTrigger: "RT"
        case .back: "Back"
        case .home: "Home"
        case .start: "Start"
        case .leftStick: "Left stick"
        case .rightStick: "Right stick"
        case .dpad: "D-pad"
        case .face: "A B X Y"
        }
    }

    /// Home stays: held, it is the only way to Playport's in-game menu from the pad.
    public var canHide: Bool { self != .home }
}

public struct PadPlacement: Codable, Equatable, Sendable {
    /// The centre, 0...1 of the area's width and height.
    public var x: Double, y: Double
    /// Over the control's own size; PadLayout.scales bounds it.
    public var scale: Double
    public var hidden: Bool

    public init(x: Double, y: Double, scale: Double = 1, hidden: Bool = false) {
        self.x = x; self.y = y; self.scale = scale; self.hidden = hidden
    }
}

public struct PadLayout: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// A light tap of the phone's haptics as a control goes down.
    public var haptics: Bool
    /// By PadControl raw value; a control missing here sits where the preset puts it.
    public var placements: [String: PadPlacement]
    /// The preset its missing controls come from.
    public var base: Preset

    public static let scales = 0.5...1.8

    public enum Preset: String, Codable, CaseIterable, Sendable {
        /// The left stick above the d-pad.
        case xbox
        /// The d-pad above the left stick.
        case playstation

        public var title: String {
            switch self {
            case .xbox: "Xbox"
            case .playstation: "PlayStation"
            }
        }
    }

    public init(id: String, name: String, haptics: Bool = true, preset: Preset) {
        self.id = id
        self.name = name
        self.haptics = haptics
        self.base = preset
        self.placements = Self.placements(preset)
    }

    public subscript(_ c: PadControl) -> PadPlacement {
        get { placements[c.rawValue] ?? Self.placements(base)[c.rawValue]! }
        set {
            var p = newValue
            p.x = min(1, max(0, p.x))
            p.y = min(1, max(0, p.y))
            p.scale = min(Self.scales.upperBound, max(Self.scales.lowerBound, p.scale))
            if !c.canHide { p.hidden = false }
            placements[c.rawValue] = p
        }
    }

    /// Every control where the preset puts it, its name and haptics kept.
    public mutating func reset(to preset: Preset) {
        base = preset
        placements = Self.placements(preset)
    }

    /// Xbox's: the shoulders along the top, Back, Home and Start under them, the left
    /// stick and the face buttons high, the d-pad and the right stick low;
    /// PlayStation's swaps the left stick and the d-pad.
    public static func placements(_ preset: Preset) -> [String: PadPlacement] {
        let shoulder = 35.0 / 470, middle = 110.0 / 470, upper = 0.44, lower = 0.76
        var p: [PadControl: PadPlacement] = [
            .leftTrigger: PadPlacement(x: 66.0 / 670, y: shoulder),
            .leftBumper: PadPlacement(x: 172.0 / 670, y: shoulder),
            .rightBumper: PadPlacement(x: 498.0 / 670, y: shoulder),
            .rightTrigger: PadPlacement(x: 604.0 / 670, y: shoulder),
            .back: PadPlacement(x: 0.4, y: middle),
            .home: PadPlacement(x: 0.5, y: middle),
            .start: PadPlacement(x: 0.6, y: middle),
            .rightStick: PadPlacement(x: 0.64, y: lower, scale: 0.85),
            .face: PadPlacement(x: 0.81, y: upper),
        ]
        switch preset {
        case .xbox:
            p[.leftStick] = PadPlacement(x: 0.19, y: upper)
            p[.dpad] = PadPlacement(x: 0.36, y: lower)
        case .playstation:
            p[.dpad] = PadPlacement(x: 0.19, y: upper)
            p[.leftStick] = PadPlacement(x: 0.36, y: lower, scale: 0.9)
        }
        return Dictionary(uniqueKeysWithValues: p.map { ($0.key.rawValue, $0.value) })
    }
}

/// Every layout, in the order Settings lists them, and the one a game gets when its
/// virtual gamepad is turned on. There is always at least one.
public struct PadLayouts: Codable, Equatable, Sendable {
    public private(set) var layouts: [PadLayout]
    public private(set) var defaultID: String

    /// What a phone starts with: Xbox's, the default, and PlayStation's.
    public init() {
        layouts = [PadLayout(id: "xbox", name: "Xbox", preset: .xbox),
                   PadLayout(id: "playstation", name: "PlayStation", preset: .playstation)]
        defaultID = "xbox"
    }

    public var defaultLayout: PadLayout { layouts.first { $0.id == defaultID } ?? layouts[0] }

    /// The layout `id` names, else the default (a game's layout that was deleted).
    public func layout(_ id: String?) -> PadLayout {
        id.flatMap { id in layouts.first { $0.id == id } } ?? defaultLayout
    }

    public func contains(_ id: String) -> Bool { layouts.contains { $0.id == id } }

    /// The one after `id`, back to the first after the last (the in-game menu's row).
    public func next(after id: String?) -> PadLayout {
        let i = layouts.firstIndex { $0.id == layout(id).id } ?? 0
        return layouts[(i + 1) % layouts.count]
    }

    /// A layout replaced by its id, or added at the end.
    public mutating func save(_ l: PadLayout) {
        if let i = layouts.firstIndex(where: { $0.id == l.id }) { layouts[i] = l } else { layouts.append(l) }
    }

    /// A copy of `l` with a new id and a name not taken yet, added at the end.
    @discardableResult
    public mutating func duplicate(_ l: PadLayout, id: String = UUID().uuidString) -> PadLayout {
        var copy = l
        copy.id = id
        copy.name = freeName(l.name + " copy")
        layouts.append(copy)
        return copy
    }

    /// `l` gone, unless it is the last; the default moves to the first if it was the default.
    public mutating func remove(_ id: String) {
        guard layouts.count > 1 else { return }
        layouts.removeAll { $0.id == id }
        if defaultID == id { defaultID = layouts[0].id }
    }

    public mutating func makeDefault(_ id: String) {
        if contains(id) { defaultID = id }
    }

    /// `name`, or `name 2`, `name 3`… when a layout has it.
    public func freeName(_ name: String) -> String {
        let taken = Set(layouts.map(\.name))
        guard taken.contains(name) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let all = try c.decodeIfPresent([PadLayout].self, forKey: .layouts) ?? []
        guard !all.isEmpty else {
            self = PadLayouts()
            return
        }
        let id = try c.decodeIfPresent(String.self, forKey: .defaultID)
        layouts = all
        defaultID = id.flatMap { id in all.contains { $0.id == id } ? id : nil } ?? all[0].id
    }
}
