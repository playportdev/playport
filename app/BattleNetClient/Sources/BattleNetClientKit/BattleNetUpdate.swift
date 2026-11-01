// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit

/// What the version endpoint says of an installed product (PLA-521): its build and the region's.
public struct BattleNetUpdateCheck: Sendable, Equatable {
    /// The install's version name (`.build.info`'s).
    public let installed: String
    /// The region's current one.
    public let current: String
    /// The region's current build is another than the install's.
    public let isNewer: Bool

    public init(installed: String, current: String, isNewer: Bool) {
        self.installed = installed
        self.current = current
        self.isNewer = isNewer
    }
}

/// An installed product brought to its store region's current build in place (PLA-521): the new
/// build's selection in the install's locale and machines, without the objects the store holds
/// already and the product folder files that are on disk as the new build has them. Never a
/// reinstall: the store's data files stay, the new objects go into data files after them.
extension BattleNetInstaller {
    /// Asks the version endpoint of the install's region for its current build.
    public func checkUpdate(_ product: BattleNetProduct, root: URL) async throws -> BattleNetUpdateCheck {
        let info = try Self.readBuildInfo(root, product)
        let current = try await client.version(product, info.region)
        return BattleNetUpdateCheck(installed: info.version, current: current.versionsName, isNewer: current.buildConfig != info.buildKey)
    }

    /// Plans the update of the install at `root` to its region's current build: the manifests and
    /// the CDN indexes the install does not have are fetched into `work` (kept for a resume).
    public func prepareUpdate(_ product: BattleNetProduct, root: URL, work: URL) async throws -> Prepared {
        let info = try Self.readBuildInfo(root, product)
        guard let locale = info.locale else { throw BattleNetError.damaged(".build.info: no locale in \(info.tags)") }
        let build = try await client.build(product, info.region)
        let r = try await read(build, work: work)
        let options = Self.options(locale, build: build, installed: info)
        let full = try BattleNetSelection(build: build, download: r.download, install: r.install, encoding: r.encoding, options: options)
        // As `prepare` does: Play starts only the ARM64 client (decision 0174), so a build that
        // drops or renames it is refused, before the product folder's files are left out.
        guard full.arm64Client(build.productConfig) != nil else {
            throw BattleNetError.unsupported("\(product.code) \(build.version.versionsName): the update has no ARM64 client "
                                             + "(\(build.productConfig.arm64Executable ?? "none named"))")
        }
        let selection = full.without { InstallEngine.fileMatches(root.appendingPathComponent($0.path), size: $0.size, hash: .md5($0.ckey.bytes)) }
        let (stored, lastDataFile) = try Self.stored(root)
        let present = Set(selection.objects.map(\.key).filter { stored.contains(Self.key9($0)) })
        let locations = try await locate(selection.wanted(besides: present), r.cdnConfig.archives, meta: r.meta, build: build, installed: root)
        let others = try await otherIndexes(r.cdnConfig, meta: r.meta, build: build, installed: root)
        let plan = try BattleNetInstallPlan(build: build, archives: r.cdnConfig.archives, selection: selection, locations: locations,
                                            options: options, present: present, firstDataFile: lastDataFile + 1)
        log.info("battlenet", "\(product.code) \(info.version) → \(build.version.versionsName): \(plan.objects) objects, "
                 + "\(plan.files.count) files, \(plan.fetchBytes) bytes to fetch")
        return Prepared(plan: plan, cdnConfig: r.cdnConfig, configs: r.configs, indexes: r.cdnConfig.archives + others,
                        installSize: Self.installSize(build), client: r.client)
    }

    /// Adds `prepared` (from `prepareUpdate`) to the install at `root` (`add`), then the new
    /// build's configs, the CDN indexes the install lacks and the archive group, and last
    /// `.build.info` naming the new build (its region and tags kept). Run again after an
    /// interruption, it resumes.
    public func update(_ prepared: Prepared, root: URL, work: URL,
                       progress: @escaping @Sendable (InstallEngine.Progress) -> Void = { _ in }) async throws -> Result {
        let started = Date()
        let plan = prepared.plan, b = plan.build
        let staged = try await add(prepared, root: root, work: work, progress: progress)

        let meta = work.appendingPathComponent("meta")
        for hash in prepared.configs {
            try place(meta.appendingPathComponent(hash.hex), at: try InstallFS.resolveInside(root, "Data/config/\(hash.cdnPath)", createParents: true))
        }
        for key in prepared.indexes {
            let to = try InstallFS.resolveInside(root, "Data/indices/\(key.hex).index", createParents: true)
            let from = meta.appendingPathComponent(key.hex + ".index")
            if InstallFS.fileSize(to) == nil, InstallFS.fileSize(from) != nil { try place(from, at: to) }
        }
        let groupWritten = try writeArchiveGroup(prepared.cdnConfig, meta: meta, into: root, installed: root)

        var info = try Self.readBuildInfo(root, b.product)
        let old = info.version
        info.buildKey = b.version.buildConfig
        info.cdnKey = b.version.cdnConfig
        info.installKey = b.config.install.ekey
        info.installSize = prepared.installSize
        info.cdnPath = b.cdn.path
        info.cdnHosts = b.cdn.hosts
        info.cdnServers = b.cdn.serverText
        info.version = b.version.versionsName
        try InstallFS.writeAtomically(root.appendingPathComponent(".build.info"), Data(info.text.utf8))
        try? FileManager.default.removeItem(at: work)
        log.info("battlenet", "\(b.product.code): updated \(old) → \(info.version), \(staged.downloadedBytes) bytes fetched")
        return Result(engine: staged, archiveGroup: groupWritten, seconds: Date().timeIntervalSince(started))
    }
}
