// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ContentKit

/// Small XML tree for the broker's fixed envelopes. Retains qualified names and
/// namespace context so exclusive canonicalization of a signed subtree is the
/// same whether it is a root or embedded in an Envelope (XML-exc-c14n 1.0).
final class XboxXML {
    let name: String
    var attributes: [String: String]
    var namespaces: [String: String]
    var children: [XboxXML] = []
    var text = ""
    // SOAP has no mixed content except whitespace around element children. Keep
    // text positions too: signature verification must not reorder that whitespace.
    var parts: [(String?, XboxXML?)] = []
    init(_ name: String, _ text: String = "", attributes: [String: String] = [:], namespaces: [String: String] = [:], children: [XboxXML] = []) {
        self.name = name; self.text = text; self.attributes = attributes; self.namespaces = namespaces
        self.children = children
        if !text.isEmpty { parts.append((text, nil)) }
        parts += children.map { (nil, $0) }
    }
    var local: String { name.split(separator: ":").last.map(String.init) ?? name }
    func child(_ name: String) -> XboxXML? { children.first { $0.local == name } }
    func all(_ name: String) -> [XboxXML] { (local == name ? [self] : []) + children.flatMap { $0.all(name) } }
    func value(_ name: String) -> String? { child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    func attr(_ local: String) -> String? { attributes.first { $0.key.split(separator: ":").last.map(String.init) == local }?.value }
    func adding(_ child: XboxXML) { children.append(child); parts.append((nil, child)) }
    func setText(_ value: String) { text = value; parts = [(value, nil)] }

    /// UTF-8 only (no other declared encoding, no UTF-16 with or without a BOM, no invalid
    /// bytes), so the parser reads the bytes the DTD check reads; and no DTD in any form:
    /// refused before parsing, and by the parser should any declaration reach it.
    static func parse(_ bytes: [UInt8]) throws -> XboxXML {
        guard bytes.count <= 1024 * 1024, !bytes.contains(0), let text = String(validating: bytes, as: UTF8.self) else { throw invalid() }
        let head = text.prefix(256).lowercased()
        if head.hasPrefix("<?xml"), let end = head.range(of: "?>"),
           let at = head[..<end.lowerBound].range(of: "encoding") {
            let declared = head[at.upperBound..<end.lowerBound].drop { " =\"'".contains($0) }.prefix { !" \"'".contains($0) }
            guard declared == "utf-8" || declared == "utf8" else { throw invalid() }
        }
        guard !text.lowercased().contains("<!doctype"), !text.contains("<!ENTITY") else { throw invalid() }
        let delegate = XboxXMLParser()
        let parser = XMLParser(data: Data(bytes))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.failed, let root = delegate.root else { throw invalid() }
        return root
    }
    static func invalid() -> ClientError { .protocolChanged("Microsoft returned invalid XML") }
    static func escape(_ s: String, attribute: Bool = false) -> String {
        var s = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\r", with: "&#xD;")
        if attribute { s = s.replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "\t", with: "&#x9;").replacingOccurrences(of: "\n", with: "&#xA;") }
        return s
    }
    func canonical(inherited: [String: String] = [:], rendered: [String: String] = [:]) -> String {
        let scope = inherited.merging(namespaces) { _, b in b }
        var visible = Set<String>()
        let prefix = name.contains(":") ? String(name.split(separator: ":")[0]) : ""
        visible.insert(prefix)
        for key in attributes.keys where key.contains(":") { visible.insert(String(key.split(separator: ":")[0])) }
        var seen = rendered
        var out = "<" + name
        for p in visible.sorted() where p != "xml" {
            let uri = scope[p] ?? ""
            if (rendered[p] ?? "") != uri {
                out += (p.isEmpty ? " xmlns=\"" : " xmlns:\(p)=\"") + Self.escape(uri, attribute: true) + "\""
                seen[p] = uri
            }
        }
        func attrKey(_ s: String) -> String {
            let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (scope[parts[0]] ?? "") + "\u{0}" + parts[1] : "\u{0}" + s
        }
        for key in attributes.keys.sorted(by: { attrKey($0) < attrKey($1) }) {
            out += " " + key + "=\"" + Self.escape(attributes[key]!, attribute: true) + "\""
        }
        out += ">"
        for (text, child) in parts {
            if let text { out += Self.escape(text) }
            if let child { out += child.canonical(inherited: scope, rendered: seen) }
        }
        return out + "</" + name + ">"
    }
}

private final class XboxXMLParser: NSObject, XMLParserDelegate {
    var root: XboxXML?
    var stack: [XboxXML] = []
    var failed = false
    var nodes = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        nodes += 1
        guard stack.count < 64, nodes < 16384 else { failed = true; parser.abortParsing(); return }
        var attrs: [String: String] = [:], ns = stack.last?.namespaces ?? [:]
        for (key, value) in attributes {
            if key == "xmlns" { ns[""] = value }
            else if key.hasPrefix("xmlns:") { ns[String(key.dropFirst(6))] = value }
            else { attrs[key] = value }
        }
        ns["xml"] = "http://www.w3.org/XML/1998/namespace"
        let node = XboxXML(qName ?? name, attributes: attrs, namespaces: ns)
        if let parent = stack.last { parent.adding(node) } else if root == nil { root = node } else { failed = true }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundCharacters text: String) { stack.last?.text += text; stack.last?.parts.append((text, nil)) }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self)) }
    // Any DTD declaration the parser meets ends the parse.
    private func refuse(_ parser: XMLParser) { failed = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { refuse(parser) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { refuse(parser) }
    func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) { refuse(parser) }
    func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String,
                type: String?, defaultValue: String?) { refuse(parser) }
    func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?) { refuse(parser) }
    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?,
                notationName: String?) { refuse(parser) }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { refuse(parser); return nil }
}
