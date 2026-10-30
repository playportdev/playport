// SPDX-License-Identifier: GPL-3.0-only
// Xodus 53ea781dcd073e31d7ea68e894134e9c959bff04 (the backend Xodus Nexus v0.4.1
// pins) licensing/{content,splicense}.rs, models/{licensing,devicecredential}.rs and
// xodus-cli/src/{license.rs,commands/license.rs}, and Xodus Nexus
// e0668a12f1da931aed13537ef04295599011317b's content-response, content-device-limit
// and offline-license patches; translated to Swift by the Playport authors,
// 2026-10-30. Modified: injected HTTP and SecretStore; content keys (never the
// licence) cached in the Keychain with the licence's expiry and offline lease; one
// typed result; HTTP 403 is not a definitive refusal; no provider text. splicense.rs
// is built on LukeFZ's CikExtractor: see LICENSE-Xodus.txt and LICENSE-CikExtractor.txt.
import Foundation
import ContentKit

/// A copy's content key: the key ID its package names and the 32-byte key.
public struct XboxContentKey: Sendable {
    public let id: UUID
    public let key: Secret<[UInt8]>
}

/// The offline lease Microsoft grants the account's offline device with a licence.
public struct XboxLicenceLease: Sendable, Equatable, Codable {
    public let expiresAt: Date
    /// When Microsoft wants the licence checked online again.
    public let pollAt: Date?
}

public struct XboxLicence: Sendable {
    public enum Source: Sendable, Equatable {
        /// Microsoft issued it just now.
        case microsoft
        /// Microsoft could not be reached; the Keychain's copy is within its expiry or lease.
        case cache
    }
    public let contentID: String
    public let keys: [XboxContentKey]
    /// The licence's own expiry, from its signed SPLicense block. Microsoft issues
    /// content licences that expire as they are issued and leave the time to the lease.
    public let expiresAt: Date
    public let offlineLease: XboxLicenceLease?
    public let source: Source
    /// Until when the cached keys may stand in while Microsoft can't be reached.
    public var usableUntil: Date { max(expiresAt, offlineLease?.expiresAt ?? .distantPast) }
}

/// Why Microsoft gave no licence and no verdict. None of these is a definitive refusal.
public enum XboxLicenceProblem: Error, Sendable, Equatable, CustomStringConvertible {
    /// No complete answer: no connection, a timeout, a dropped response.
    case network
    /// HTTP 408, 429 or 5xx: licensing is busy or failing.
    case service(Int)
    /// Any other HTTP error (401, 403, …): no licensing reason, so no verdict.
    case rejected(Int)
    /// An answer this client does not recognise, or keys that do not unwrap.
    case invalidResponse
    /// The account or device tickets the request needs are unavailable.
    case session(XboxSessionError)
    /// Licensing can't be reached and the offline launch rule keeps the stored keys out.
    case connectionNeeded(XboxOfflineRefusal)
    public var description: String {
        switch self {
        case .network: "Microsoft's licensing service couldn't be reached. Check your connection and try again."
        case .service(let status): "Microsoft's licensing service is unavailable (HTTP \(status)). Try again later."
        case .rejected(let status): "Microsoft's licensing service rejected the request (HTTP \(status)). Try again later."
        case .invalidResponse: "Microsoft's licensing service returned a response Playport doesn't recognise."
        case .session(let error): error.description
        case .connectionNeeded(let why): why.description
        }
    }
    /// The service could not be reached or is failing: a stored licence may stand in.
    var offlineCovers: Bool {
        switch self {
        case .network, .service: true
        case .rejected, .invalidResponse, .session, .connectionNeeded: false
        }
    }
}

/// `refused` is Microsoft's definitive answer for this account, copy and device: an
/// HTTP 2xx licensing response that carries `satisfactionFailure` with a numeric
/// reason and no licence. `.deviceLimit` (reason 501) refuses the device, not the
/// copy; every other reason is `.refused`, the only result a licence lapse counts.
/// Everything else is `unavailable`, never a verdict on the licence.
public enum XboxLicenceResult: Sendable {
    case licensed(XboxLicence)
    case refused(XboxLicenseFailure)
    case unavailable(XboxLicenceProblem)
}

extension XboxSession {
    /// The licence for a copy's content ID, with its content keys unwrapped by the
    /// synthetic device's key. Microsoft is asked every time (its policies say
    /// `refreshOnStartup`). A granted licence's keys go to the Keychain with its
    /// expiry, offline lease and when they were stored. While licensing can't be
    /// reached (`network`, `service`) the stored keys are returned as `.cache` under
    /// the offline launch rule (XboxOfflineLaunch): on the offline device, from a
    /// licence issued since the designation, within its offline lease. Otherwise a
    /// `network` failure is `.connectionNeeded` with the reason. A refusal deletes the
    /// copy's stored keys (a device-limit refusal, every copy's). Throws only for
    /// cancellation (sign-out included) and Keychain failures.
    public func licence(contentID: String, market: String = "US") async throws -> XboxLicenceResult {
        guard let id = UUID(uuidString: contentID) else { throw ClientError.unsupported("Xbox content ID is not a GUID") }
        let content = id.uuidString.lowercased()
        let epoch = generation
        let result = try await requestLicence(content, market: market, epoch: epoch)
        try check(epoch)
        var stored = try read([String: XboxStoredLicence].self, "licences") ?? [:]
        switch result {
        case .licensed(let licence):
            stored = stored.filter { $0.value.usableUntil > now() }
            stored[content] = XboxStoredLicence(licence, storedAt: now())
            try write(stored, "licences")
            log.info("xbox", "licence granted; " + (licence.offlineLease == nil ? "no offline lease" : "offline lease granted"))
        case .refused(let failure):
            if failure == .deviceLimit { stored = [:] } else { stored[content] = nil }
            try write(stored, "licences")
            log.info("xbox", failure == .deviceLimit ? "licence refused: device limit" : "licence refused")
        case .unavailable(let problem):
            guard problem.offlineCovers else { log.info("xbox", "licensing unavailable"); break }
            let designation = try read(XboxOfflineDesignation.self, "offline-device")
            switch XboxOfflineLaunch.check(stored[content], designation: designation, now: now()) {
            case .success(let cached):
                log.info("xbox", "licensing unavailable; using the stored licence (offline lease)")
                return .licensed(cached.licence(content))
            case .failure(let refusal):
                log.info("xbox", "licensing unavailable; offline start refused: \(refusal.label)")
                if problem == .network { return .unavailable(.connectionNeeded(refusal)) }
            }
        }
        return result
    }

    private func requestLicence(_ content: String, market: String, epoch: UInt64) async throws -> XboxLicenceResult {
        let device: XboxTicket, user: XboxTicket
        do {
            device = try await deviceTicket(scope: Self.storeScope, clientID: Self.storeApp, policy: "mbi_ssl")
            user = try await storeTicket()
        } catch let error as XboxSessionError { return .unavailable(.session(error)) }
        catch ClientError.cancelled { throw ClientError.cancelled }
        catch let error as ClientError {
            if case .credentialStore = error { throw error }
            if case .transport = error { return .unavailable(.network) }
            return .unavailable(.invalidResponse)
        }
        guard let reference = try ticketReference,
              let deviceLicence = try read(XboxDevice.self, "device")?.registration?.license else {
            return .unavailable(.session(.signInRequired))
        }
        try check(epoch)
        let response: XboxHTTPResponse
        do { response = try await http.send(XboxLicensing.request(content: content, market: market, device: device, user: user, reference: reference)) }
        catch is CancellationError { throw ClientError.cancelled }
        catch ClientError.cancelled { throw ClientError.cancelled }
        catch { return .unavailable(.network) }
        try check(epoch)
        if (200..<300).contains(response.status), let usage = XboxLicensing.usage(response.body.value) { log.info("xbox", "licence usage: \(usage)") }
        return XboxLicensing.result(response, content: content, deviceLicence: deviceLicence)
    }
}

struct XboxStoredLicence: Codable {
    struct Key: Codable { let id: UUID; let key: [UInt8] }
    let keys: [Key]
    let expiresAt: Date
    let offlineLease: XboxLicenceLease?
    /// When Microsoft issued it to this app (an online play); nil in entries from before PLA-504.
    let storedAt: Date?
    init(_ licence: XboxLicence, storedAt: Date) {
        keys = licence.keys.map { Key(id: $0.id, key: $0.key.value) }
        expiresAt = licence.expiresAt; offlineLease = licence.offlineLease; self.storedAt = storedAt
    }
    var usableUntil: Date { max(expiresAt, offlineLease?.expiresAt ?? .distantPast) }
    func licence(_ content: String) -> XboxLicence {
        XboxLicence(contentID: content, keys: keys.map { XboxContentKey(id: $0.id, key: Secret($0.key)) },
                    expiresAt: expiresAt, offlineLease: offlineLease, source: .cache)
    }
}

enum XboxLicensing {
    static let endpoint = URL(string: "https://licensing.mp.microsoft.com/v7.0/licenses/content")!
    static let userAgent = "XboxLm-PC/Microsoft.GamingServices_32.107.4002.0_x64__8wekyb3d8bbwe"
    /// Xodus's fixed ClientChallenge: LicenseProtocolVersion 5, SigningKeyVersion 1, ClientVersion 2.
    static let challenge = "PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0idXRmLTgiID8+PENsaWVudENoYWxsZW5nZSB4bWxuczp4c2k9Imh0dHA6Ly93d3cudzMub3JnLzIwMDEvWE1MU2NoZW1hLWluc3RhbmNlIiB4bWxuczp4c2Q9Imh0dHA6Ly93d3cudzMub3JnLzIwMDEvWE1MU2NoZW1hIiB4bWxucz0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS9vbmVzdG9yZS9zZWN1cml0eS9ta21zL0xpY1JlcS92MSIgVmVyc2lvbj0iMiI+PExpY2Vuc2VQcm90b2NvbFZlcnNpb24+NTwvTGljZW5zZVByb3RvY29sVmVyc2lvbj48U2lnbmluZ0tleVZlcnNpb24+MTwvU2lnbmluZ0tleVZlcnNpb24+PENsaWVudFZlcnNpb24+MjwvQ2xpZW50VmVyc2lvbj48L0NsaWVudENoYWxsZW5nZT4="
    /// The one local user Xodus presents (utils.rs generate_suid).
    static let user = "S-1-5-21-0000000000-0000000000-0000000000-1001"

    private struct Body: Encodable {
        struct Identity: Encodable { let identityType = "Msa"; let identityValue: String; let localTicketReference: String }
        let clientChallenge = XboxLicensing.challenge
        let concurrencyMode = "Rude"
        let contentId: String
        let deviceContext = ["hardwareManufacturer": "Public", "hardwareType": "Public", "mobileOperator": "Public"]
        let licenseVersion = 4
        let market: String
        let needKey = true
        let keyOnly = true
        let users: [String: [Identity]]
    }

    /// The device's Store ticket authorises; the account's Store ticket (`t=…&p=`) and
    /// its PUID name the user, as Xodus's get_license_content sends them.
    static func request(content: String, market: String, device: XboxTicket, user: XboxTicket, reference: String) throws -> XboxHTTPRequest {
        let body = Body(contentId: content, market: market,
                        users: [Self.user: [.init(identityValue: user.token.value, localTicketReference: reference)]])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return XboxHTTPRequest(url: endpoint, headers: [
            "from": Secret("XboxLicenseManager"), "Authorization": device.token, "user-agent": Secret(userAgent),
            "MS-CV": Secret(XboxCrypto.correlationVector()), "Content-Type": Secret("application/json"), "Accept": Secret("*/*"),
        ], body: Secret(Array(try encoder.encode(body))))
    }
    static func result(_ response: XboxHTTPResponse, content: String, deviceLicence: String) -> XboxLicenceResult {
        switch response.status {
        case 200..<300: break
        case 408, 429, 500..<600: return .unavailable(.service(response.status))
        default: return .unavailable(.rejected(response.status))
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(response.body.value)) as? [String: Any] else {
            return .unavailable(.invalidResponse)
        }
        let present = { (key: String) in json[key].map { !($0 is NSNull) } ?? false }
        if present("satisfactionFailure") {
            // A licence beside a denial is ambiguous, never a grant or a verdict.
            guard !present("license") else { return .unavailable(.invalidResponse) }
            do { try XboxLicenseFailure.check(response) } catch let failure as XboxLicenseFailure { return .refused(failure) } catch {}
            return .unavailable(.invalidResponse)
        }
        do { return .licensed(try licence(response.body.value, content: content, deviceLicence: deviceLicence)) }
        catch { return .unavailable(.invalidResponse) }
    }

    private struct Envelope: Decodable {
        struct Value: Decodable { let value: String }
        struct Content: Decodable { let keys: [Value]; let leases: [Value]? }
        let license: Content
    }

    static func licence(_ body: [UInt8], content: String, deviceLicence: String) throws -> XboxLicence {
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(body))
        // Xodus and Nexus take the first key licence; Microsoft sends one.
        guard let first = envelope.license.keys.first else { throw invalid }
        let xml = try XboxXML.parse(XboxCrypto.decode(first.value))
        guard xml.local == "License", xml.attr("ContentID").map({ $0.lowercased() == content }) ?? true,
              let block = xml.value("SPLicenseBlock"), !block.isEmpty else { throw invalid }
        let spl = try XboxSPLicense(XboxCrypto.decode(block))
        guard !spl.contentKeys.isEmpty else { throw invalid }
        let deviceKey = try XboxSPLicense(XboxCrypto.decode(deviceLicence)).deviceKey()
        let keys = try spl.contentKeys.map { XboxContentKey(id: $0.id, key: Secret(try unwrap($0.wrapped, key: deviceKey))) }
        // A lease that can't be read never blocks the licence; it grants no offline time.
        let leases = (envelope.license.leases ?? []).compactMap { try? offlineLease($0.value) }
        return XboxLicence(contentID: content, keys: keys, expiresAt: spl.expiresAt, offlineLease: leases.min { $0.expiresAt < $1.expiresAt },
                           source: .microsoft)
    }

    /// A lease licence whose CustomPolicies (base64 JSON) say `isOffline` with an expiry.
    static func offlineLease(_ value: String) throws -> XboxLicenceLease? {
        let xml = try XboxXML.parse(XboxCrypto.decode(value))
        guard xml.local == "License", let encoded = xml.value("CustomPolicies"),
              let policy = try JSONSerialization.jsonObject(with: Data(XboxCrypto.decode(encoded))) as? [String: Any],
              policy["isOffline"] as? Bool == true, let expires = (policy["expiresAt"] as? String).flatMap(date) else { return nil }
        return XboxLicenceLease(expiresAt: expires, pollAt: (policy["pollAt"] as? String).flatMap(date))
    }

    /// ISO 8601 with an offset and any number of fractional digits (Microsoft sends seven).
    static func date(_ value: String) -> Date? {
        var text = Substring(value)
        if let dot = text.firstIndex(of: ".") {
            let end = text[dot...].dropFirst().firstIndex { !$0.isNumber } ?? text.endIndex
            text = text[..<dot] + text[end...]
        }
        return ISO8601DateFormatter().date(from: String(text))
    }

    /// RFC 3394 AES key unwrap with the default IV (Xodus: aes_keywrap Aes128KeyWrapAligned).
    static func unwrap(_ wrapped: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard wrapped.count >= 24, wrapped.count % 8 == 0 else { throw invalid }
        let aes = try XboxAES128(key), n = wrapped.count / 8 - 1
        var a = Array(wrapped[0..<8]), r = (1...n).map { Array(wrapped[(8 * $0)..<(8 * $0 + 8)]) }
        for j in (0...5).reversed() {
            for i in (1...n).reversed() {
                let t = UInt64(n * j + i)
                for k in 0..<8 { a[k] ^= UInt8(truncatingIfNeeded: t >> (8 * (7 - k))) }
                let b = aes.block(a + r[i - 1])
                a = Array(b[0..<8]); r[i - 1] = Array(b[8..<16])
            }
        }
        guard a == [UInt8](repeating: 0xA6, count: 8) else { throw ClientError.verificationFailed("Xbox content key did not unwrap") }
        return r.flatMap { $0 }
    }
    static var invalid: ClientError { .protocolChanged("Microsoft returned an invalid licence") }

    /// What a granted licence says about its use, for the log (PLA-504 compares it on
    /// and off the offline device): the key licence's binding and `LicenseUsage`, and
    /// each lease's binding, `LicenseUsage`, `isOffline` and its lease URI's
    /// `policyType`/`policyKind`. Short words only; no IDs, dates or tickets.
    static func usage(_ body: [UInt8]) -> String? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(body)) else { return nil }
        func word(_ value: String?) -> String {
            guard let value, (1...24).contains(value.count), value.allSatisfy({ $0.isASCII && $0.isLetter }) else { return "?" }
            return value
        }
        func describe(_ value: String) -> (XboxXML, String)? {
            guard let bytes = try? XboxCrypto.decode(value), let xml = try? XboxXML.parse(bytes), xml.local == "License" else { return nil }
            return (xml, word(xml.child("Binding")?.attr("Binding_Type")) + "/" + word(xml.child("LicenseInfo")?.attr("LicenseUsage")))
        }
        var parts = envelope.license.keys.prefix(1).compactMap { describe($0.value) }.map { "key " + $0.1 }
        for lease in envelope.license.leases ?? [] {
            guard let (xml, text) = describe(lease.value) else { continue }
            var line = "lease " + text
            if let encoded = xml.value("CustomPolicies"), let bytes = try? XboxCrypto.decode(encoded),
               let policy = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] {
                line += " isOffline=" + ((policy["isOffline"] as? Bool).map { $0 ? "true" : "false" } ?? "?")
                let query = (policy["leaseUri"] as? String).flatMap { URLComponents(string: $0)?.queryItems } ?? []
                for name in ["policyType", "policyKind"] {
                    line += " \(name)=" + word(query.first { $0.name == name }?.value)
                }
            }
            parts.append(line)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}

/// The blocks of an SPLicense (tag, length, value; little-endian) this client reads.
struct XboxSPLicense {
    struct Packed { let id: UUID; let wrapped: [UInt8] }
    var contentKeys: [Packed] = []
    var expiresAt = Date(timeIntervalSince1970: 0)
    var encryptedDeviceKey: [UInt8]?

    init(_ bytes: [UInt8]) throws {
        guard bytes.count >= 8 else { throw XboxLicensing.invalid }
        var off = 8
        while off < bytes.count {
            guard bytes.count - off >= 8 else { throw XboxLicensing.invalid }
            let tag = bytes.readLE32(at: off), length = Int(bytes.readLE32(at: off + 4)); off += 8
            guard length <= bytes.count - off else { throw XboxLicensing.invalid }
            let value = Array(bytes[off..<off + length]); off += length
            switch tag {
            case 0xca: contentKeys += try Self.packed(value)
            case 0x20, 0x1f:  // licence or device-licence expiration time, Unix seconds
                guard length == 4 else { throw XboxLicensing.invalid }
                expiresAt = Date(timeIntervalSince1970: TimeInterval(value.readLE32(at: 0)))
            case 0x1:
                guard length == 4096 else { throw XboxLicensing.invalid }
                encryptedDeviceKey = value
            default: break
            }
        }
    }
    /// Entries of id length (≥ 16, a GUID first), key length (40), id, wrapped key.
    private static func packed(_ value: [UInt8]) throws -> [Packed] {
        var keys: [Packed] = [], off = 0
        while off < value.count {
            guard value.count - off >= 4 else { throw XboxLicensing.invalid }
            let idLength = Int(value.readLE16(at: off)), keyLength = Int(value.readLE16(at: off + 2)); off += 4
            guard idLength >= 16, keyLength == 40, value.count - off >= idLength + keyLength else { throw XboxLicensing.invalid }
            keys.append(Packed(id: guid(Array(value[off..<off + 16])), wrapped: Array(value[(off + idLength)..<(off + idLength + keyLength)])))
            off += idLength + keyLength
        }
        return keys
    }
    /// A Windows GUID: three little-endian fields, then eight bytes as they are.
    static func guid(_ b: [UInt8]) -> UUID {
        UUID(uuid: (b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
    /// The device licence's EncryptedDeviceKey (version 4): the 16 bytes at 518 are the
    /// schedule's hidden key, AES-128-CBC encrypted (zero IV) under itself.
    func deviceKey() throws -> [UInt8] {
        guard let block = encryptedDeviceKey, block.readLE32(at: 2) == 4 else {
            throw ClientError.protocolChanged("Device licence has no device key")
        }
        let key = XboxCrypto.scheduleKey(block, at: 6)
        guard try XboxAES128(key).cbc(Array(block[518..<534])) == key else {
            throw ClientError.verificationFailed("Device licence key")
        }
        return key
    }
}
