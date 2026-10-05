// SPDX-License-Identifier: GPL-3.0-or-later
// FEX's settings for one launch (decision 0021): the x86 memory ordering from
// Proton's FEX profiles with the game's page over them, and the host CPU
// features FEX cannot find itself on iOS.
//
// Proton on ARM64 gives FEX two configurations: a global one it installs as
// share/fex-emu/Config.json (FEX_APP_CONFIG_LOCATION), and one per launch
// (FEX_APP_CONFIG) whose AppOverrides come from the `proton` script's
// fex_application_profiles, by Steam app ID and then by executable pattern.
// Both are carried here as data (`proton`, `protonApps`), as ValveSoftware/Proton
// has them at `protonSource`, and mapped onto what this build's FEX honours:
//
//   ordering   TSOEnabled, VectorTSOEnabled, MemcpySetTSOEnabled and
//              HalfBarrierTSOEnabled: a game's profile gives the defaults and
//              its page (LaunchSettings.ordering) overrides each one. Proton's
//              global values are the build's own FEX defaults.
//   x87        X87ReducedPrecision: Proton's global value (1, x87 at 64-bit
//              precision; decision 0048) under a game's profile entry; the
//              game's page (LaunchSettings.x87Reduced) overrides it.
//   honoured   Multiblock and MaxInst in a game's profile, passed on as they
//              are; the game's page (LaunchSettings.maxInst) overrides MaxInst.
//   not taken  Proton's other global values: MaxInst=500 would change every
//              game's code generation, which nothing here has measured, and
//              ProfileStats needs the Linux stats shared memory.
//
// FEX reads each as FEX_<NAME> from the environment, the highest of its
// configuration layers (FEX::Config::LoadConfig), so a launch sets them all
// and the game's child processes inherit them. A game's profile is matched
// against the executable the launch runs, as FEX matches AppOverrides.

import Foundation

/// FEX's x86 memory-ordering switches for one game (FEXCore Config.json.in,
/// "Hacks"); nil takes the game's profile.
public struct MemoryOrdering: Codable, Equatable, Hashable, Sendable {
    /// Ordinary loads and stores keep x86's order (FEX `TSOEnabled`).
    public var tso: Bool?
    /// SSE and AVX loads and stores too (`VectorTSOEnabled`).
    public var vector: Bool?
    /// `rep movs` and `rep stos` too (`MemcpySetTSOEnabled`).
    public var memcpySet: Bool?
    /// Unaligned atomics are rewritten with half barriers rather than none
    /// (`HalfBarrierTSOEnabled`).
    public var halfBarrier: Bool?

    public init(tso: Bool? = nil, vector: Bool? = nil, memcpySet: Bool? = nil, halfBarrier: Bool? = nil) {
        self.tso = tso
        self.vector = vector
        self.memcpySet = memcpySet
        self.halfBarrier = halfBarrier
    }

    public enum Setting: String, CaseIterable, Sendable {
        case tso, vector, memcpySet, halfBarrier

        /// FEX's name for it, as in its JSON configuration.
        public var fexName: String {
            switch self {
            case .tso: "TSOEnabled"
            case .vector: "VectorTSOEnabled"
            case .memcpySet: "MemcpySetTSOEnabled"
            case .halfBarrier: "HalfBarrierTSOEnabled"
            }
        }
    }

    public subscript(_ s: Setting) -> Bool? {
        get {
            switch s {
            case .tso: tso
            case .vector: vector
            case .memcpySet: memcpySet
            case .halfBarrier: halfBarrier
            }
        }
        set {
            switch s {
            case .tso: tso = newValue
            case .vector: vector = newValue
            case .memcpySet: memcpySet = newValue
            case .halfBarrier: halfBarrier = newValue
            }
        }
    }

    public var isEmpty: Bool { Setting.allCases.allSatisfy { self[$0] == nil } }
}

public enum FEXProfile {
    /// Where `proton` and `protonApps` come from.
    public static let protonSource = "ValveSoftware/Proton bleeding-edge c9e0da9d736c (2026-09-26): FEX_Config.json, "
        + "proton's fex_application_profiles; proton_11.0 5b89db940e0e has the same"

    /// Proton's global FEX configuration (FEX_Config.json).
    public static let proton: [String: String] = [
        "ProfileStats": "1",
        "X87ReducedPrecision": "1",
        "TSOEnabled": "1",
        "VectorTSOEnabled": "0",
        "MemcpySetTSOEnabled": "0",
        "HalfBarrierTSOEnabled": "1",
        "MaxInst": "500",
        "Multiblock": "1",
    ]

    /// One AppOverrides entry: an executable name pattern and its values.
    public struct Override: Equatable, Sendable {
        public var pattern: String
        public var config: [String: String]
    }

    /// Proton's fex_application_profiles, by Steam app ID, in its order.
    public static let protonApps: [UInt32: [Override]] = [
        // The Witcher 3: Wild Hunt
        292030: [Override(pattern: "setup*", config: ["X87ReducedPrecision": "0"])],
    ]

    /// FEX's own MaxInst (FEXCore Config.json.in) when no profile sets one.
    public static let fexMaxInst = 5000
    /// The block sizes a game's page offers besides its default: Proton's global
    /// value and two between it and FEX's.
    public static let blockSizes = [500, 1000, 2000, 5000]
    /// A block size FEX takes: at least one instruction, at most FEX's own ceiling
    /// in practice (a block past a few thousand instructions only compiles longer).
    public static func validBlockSize(_ n: Int) -> Bool { (1...65536).contains(n) }

    /// The keys of a game's profile this build passes on besides the ordering.
    public static let honoured: Set<String> = ["X87ReducedPrecision", "Multiblock", "MaxInst"]

    /// FEX's AppOverrides match (FEXCore::Utils::Wildcard::Matches): `*` is any
    /// run of characters, everything else matches itself, case and all.
    public static func matches(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern.utf8), t = Array(name.utf8)
        var memo = [Int: Bool]()
        func m(_ i: Int, _ j: Int) -> Bool {
            if let v = memo[i * (t.count + 1) + j] { return v }
            let v: Bool = if i == p.count { j == t.count }
                else if p[i] == UInt8(ascii: "*") { m(i + 1, j) || (j < t.count && m(i, j + 1)) }
                else { j < t.count && p[i] == t[j] && m(i + 1, j + 1) }
            memo[i * (t.count + 1) + j] = v
            return v
        }
        return m(0, 0)
    }

    /// The executable's file name, as FEX names the app (`BaseName` of its
    /// path): after the last `\` or `/`.
    public static func baseName(_ exe: String) -> String {
        String(exe.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? Substring(exe))
    }

    /// The game's profile for this executable: the first matching AppOverrides entry, if any.
    public static func override(appID: UInt32?, exe: String) -> Override? {
        let name = baseName(exe)
        return appID.flatMap { protonApps[$0] }?.first { matches($0.pattern, name) }
    }

    /// Whether the game's profile runs x87 at 64-bit precision (FEX `X87ReducedPrecision`):
    /// Proton's global value under the matched entry's (decision 0048).
    public static func defaultX87Reduced(appID: UInt32?, exe: String) -> Bool {
        let config = proton.merging(override(appID: appID, exe: exe)?.config ?? [:]) { _, app in app }
        return config["X87ReducedPrecision"].flatMap(Int.init).map { $0 != 0 } ?? false
    }

    /// The ordering a game's profile gives: Proton's global values under the matched entry's.
    public static func defaults(appID: UInt32?, exe: String) -> [MemoryOrdering.Setting: Bool] {
        let config = proton.merging(override(appID: appID, exe: exe)?.config ?? [:]) { _, app in app }
        var out: [MemoryOrdering.Setting: Bool] = [:]
        for s in MemoryOrdering.Setting.allCases {
            out[s] = config[s.fexName].flatMap(Int.init).map { $0 != 0 }
        }
        return out
    }

    /// What one launch gives FEX.
    public struct Launch: Equatable, Sendable {
        /// Each ordering switch and where its value came from.
        public var ordering: [MemoryOrdering.Setting: Bool]
        /// The switches the game's page set (the rest are the profile's).
        public var chosen: Set<MemoryOrdering.Setting>
        /// The game's profile entry for this executable, if one matched.
        public var override: Override?
        /// FEX_<NAME> for each: the ordering, then the profile's other honoured keys.
        public var environment: [String: String]
        /// The block size this launch asks FEX for, and whether the game's page chose it.
        public var maxInst: Int
        public var maxInstChosen: Bool
        /// Whether x87 runs at 64-bit precision, and whether the game's page chose it.
        public var x87Reduced: Bool
        public var x87Chosen: Bool

        /// `tso=1 vector=0 memcpyset=0 halfbar=1`, as FEX's own `TSO config` line orders them,
        /// a `*` after each value the game's page chose.
        public var summary: String {
            let order: [(MemoryOrdering.Setting, String)] = [(.tso, "tso"), (.halfBarrier, "halfbar"), (.vector, "vector"),
                                                              (.memcpySet, "memcpyset")]
            return order.map { s, n in "\(n)=\(ordering[s] == true ? 1 : 0)\(chosen.contains(s) ? "*" : "")" }.joined(separator: " ")
        }
    }

    public static func environmentName(_ fexName: String) -> String { "FEX_" + fexName.uppercased() }

    /// The block size a game's profile gives for `exe`: its MaxInst, else FEX's own.
    public static func defaultBlockSize(appID: UInt32?, exe: String) -> Int {
        override(appID: appID, exe: exe)?.config["MaxInst"].flatMap(Int.init).flatMap { validBlockSize($0) ? $0 : nil }
            ?? fexMaxInst
    }

    /// The game's page over its profile, for a launch of `exe`.
    public static func launch(appID: UInt32?, exe: String, ordering: MemoryOrdering, maxInst: Int? = nil,
                              x87Reduced: Bool? = nil) -> Launch {
        let entry = override(appID: appID, exe: exe)
        var values = defaults(appID: appID, exe: exe)
        var chosen: Set<MemoryOrdering.Setting> = []
        var env: [String: String] = [:]
        for s in MemoryOrdering.Setting.allCases {
            if let v = ordering[s] {
                values[s] = v
                chosen.insert(s)
            }
            if let v = values[s] { env[environmentName(s.fexName)] = v ? "1" : "0" }
        }
        for (key, value) in entry?.config ?? [:] where honoured.contains(key) {
            env[environmentName(key)] = value
        }
        let chosenMax = maxInst.flatMap { validBlockSize($0) ? $0 : nil }
        if let chosenMax { env[environmentName("MaxInst")] = String(chosenMax) }
        let x87 = x87Reduced ?? defaultX87Reduced(appID: appID, exe: exe)
        env[environmentName("X87ReducedPrecision")] = x87 ? "1" : "0"
        return Launch(ordering: values, chosen: chosen, override: entry, environment: env,
                      maxInst: chosenMax ?? defaultBlockSize(appID: appID, exe: exe), maxInstChosen: chosenMax != nil,
                      x87Reduced: x87, x87Chosen: x87Reduced != nil)
    }

    /// FEX_HOSTFEATURES for a launch. On iOS FEX cannot read the CPU's ID
    /// registers and builds its feature set by hand (patches/fex-port 0009), so
    /// the app adds what the kernel reports (sysctl hw.optional.arm.FEAT_*):
    /// `enablelrcpc2` for FEAT_LRCPC2 (patches/fex 0008). A value already set
    /// (the launch's or the process's) is kept and only added to, and one that names lrcpc2 itself is left as it is.
    public static func hostFeatures(player: String?, lrcpc2: Bool) -> String? {
        let own = player?.trimmingCharacters(in: .whitespaces) ?? ""
        let names = own.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lrcpc2, !names.contains(where: { $0.hasSuffix("lrcpc2") }) else { return player }
        // A number is FEX's bitmask form, which the switch names cannot be added to.
        if !own.isEmpty, UInt64(own) != nil { return player }
        return own.isEmpty ? "enablelrcpc2" : own + ",enablelrcpc2"
    }
}
