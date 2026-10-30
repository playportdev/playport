// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit

/// An installed product's store region and language, changed in place (PLA-520).
extension BattleNetInstaller {
    static func readBuildInfo(_ root: URL, _ product: BattleNetProduct) throws -> BuildInfo {
        try BuildInfo.read([UInt8](try Data(contentsOf: root.appendingPathComponent(".build.info"))), product: product.code)
    }

    // MARK: region

    /// Moves the install at `root` to `region`: its `.build.info` names the region, its CDN and
    /// its tag, and nothing else changes. Every region's data is in the store already (the
    /// install takes them all), so nothing is downloaded; only the region's version and CDN
    /// endpoints are asked. A region whose current build is another is an update, refused here.
    @discardableResult
    public func changeRegion(_ product: BattleNetProduct, root: URL, to region: StoreRegion) async throws -> BuildInfo {
        let info = try Self.readBuildInfo(root, product)
        async let v = client.version(product, region)
        async let c = client.cdn(product, region)
        let (version, cdn) = try await (v, c)
        guard version.buildConfig == info.buildKey else {
            throw BattleNetError.unsupported("\(product.code) \(region.rawValue) is on \(version.versionsName), the install on \(info.version): "
                                             + "the region can change after an update")
        }
        var changed = info
        changed.region = region
        changed.cdnPath = cdn.path
        changed.cdnHosts = cdn.hosts
        changed.cdnServers = cdn.serverText
        changed.tags = info.retagged(region: region)
        try InstallFS.writeAtomically(root.appendingPathComponent(".build.info"), Data(changed.text.utf8))
        log.info("battlenet", "\(product.code): store region \(info.region.rawValue) → \(region.rawValue)")
        return changed
    }

    // MARK: language

    /// Plans the install at `root` in `locale`: the new locale's selection of the installed
    /// build, without the objects the store's journals already name and the product folder files
    /// the installed locale already put there, in data files numbered after the store's. The
    /// CDN indexes are read from the install; the manifests are fetched into `work`.
    public func prepareLocaleChange(_ product: BattleNetProduct, root: URL, to locale: String, work: URL) async throws -> Prepared {
        let info = try Self.readBuildInfo(root, product)
        guard let old = info.locale else { throw BattleNetError.damaged(".build.info: no locale in \(info.tags)") }
        let build = try await client.build(product, info.region)
        guard build.version.buildConfig == info.buildKey else {
            throw BattleNetError.unsupported("\(product.code) \(info.region.rawValue) is on \(build.version.versionsName), the install on \(info.version): "
                                             + "the language can change after an update")
        }
        let r = try await read(build, work: work)
        let installedTags = Set(info.tags.split(separator: ":").first.map { $0.split(separator: " ").map(String.init) } ?? [])
        func options(_ locale: String) -> BattleNetInstallOptions {
            var o = BattleNetInstallOptions(locale: locale)
            o.x64Client = build.productConfig.x64Tags.contains(where: installedTags.contains)
            return o
        }
        let installed = try BattleNetSelection(build: build, download: r.download, install: r.install, encoding: r.encoding, options: options(old))
        let have = Set(installed.files.map { "\($0.path)|\($0.ckey)" })
        let selection = try BattleNetSelection(build: build, download: r.download, install: r.install, encoding: r.encoding, options: options(locale))
            .without { have.contains("\($0.path)|\($0.ckey)") && InstallFS.fileSize(root.appendingPathComponent($0.path)) == $0.size }

        // What the store holds: its journals' keys (9 bytes) and data files.
        let dataDir = root.appendingPathComponent("Data/data")
        var stored = Set<PackedKey>(), lastDataFile = -1
        for (_, j) in try Self.latestJournals(dataDir) {
            for l in try CASC.readJournal([UInt8](try Data(contentsOf: dataDir.appendingPathComponent(j.name)))).locations {
                stored.insert(l.key)
                lastDataFile = max(lastDataFile, l.dataFile)
            }
        }
        let present = Set(selection.objects.map(\.key).filter { stored.contains(Self.key9($0)) })
        let locations = try await locate(selection.wanted.subtracting(present), r.cdnConfig.archives, meta: r.meta, build: build, installed: root)
        let plan = try BattleNetInstallPlan(build: build, archives: r.cdnConfig.archives, selection: selection, locations: locations,
                                            options: options(locale), present: present, firstDataFile: lastDataFile + 1)
        log.info("battlenet", "\(product.code) \(old) → \(locale): \(plan.objects) objects, \(plan.files.count) files, \(plan.fetchBytes) bytes to fetch")
        return Prepared(plan: plan, cdnConfig: r.cdnConfig, configs: [], indexes: [], installSize: info.installSize, client: r.client)
    }

    /// A key as a journal names it: its first 9 bytes.
    static func key9(_ key: PackedKey) -> PackedKey { PackedKey(Array(key.bytes.prefix(9)) + [UInt8](repeating: 0, count: 7)) }

    /// Adds `prepared` (from `prepareLocaleChange`) to the install at `root`: stages it through
    /// ContentKit in `work` (resumable), moves the new data files and product folder files in,
    /// writes the next generation of journals naming the store's objects and the new ones, then
    /// the locale into `.build.info` and into the game's `Config.wtf` when it has one.
    public func changeLocale(_ prepared: Prepared, root: URL, work: URL,
                             progress: @escaping @Sendable (InstallEngine.Progress) -> Void = { _ in }) async throws -> Result {
        let started = Date()
        let plan = prepared.plan, product = plan.build.product
        let tree = work.appendingPathComponent("tree")
        var engine = InstallEngine(tree: tree, journal: work.appendingPathComponent("stage.journal"),
                                   source: BattleNetChunkSource(client: prepared.client, plan: plan), log: log, options: engine)
        if let freeSpace { engine.freeSpace = freeSpace }
        let staged = try await engine.run(plan.content, progress: progress)

        let fm = FileManager.default
        for f in plan.content.files {
            let to = try InstallFS.resolveInside(root, f.path, createParents: true)
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.moveItem(at: try InstallFS.resolveInside(tree, f.path, createParents: false), to: to)
        }
        if !plan.dataFiles.isEmpty {
            let dataDir = root.appendingPathComponent("Data/data")
            let latest = try Self.latestJournals(dataDir)
            guard latest.count == CASC.buckets else { throw BattleNetError.damaged("\(product.code): the store has \(latest.count) journals") }
            var existing = [[CASC.Location]]()
            for bucket in 0..<CASC.buckets {
                existing.append(try CASC.readJournal([UInt8](try Data(contentsOf: dataDir.appendingPathComponent(latest[bucket]!.name)))).locations)
            }
            let generation = latest.values.map(\.generation).max()! + 1
            for (bucket, journal) in CASC.journals(objects: plan.locations, dataFiles: plan.dataFiles, existing: existing).enumerated() {
                try InstallFS.writeAtomically(dataDir.appendingPathComponent(CASC.journalName(bucket: bucket, generation: generation)), Data(journal))
            }
            for (_, old) in latest { try fm.removeItem(at: dataDir.appendingPathComponent(old.name)) }
        }
        var info = try Self.readBuildInfo(root, product)
        let old = info.locale
        info.tags = info.retagged(locale: plan.options.locale)
        try InstallFS.writeAtomically(root.appendingPathComponent(".build.info"), Data(info.text.utf8))
        let wtf = root.appendingPathComponent("\(plan.build.productConfig.folder)/WTF/Config.wtf")
        if let text = try? String(contentsOf: wtf, encoding: .utf8) {
            try InstallFS.writeAtomically(wtf, Data(Self.config(text, locale: plan.options.locale).utf8))
        }
        try? fm.removeItem(at: work)
        log.info("battlenet", "\(product.code): language \(old ?? "?") → \(plan.options.locale), \(staged.downloadedBytes) bytes fetched")
        return Result(engine: staged, archiveGroup: false, seconds: Date().timeIntervalSince(started))
    }

    /// The game's settings with its text and voice locales set to `locale` (other lines kept).
    static func config(_ text: String, locale: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            for name in ["textLocale", "audioLocale"] where line.hasPrefix("SET \(name) ") { return "SET \(name) \"\(locale)\"" }
            return String(line)
        }.joined(separator: "\n")
    }
}

extension BuildInfo {
    /// The install's locale: the tag after the region's (`US? enUS`).
    public var locale: String? {
        let words = tags.split(separator: ":").first.map { $0.split(separator: " ").map(String.init) } ?? []
        guard let at = words.firstIndex(where: { w in StoreRegion.allCases.contains { "\($0.tag)?" == w } }), at + 1 < words.count else {
            return nil
        }
        return words[at + 1]
    }

    /// The tags with the region's tag, the locale, or both replaced; every other tag kept.
    func retagged(region: StoreRegion? = nil, locale: String? = nil) -> String {
        let old = self.locale
        return tags.split(separator: ":", omittingEmptySubsequences: false).map { group in
            group.split(separator: " ", omittingEmptySubsequences: false).map { w -> String in
                if let region, StoreRegion.allCases.contains(where: { "\($0.tag)?" == w }) { return "\(region.tag)?" }
                if let locale, let old, w == old { return locale }
                return String(w)
            }.joined(separator: " ")
        }.joined(separator: ":")
    }
}
