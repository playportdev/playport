// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › About › Licences, pages shown in place of the About section
// (AppNavigation.licences; SettingsView.swift). The list: Playport's copyright,
// licence, warranty notice and where its source is (the GPL's Appropriate Legal
// Notices), then every component the app carries with its licence, the credit
// lines and, until the selection is reviewed, its open questions. A component:
// its licence files. A file: its text, one row a paragraph so the ring scrolls
// through it. The list comes from the bundled Licenses/components.json
// (PlayportKit Licences, docs/NOTICES.md); a build without it says so rather
// than showing a placeholder. Every row is on Settings' ring: A opens, B goes
// back a page.

import PlayportKit
import SwiftUI

/// A page of Settings › About › Licences.
enum LicencePage: Hashable {
    case list
    case component(String)
    /// A file of Licenses/, by its name there.
    case text(String)

    /// The row that opens this page on the page under it; the ring goes back to it.
    var row: String {
        switch self {
        case .list: "set:licences"
        case .component(let name): "set:lic:c:" + name
        case .text(let file): "set:lic:f:" + file
        }
    }

    /// Where the ring starts on this page.
    var firstItem: String {
        switch self {
        case .list: "set:lic:playport"
        case .component: "set:lic:head"
        case .text: "set:lic:p:0"
        }
    }
}

@MainActor
enum BundledLicences {
    static let copyright = "Copyright (C) 2026 The Playport authors"
    static let directory = Bundle.main.bundleURL.appendingPathComponent("Licenses", isDirectory: true)
    static let loaded: Result<Licences, Error> = Result { try Licences.load(directory: directory) }
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

struct LicencePageView: View {
    let page: LicencePage

    var body: some View {
        switch page {
        case .list: LicencesList()
        case .component(let name): LicenceComponentPage(name: name)
        case .text(let file): LicenceTextPage(file: file)
        }
    }
}

/// A paragraph on the ring: A does nothing, the ring moving onto it scrolls it into view.
private struct LicenceParagraph: View {
    let id: String
    let text: String
    var monospaced = false
    var warning = false

    var body: some View {
        Text(text)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
            .foregroundStyle(warning ? Color(hex: 0xFF9A8A) : PP.soft)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(PP.surface, in: RoundedRectangle(cornerRadius: 10))
            .padItem("set:lic:" + id, hint: "", cornerRadius: 10) {}
    }
}

private struct LicencesList: View {
    var body: some View {
        VStack(spacing: 8) {
            SettingsNote(text: "Playport \(BundledLicences.version) · \(BundledLicences.copyright)")
            LicenceParagraph(id: "playport", text: "Playport is free software: you can redistribute it and/or modify it "
                             + "under the terms of the GNU General Public License as published by the Free Software "
                             + "Foundation, either version 3 of the License, or (at your option) any later version, "
                             + "with the additional permission of its licence exception.")
            LicenceParagraph(id: "warranty", text: "Playport is distributed in the hope that it will be useful, but "
                             + "WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS "
                             + "FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.")
            if case .success(let licences) = BundledLicences.loaded {
                if licences.contains(Licences.playportLicence) { fileRow("GNU General Public License", Licences.playportLicence) }
                if licences.contains(Licences.playportException) { fileRow("Additional permission", Licences.playportException) }
            }
            PadSectionHeader(text: "Source code")
            LicenceParagraph(id: "source", text: "The complete source code of this version, with every change Playport "
                             + "makes to the projects it is built from and how to build it, is published free of charge "
                             + "beside it, on the release it came from, as Playport-\(BundledLicences.version)-source.tar. "
                             + "You may copy, change and share Playport under these licences.")
            switch BundledLicences.loaded {
            case .success(let licences):
                PadSectionHeader(text: "Components")
                ForEach(licences.components) { c in
                    PadRow(id: LicencePage.component(c.name).row, title: c.name, value: c.licence, accessory: .chevron,
                           hint: "Open") {
                        AppNavigation.shared.openLicence(.component(c.name))
                    }
                }
                SettingsNote(text: "Each part of Playport keeps its own licence. These are the texts it carries.")
                if !licences.credits.isEmpty {
                    PadSectionHeader(text: "Credits")
                    ForEach(licences.credits.indices, id: \.self) { i in
                        LicenceParagraph(id: "credit:\(i)", text: licences.credits[i])
                    }
                }
                if !licences.reviewed {
                    PadSectionHeader(text: "Not yet reviewed")
                    ForEach(licences.open.indices, id: \.self) { i in
                        LicenceParagraph(id: "open:\(i)", text: licences.open[i])
                    }
                    SettingsNote(text: "This build's notices have not had their release review (status: \(licences.status)).")
                }
            case .failure(let error):
                PadSectionHeader(text: "Components")
                LicenceParagraph(id: "missing", text: "This build carries no licence notices: \(String(describing: error))",
                                 warning: true)
            }
        }
    }

    private func fileRow(_ title: String, _ file: String) -> some View {
        PadRow(id: LicencePage.text(file).row, title: title, accessory: .chevron, hint: "Read") {
            AppNavigation.shared.openLicence(.text(file))
        }
    }
}

private struct LicenceComponentPage: View {
    let name: String

    var body: some View {
        VStack(spacing: 8) {
            if case .success(let licences) = BundledLicences.loaded,
               let component = licences.components.first(where: { $0.name == name }) {
                SettingsNote(text: "\(component.name) · \(component.licence)")
                SettingsInfoRow(id: "lic:head", title: component.name, value: component.licence)
                ForEach(component.files, id: \.self) { file in
                    PadRow(id: LicencePage.text(file).row, title: file, accessory: .chevron, hint: "Read") {
                        AppNavigation.shared.openLicence(.text(file))
                    }
                }
            } else {
                LicenceParagraph(id: "head", text: "\(name) is not in this build's licences.", warning: true)
            }
        }
    }
}

private struct LicenceTextPage: View {
    let file: String
    @State private var paragraphs: [String]?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 8) {
            SettingsNote(text: file)
            if let failure {
                LicenceParagraph(id: "p:0", text: failure, warning: true)
            } else if let paragraphs {
                // Lazy: a long text draws the paragraphs near the ring, and the ring
                // moving down scrolls the next ones into being.
                LazyVStack(spacing: 8) {
                    ForEach(paragraphs.indices, id: \.self) { i in
                        LicenceParagraph(id: "p:\(i)", text: paragraphs[i], monospaced: true)
                    }
                }
            } else {
                // Keep the first row on the ring while the text loads. A spinner
                // left only the sidebar focusable, so the ring fell onto Steam
                // and B closed Settings instead of returning to the file list.
                LicenceParagraph(id: "p:0", text: "Loading licence text…")
            }
        }
        .task(id: file) {
            guard case .success(let licences) = BundledLicences.loaded else {
                failure = "This build carries no licence notices."
                return
            }
            do {
                let p = Licences.paragraphs(try licences.text(of: file))
                if p.isEmpty { failure = "\(file) is empty." } else { paragraphs = p }
            } catch {
                failure = "\(file) could not be read: \(String(describing: error))"
            }
        }
    }
}
