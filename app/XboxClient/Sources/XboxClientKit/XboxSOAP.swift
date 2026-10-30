// SPDX-License-Identifier: GPL-3.0-only
// Xodus 514dd56f360a4bdf12f4acde5148bac5ce5f957f api/live/rst/, models/soap/;
// translated to Swift by the Playport authors, 2026-10-30. Modified: bounded XML,
// explicit failures, exclusive canonical signatures, no provider data in errors.
import Foundation
import ContentKit

struct XboxToken: Codable {
    let legacy: Bool
    let value: String
    let proof: String?
    let scope: String
    let expires: Date
}

struct XboxSOAPReply {
    var tokens: [XboxToken] = []
    var fault = false
    var inlineURL: URL?
}

enum XboxSOAP {
    static let endpoint = URL(string: "https://login.live.com/RST2.srf")!
    static let userAgent = "MSAWindows/55 (OS 10.0.26100.0.0 ge_release; IDK 10.0.26100.5074 ge_release; Cfg 16.000.29325.00; Test 0)"
    static let sts = "http://Passport.NET/STS"
    static let tb = "http://Passport.NET/tb"
    static let userScope = "scope=service::user.auth.xboxlive.com::MBI_SSL&api-version=2.0"
    static let deviceApp = "{DF60E2DF-88AD-4526-AE21-83D130EF0F68}"
    static let namespaces = ["s": "http://www.w3.org/2003/05/soap-envelope", "ps": "http://schemas.microsoft.com/Passport/SoapServices/PPCRL",
        "wsse": "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd",
        "wsu": "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd",
        "wsp": "http://schemas.xmlsoap.org/ws/2004/09/policy", "wsa": "http://www.w3.org/2005/08/addressing",
        "wssc": "http://schemas.xmlsoap.org/ws/2005/02/sc", "wst": "http://schemas.xmlsoap.org/ws/2005/02/trust"]
    static let ds = "http://www.w3.org/2000/09/xmldsig#"
    static let c14n = "http://www.w3.org/2001/10/xml-exc-c14n#"
    static let sha = "http://www.w3.org/2001/04/xmlenc#sha256"
    static let hmac = "http://www.w3.org/2001/04/xmldsig-more#hmac-sha256"
    static let rsa = "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"
    static let derived = "urn:liveid:SP800108_CTR_HMAC_SHA256_DOUBLEDERIVED"
    static func node(_ name: String, _ value: String = "", _ attrs: [String: String] = [:], _ children: [XboxXML] = []) -> XboxXML {
        XboxXML(name, value, attributes: attrs, children: children)
    }
    static func date(_ value: String) throws -> Date {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: value) { return d }
        f.formatOptions.insert(.withFractionalSeconds)
        guard let d = f.date(from: value) else { throw ClientError.protocolChanged("Microsoft token has an invalid lifetime") }; return d
    }
    static func time(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }

    static func request(now: Date, device: XboxToken? = nil, user: XboxToken? = nil, username: String,
                        app: String = deviceApp, scopes: [(String, String?)], inline: String? = nil,
                        silent: Bool = false, privateKey: XboxRSA? = nil) throws -> [UInt8] {
        let key: [UInt8]?
        if let device {
            guard let proof = device.proof else { throw ClientError.protocolChanged("Xbox device ticket has no proof") }
            key = Array(try XboxCrypto.clep(XboxCrypto.decode(proof), keyBytes: 48)[12..<44])
        } else { key = nil }
        let nonce = XboxCrypto.random(32)
        var auth = [node("ps:SSOFlags", device == nil ? "" : "SsoRestr"), node("ps:HostingApp", app),
                    node("ps:BinaryVersion", "55"), node("ps:UIVersion", "1"), node("ps:InlineUX", silent ? "Silent" : "TokenBroker"),
                    node("ps:IsAdmin", "1"), node("ps:Cookies"), node("ps:RequestParams", "AQAAAAIAAABsYwQAAAAxMDMz"),
                    node("ps:WindowsClientString", "b4d/QB7Zy5pjUAY9ByQ1echTyTITx6ZCErOEztuIVtw=")]
        if user == nil { auth.append(node("ps:LicenseSignatureKeyVersion", "2")) }
        auth.append(node("ps:ClientCapabilities", "1"))
        if let inline { auth.append(node("ps:InlineFT", inline)) }
        let info = node("ps:AuthInfo", "", ["Id": "PPAuthInfo"], auth)
        let timestamp = node("wsu:Timestamp", "", ["wsu:Id": "Timestamp"], [node("wsu:Created", time(now)), node("wsu:Expires", time(now.addingTimeInterval(300)))])
        var security: [XboxXML] = []
        if user != nil {
            security.append(node("wsse:UsernameToken", "", ["wsu:Id": "user"], [node("wsse:UsernameHint", username), node("wsse:LoginOption", "1")]))
        } else if device == nil {
            security.append(node("wsse:UsernameToken", "", ["wsu:Id": "devicesoftware"], [node("wsse:Username", username)]))
        }
        if let device {
            if let user {
                security.append(try XboxXML.parse(Array(user.value.utf8)))
                security.append(node("wsse:BinarySecurityToken", device.value, ["id": "DeviceDAToken", "ValueType": "urn:liveid:device"]))
            } else { security.append(try XboxXML.parse(Array(device.value.utf8))) }
            security.append(node("wssc:DerivedKeyToken", "", ["wsu:Id": "SignKey", "Algorithm": derived], [
                node("wsse:RequestedTokenReference", "", [:], [node("wsse:KeyIdentifier", "", ["ValueType": "http://docs.oasis-open.org/wss/2004/XX/oasis-2004XX-wss-saml-token-profile-1.0#SAMLAssertionID"]),
                    node("wsse:Reference", "", ["URI": user == nil ? "" : "#DeviceDAToken"])]), node("wssc:Nonce", XboxCrypto.base64(nonce))]))
        }
        security.append(timestamp)
        let requests = scopes.enumerated().map { i, scope in
            var children = [node("wst:RequestType", "http://schemas.xmlsoap.org/ws/2005/02/trust/Issue"),
                            node("wsp:AppliesTo", "", [:], [node("wsa:EndpointReference", "", [:], [node("wsa:Address", scope.0)])])]
            if let policy = scope.1 { children.append(node("wsp:PolicyReference", "", ["URI": policy])) }
            return node("wst:RequestSecurityToken", "", ["Id": "RST\(i)"], children)
        }
        guard !requests.isEmpty else { throw ClientError.protocolChanged("Xbox request has no scope") }
        let body = requests.count == 1 ? requests[0] : node("ps:RequestMultipleSecurityTokens", "", ["Id": "RSTS"], requests)
        let references = [body, timestamp, info].map { element -> XboxXML in
            let digest = XboxCrypto.base64(SHA256Stream.hash(Array(element.canonical(inherited: namespaces).utf8)))
            return node("Reference", "", ["URI": "#" + (element.attr("Id") ?? "")], [node("Transforms", "", [:], [node("Transform", "", ["Algorithm": c14n])]),
                node("DigestMethod", "", ["Algorithm": sha]), node("DigestValue", digest)])
        }
        let signedInfo = node("SignedInfo", "", [:], [node("CanonicalizationMethod", "", ["Algorithm": c14n]), node("SignatureMethod", "", ["Algorithm": key == nil ? rsa : hmac])] + references)
        let signed = Array(signedInfo.canonical(inherited: namespaces.merging(["": ds]) { _, b in b }).utf8)
        let signature: [UInt8]
        if let key { signature = XboxCrypto.hmac(XboxCrypto.derived(key, nonce: nonce), signed) }
        else if let privateKey { signature = try privateKey.sign(signed) }
        else { throw ClientError.protocolChanged("Xbox request has no signing key") }
        var signatureChildren = [signedInfo, node("SignatureValue", XboxCrypto.base64(signature))]
        if key != nil { signatureChildren.append(node("KeyInfo", "", [:], [node("wsse:SecurityTokenReference", "", [:], [node("wsse:Reference", "", ["URI": "#SignKey"])])])) }
        let sig = node("Signature", "", [:], signatureChildren); sig.namespaces[""] = ds
        security.append(sig)
        let header = node("s:Header", "", [:], [node("wsa:Action", "http://schemas.xmlsoap.org/ws/2005/02/trust/RST/Issue", ["s:mustUnderstand": "1"]),
            node("wsa:To", "https://login.live.com:443/RST2.srf", ["s:mustUnderstand": "1"]), node("wsa:MessageID", String(Int(now.timeIntervalSince1970))), info, node("wsse:Security", "", [:], security)])
        let envelope = node("s:Envelope", "", [:], [header, node("s:Body", "", [:], [body])]); envelope.namespaces = namespaces
        return Array(envelope.canonical().utf8)
    }

    static func reply(_ bytes: [UInt8], device: XboxToken? = nil) throws -> XboxSOAPReply {
        let envelope = try XboxXML.parse(bytes)
        guard envelope.local == "Envelope", let header = envelope.child("Header"), let body = envelope.child("Body"), let content = body.children.first else { throw XboxXML.invalid() }
        var hmacKey: [UInt8]?
        if let proof = device?.proof { hmacKey = Array(try XboxCrypto.clep(XboxCrypto.decode(proof), keyBytes: 48)[12..<44]) }
        var nonces: [String: [UInt8]] = [:]
        for node in header.child("Security")?.children.filter({ $0.local == "DerivedKeyToken" }) ?? [] {
            guard let id = node.attr("Id"), nonces[id] == nil, let nonce = node.value("Nonce") else { throw XboxXML.invalid() }
            nonces[id] = try XboxCrypto.decode(nonce)
        }
        func key(_ node: XboxXML) throws -> [UInt8] {
            guard let id = node.child("KeyInfo")?.child("SecurityTokenReference")?.child("Reference")?.attributes["URI"],
                  id.hasPrefix("#"), let nonce = nonces[String(id.dropFirst())], let hmacKey else { throw XboxXML.invalid() }
            return XboxCrypto.derived(hmacKey, nonce: nonce)
        }
        // Check the server's HMAC signature before accepting or decrypting anything. A reply
        // to a request signed with the device's proof key (`device`) must carry one over its
        // body, unless it is a fault (which grants nothing). Reference IDs must resolve
        // uniquely (no wrapping). Comparisons are constant time.
        let sig = header.child("Security")?.child("Signature")
        if hmacKey != nil, content.local != "Fault", sig == nil {
            throw ClientError.verificationFailed("Microsoft response has no signature")
        }
        if let sig {
            guard let si = sig.child("SignedInfo"), si.child("SignatureMethod")?.attributes["Algorithm"] == hmac,
                  si.child("CanonicalizationMethod")?.attributes["Algorithm"] == c14n,
                  let value = sig.value("SignatureValue") else { throw XboxXML.invalid() }
            let expected = XboxCrypto.hmac(try key(sig), Array(si.canonical().utf8))
            guard XboxCrypto.same(try XboxCrypto.decode(value), expected) else { throw ClientError.verificationFailed("Microsoft response signature") }
            func nodes(_ root: XboxXML) -> [XboxXML] { [root] + root.children.flatMap(nodes) }
            let references = si.children.filter { $0.local == "Reference" }
            guard let bodyID = body.attr("Id"), references.contains(where: { $0.attributes["URI"] == "#" + bodyID }) else {
                throw ClientError.verificationFailed("Microsoft response signature doesn't cover its body")
            }
            for reference in references {
                guard let uri = reference.attributes["URI"], uri.hasPrefix("#"),
                      reference.child("DigestMethod")?.attributes["Algorithm"] == sha,
                      reference.child("Transforms")?.children.allSatisfy({ $0.attributes["Algorithm"] == c14n }) == true,
                      let digest = reference.value("DigestValue") else { throw XboxXML.invalid() }
                let targets = nodes(envelope).filter { $0.attr("Id") == String(uri.dropFirst()) }
                guard targets.count == 1, XboxCrypto.same(try XboxCrypto.decode(digest), SHA256Stream.hash(Array(targets[0].canonical().utf8))) else {
                    throw ClientError.verificationFailed("Microsoft response digest")
                }
            }
        }
        func decrypt(_ node: XboxXML) throws -> XboxXML {
            guard node.child("EncryptionMethod")?.attributes["Algorithm"] == "http://www.w3.org/2001/04/xmlenc#aes256-cbc",
                  let value = node.child("CipherData")?.value("CipherValue") else { throw XboxXML.invalid() }
            let cipher = try XboxCrypto.decode(value)
            guard cipher.count >= 32 else { throw XboxXML.invalid() }
            let clear = try AES256Decryptor(key: key(node)).decryptCBC(cipher[16...], iv: Array(cipher[..<16]))
            return try XboxXML.parse(clear)
        }
        let clear = content.local == "EncryptedData" ? try decrypt(content) : content
        var pp = header.child("pp")
        if let encrypted = header.child("EncryptedPP")?.child("EncryptedData") { pp = try decrypt(encrypted) }
        if clear.local == "Fault" {
            let code = clear.child("Code")
            guard code?.value("Value")?.split(separator: ":").last == "Sender" else {
                throw ClientError.transport("Microsoft's token broker is unavailable; try again")
            }
            let reason = code?.child("Subcode")?.value("Value")?.split(separator: ":").last
            guard reason == "FailedAuthentication" || reason == "InvalidSecurityToken" || pp?.value("inlineauthurl") != nil else {
                throw ClientError.protocolChanged("Microsoft's token broker refused the request")
            }
            return XboxSOAPReply(fault: true, inlineURL: pp?.value("inlineauthurl").flatMap(URL.init(string:)))
        }
        let responses = clear.local == "RequestSecurityTokenResponse" ? [clear] : clear.children.filter { $0.local == "RequestSecurityTokenResponse" }
        guard !responses.isEmpty else { throw XboxXML.invalid() }
        return XboxSOAPReply(tokens: try responses.map(parseToken))
    }
    static func parseToken(_ xml: XboxXML) throws -> XboxToken {
        guard let type = xml.value("TokenType"), let scope = xml.child("AppliesTo")?.child("EndpointReference")?.value("Address"),
              let expires = xml.child("Lifetime")?.value("Expires"), let requested = xml.child("RequestedSecurityToken") else { throw XboxXML.invalid() }
        let expiry = try date(expires)
        switch type {
        case "urn:passport:legacy":
            guard let enc = requested.child("EncryptedData") else { throw XboxXML.invalid() }
            return XboxToken(legacy: true, value: enc.canonical(), proof: xml.child("RequestedProofToken")?.value("BinarySecret"),
                             scope: enc.child("KeyInfo")?.value("KeyName") ?? scope, expires: expiry)
        case "urn:passport:compact", "urn:passport:delegationcompact":
            guard let token = requested.value("BinarySecurityToken"), !token.isEmpty else { throw XboxXML.invalid() }
            return XboxToken(legacy: false, value: (type == "urn:passport:delegationcompact" ? "d=" : "") + token, proof: nil, scope: scope, expires: expiry)
        default: throw ClientError.protocolChanged("Microsoft returned an unsupported ticket type")
        }
    }
}
