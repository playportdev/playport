// SPDX-License-Identifier: GPL-3.0-only
// Xodus 514dd56f360a4bdf12f4acde5148bac5ce5f957f hardware.rs,
// tokens/device.rs, models/devicecredential.rs and clep/challenge.rs;
// translated to Swift by the Playport authors, 2026-10-30. Modified: all
// hardware is random synthetic data, never probed from the host or the phone.
import Foundation
import ContentKit

struct XboxDevice: Codable {
    let identity: String
    let username: String
    let password: String
    let serial: String
    let uuid: [UInt8]
    let disk: String
    var registration: XboxDeviceRegistration?
    static func make() -> XboxDevice {
        XboxDevice(identity: UUID().uuidString, username: "02" + randomString(14), password: randomString(20),
                   serial: randomString(16), uuid: XboxCrypto.random(16), disk: randomString(20))
    }
    private static func randomString(_ count: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<count).map { _ in alphabet.randomElement(using: &rng)! })
    }
    func request() -> [UInt8] {
        // SMBIOS Type 1, 27-byte formatted area, followed by its string table.
        var smbios: [UInt8] = [1, 27, 1, 0, 1, 2, 3, 4] + uuid + [6, 5, 6]
        smbios += Array(("Playport\0PC-" + serial.prefix(6) + "\0" + "1.0\0" + serial + "\0PC\0Virtual PC\0\0").utf8)
        smbios += [UInt8](repeating: 0, count: 256 - smbios.count)
        let disk = Array(disk.utf8) + [UInt8](repeating: 0, count: 64 - disk.utf8.count)
        let v2 = XboxClep.challenge(version: 2, smbios: smbios, disk: disk)
        let v4 = XboxClep.challenge(version: 4, smbios: smbios, disk: disk)
        func component(_ name: Int, _ bytes: [UInt8]) -> String {
            "<Component name=\"\(name)\">" + XboxCrypto.base64(bytes) + "</Component>"
        }
        let components = component(4113, disk) + component(4100, Array("1.0".utf8)) + component(4101, Array(serial.utf8))
            + component(4102, uuid) + component(8196, v2) + component(8197, v4) + component(4145, [1, 0, 0, 0])
            + "<Component name=\"4160\" error=\"-2147024894\"/><Component name=\"4161\" error=\"-2147024894\"/>"
        return Array(("<DeviceAddRequest><ClientInfo name=\"IDCRL\" version=\"1.0\"><BinaryVersion>55</BinaryVersion></ClientInfo>"
            + "<Authentication><Membername>" + username + "</Membername><Password>" + password + "</Password></Authentication>"
            + "<DeviceInfo Id=\"DeviceInfo\">" + components + "</DeviceInfo></DeviceAddRequest>").utf8)
    }
}

struct XboxDeviceRegistration: Codable {
    let puid: String
    let hardwareID: String
    let deviceID: String
    let license: String
    init(_ body: [UInt8]) throws {
        let xml = try XboxXML.parse(body)
        guard xml.local == "DeviceAddResponse", xml.attributes["Success"] == "true", let puid = xml.value("puid"), !puid.isEmpty,
              let license = xml.child("License")?.value("SPLicenseBlock"), !license.isEmpty,
              let hardware = xml.value("HWDeviceID") else {
            throw ClientError.protocolChanged("Microsoft did not register the Xbox device")
        }
        self.puid = puid; hardwareID = hardware
        deviceID = xml.child("License")?.child("Binding")?.value("DeviceId") ?? ""
        self.license = license
        // Fail here, not on a later sign-in, if Microsoft changed its key format.
        _ = try XboxRSA(XboxCrypto.privateKey(license))
    }
}

/// Microsoft's obfuscation of the 2048-byte hardware challenge is not encryption
/// and contains no secrets. A forward port of Xodus's fixed eight round functions.
private enum XboxClep {
    static func rr(_ x: UInt32, _ n: Int) -> UInt32 { (x >> n) | (x << (32 - n)) }
    static func f(_ round: Int, _ x: UInt32) -> UInt32 {
        switch round {
        case 0: return 0x3243 &* rr(x &- 0x24181621, 18) &- rr(x, 9)
        case 1: return 0x3243 &* rr(x ^ 0x24181621, 22) &- rr(x, 8)
        case 2: return 0x3243 &* (rr(x, 15) ^ 0x2418)
        case 3: return (x >> 9) &+ (0x1621 &* rr(x ^ 0x4139, 29))
        case 4: return rr(x, 28) ^ (0x4139 &* rr(x ^ 0x24181621, 9))
        case 5: return rr(x, 12) &+ (0x3243 &* rr(x &- 0x24181621, 14))
        case 6: return rr(x, 11) ^ (0x2418 &* rr(x ^ 0x1621, 30))
        case 7: return x &- 0x41393243 &- 0x1621
        case 8: return 0x4139 &* rr(x ^ 0x2418, 30) &- rr(x, 18)
        default: return 0x4139 &* rr(x &+ 0x24181621, 10) &- rr(x, 29)
        }
    }
    static let initial: UInt32 = {
        var a: UInt32 = 0, b = ~(UInt32(0x4139) &* rr(0x24181621, 10))
        for i in 1...8 { (a, b) = (b, a ^ f(i, b)) }; return b
    }()
    static func challenge(version: UInt8, smbios: [UInt8], disk: [UInt8]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 2048)
        bytes[0] = version
        bytes.replaceSubrange(4..<260, with: smbios)
        bytes.replaceSubrange(260..<324, with: disk)
        if version == 2 { bytes[328] = 1 } else { bytes[1231] = 1 }
        let iv = bytes.readLE32(at: 4)
        var lo = initial ^ iv, hi: UInt32 = 0, prevLo = iv, prevHi: UInt32 = 0
        func store(_ word: UInt32, _ off: Int) { for i in 0..<4 { bytes[off + i] = UInt8(truncatingIfNeeded: word >> (8 * i)) } }
        store(lo, 4)
        for off in stride(from: 8, to: 2048, by: 8) {
            let plainLo = bytes.readLE32(at: off), plainHi = bytes.readLE32(at: off + 4)
            var a = lo ^ plainLo, b = hi ^ plainHi ^ f(0, lo ^ plainLo)
            for i in (1...8).reversed() { (a, b) = (b ^ f(i, a), a) }
            lo = prevLo ^ a ^ f(9, b); hi = b ^ prevHi
            store(lo, off); store(hi, off + 4)
            prevLo = plainLo; prevHi = plainHi
        }
        return bytes
    }
}
