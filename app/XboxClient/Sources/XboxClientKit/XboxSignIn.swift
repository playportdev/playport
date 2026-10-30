// SPDX-License-Identifier: GPL-3.0-only
// Xodus 514dd56f360a4bdf12f4acde5148bac5ce5f957f, webview.rs and models/live.rs;
// translated to Swift by the Playport authors, 2026-10-30. Modified: origin-bound
// WKWebView bridge, JSON-escaped replies. Both hosted legs keep the broker headers
// as Xodus Nexus 96c652343d30ae16fe476818288edbed5dfac673's hosted-signin patch.
// See LICENSE-Xodus.txt and LICENSE-XodusNexus.txt.
import Foundation
import ContentKit

public struct XboxLoginPage: Sendable {
    public let url: URL
    public let headers: [String: String]
}

/// The page's DAProperty. No account field or ticket is printable.
public struct XboxSignInToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let data: Secret<[UInt8]>
    public var description: String { "<redacted>" }
    public var debugDescription: String { description }
}

public enum XboxSignInMessage: Sendable {
    case ignored
    case script(String)
    case token(XboxSignInToken)
}

public enum XboxSignIn {
    public static let clientID = "000000004424da1f"
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; MSAppHost/3.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.102 Safari/537.36 Edge/18.26100"
    // Passkeys are assumed unavailable in a sideloaded WKWebView (0166). Phone
    // finding is a deferred gate; this text does not claim it was tested.
    public static let passkeyNote = "Passkeys aren't available in this sign-in window. Choose Microsoft's other sign-in options: Authenticator, an emailed or texted code, or a password. A passkey-only account needs another sign-in method added first."
    public static let bridgeScript = "window.ipc = {postMessage: function(m) { window.webkit.messageHandlers.xbox.postMessage(String(m)); }}; window.external = {notify: window.ipc.postMessage};"
    public static let handoffScript = "if (typeof ServerData !== 'undefined') window.ipc.postMessage(JSON.stringify(ServerData));"

    public static func page(market: String = "en-US") -> XboxLoginPage {
        var url = URLComponents(string: "https://login.live.com/ppsecure/InlineLogin.srf")!
        url.queryItems = [URLQueryItem(name: "id", value: "80604"), URLQueryItem(name: "scid", value: "3"),
                          URLQueryItem(name: "mkt", value: market), URLQueryItem(name: "Platform", value: "Windows10"),
                          URLQueryItem(name: "clientid", value: clientID), URLQueryItem(name: "hosted", value: "1")]
        return XboxLoginPage(url: url.url!, headers: headers())
    }

    public static func continuation(_ url: URL) throws -> XboxLoginPage {
        guard trusted(url) else { throw ClientError.protocolChanged("Xbox sign-in returned an untrusted page") }
        return XboxLoginPage(url: url, headers: headers())
    }

    public static func isHandoff(_ url: URL) -> Bool { trusted(url) && url.path == "/ppsecure/post.srf" }

    public static func receive(_ message: Secret<String>, from url: URL) throws -> XboxSignInMessage {
        guard trusted(url), message.value.utf8.count <= 128 * 1024 else { return .ignored }
        let bytes = Data(message.value.utf8)
        if isHandoff(url), (try? JSONDecoder().decode(XboxDAProperty.self, from: bytes)) != nil {
            return .token(XboxSignInToken(data: Secret(Array(bytes))))
        }
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["type"] as? String == "invoke", let value = object["value"] as? [String: Any],
              value["name"] as? String == "CloudExperienceHost.getContext", let context = value["context"] as? String else { return .ignored }
        let reply: [String: Any] = ["type": "callback", "value": ["name": "CloudExperienceHost.getContext", "context": context,
            "args": ["CloudExperienceHost", "TokenBroker", "TokenBroker", capabilities]]]
        let json = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
        // Pass the JSON as a JSON string, never interpolate the page's context as script.
        let quoted = try JSONSerialization.data(withJSONObject: [String(decoding: json, as: UTF8.self)])
        let literal = String(decoding: quoted, as: UTF8.self).dropFirst().dropLast()
        return .script("window[\"CloudExperienceHost.Bridge.dispatchMessage\"](" + literal + ");")
    }

    static func trusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "login.live.com" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }
    private static let capabilities = #"{"PrivatePropertyBag":1,"PasswordlessConnect":1,"PreferAssociate":1,"ChromelessUI":0}"#
    private static func headers() -> [String: String] {
        ["cxh-capabilities": capabilities, "cxh-correlationId": UUID().uuidString.lowercased(), "cxh-msaBinaryVersion": "55",
         "cxh-identityClientBinaryVersion": "3", "cxh-osVersionInfo": #"{"platformId":2,"majorVersion":10,"minorVersion":0,"buildNumber":26100}"#,
         "cxh-platform": "CloudExperienceHost.Platform.DESKTOP", "cxh-protocol": "TokenBroker", "cxh-source": "TokenBroker", "hostApp": "CloudExperienceHost"]
    }
}

struct XboxDAProperty: Decodable {
    let sDAToken: String
    let sDASessionKey: String
    let sDAStartTime: String
    let sDAExpires: String
    let sSTSInlineFlowToken: String
    let sSigninName: String
    let K: String
}
