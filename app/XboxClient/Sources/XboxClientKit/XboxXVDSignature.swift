// SPDX-License-Identifier: GPL-3.0-or-later
// The XVD header's signature as Microsoft's tools make it: RSASSA-PSS (SHA-256,
// MGF1-SHA-256, a 32-byte salt) over the header after the signature, file bytes
// 0x200..<0x1000, the signature the first 0x200 bytes, big-endian (RFC 8017 9.1.2).
// Written by the Playport authors, 2026-10-30.
import Foundation
import ContentKit

/// An RSA public key from a CNG `BCRYPT_RSAPUBLIC_BLOB` ("RSA1"): exponent and modulus big-endian.
struct XboxRSAPublicKey: Sendable, Equatable {
    let n: [UInt8], e: [UInt8]

    init(blob: [UInt8]) throws {
        let bad = ClientError.protocolChanged("not an RSA public key blob")
        guard blob.count >= 24, blob.readLE32(at: 0) == 0x3141_5352 else { throw bad }
        let bits = Int(blob.readLE32(at: 4)), exp = Int(blob.readLE32(at: 8)), mod = Int(blob.readLE32(at: 12))
        guard (1...4).contains(exp), bits == mod * 8, (128...512).contains(mod), blob.count == 24 + exp + mod else { throw bad }
        e = Array(blob[24..<(24 + exp)]); n = Array(blob[(24 + exp)...])
        guard n.first.map({ $0 & 0x80 != 0 }) == true, n.last! & 1 == 1 else { throw bad }
    }
}

/// The keys an XVD header must be signed with to be installed.
public struct XboxXVDTrust: Sendable {
    let keys: [XboxRSAPublicKey]
    init(keys: [XboxRSAPublicKey]) { self.keys = keys }

    /// Microsoft's retail XVD signing keys: GreenGamesPublicKey (store games; it signs the
    /// pilot's header) and GreenXvdPublicKey, the two "Green" keys of xvdtool's key list
    /// (LibXboxOne/Keys/DurangoKeys.cs, by SHA-256 of the blob: 183f0ae0… and 618c5fb1…),
    /// as `native/bin/xsapi.dll` of Microsoft's NuGet package Microsoft.GDK.PC 2510.5.6322
    /// carries them (offsets 0x3a320 and 0x3a540). A package signed with Microsoft's SDK
    /// (test, "Red") key or any other is not one of these.
    public static let retail: XboxXVDTrust = {
        let blobs = [
            // GreenGamesPublicKey, SHA-256 183f0ae05431e4ad91554e88946967c872997227dbe6c85116f5fd2fd2d1229e
            "UlNBMQAQAAADAAAAAAIAAAAAAAAAAAAAAQABtG03qY5XGtWp27iZAKNLvlpDUJbXC2yAZcjXBUxjlYxClUCjFvrXWf726Ka0K1K+35sVGYwXmrV5zHZsnFu3"
                + "NfdScg9GyXNtw2uCfZGebXQZLHwZIVPx54ng2ZvFwAVHJg1w/JI9P/HVJhjsLUxCGYEz2mfCDf3wanIDUxOAB7SiJOQ6z+XEUrtpPzezwx1ktI2VFjum291Z"
                + "bQDSWAnmncI9mDnNSZpjjIWD+JZYw0N13/WuAOG0GN/eth9eNfNg7TpYXvgKuhOlHq36XoUnt6VpLLJxS/A7x/4SiOqHoBIga6djY/vBtW+Os2GbPIXlveVl"
                + "MwVlmK/odx5V+gXsA2EsX2dzDjco1twFOHbgNB2obpumpJaAIRYqrL5IsGvTCkPg5NrDu+gWdNEeLEzuy7izNx/3ojHHohBsNqxmgx/oRKJT3rNjaiwGNg/P"
                + "V/TzTQ8wDFwQEQ+fP07998CWnuY0hiozySeO/L00pyYgoa34FGWs0ooi8V3SMKDGfVheklhm8iHO6CDKu+CWxgJVgF8cEZVnu9c7917uIVYjB8RNBfddkCrZ"
                + "te4H+btP52jB2qdSCkO9sJHgYvwc4YtYULFfIma9+dHDDsjFF+CHC+Szvi3f+MUwa4HYlYeRPtn9UQzUJaZQ5twXPS5N8Eenyoi660Ne0etd3WaspL5b5+8=",
            // GreenXvdPublicKey, SHA-256 618c5fb1193040af8bc1c0199b850b4b5c42e43ce388129180284e4ef0b18082
            "UlNBMQAQAAADAAAAAAIAAAAAAAAAAAAAAQABrAA+zxibGAejcdI5RUsvURA6Y+fOL0zcP0VuluFgfhB66mipNu3ohXtUEZHx/2nQ52V4doxxP9X9GqlsXweb"
                + "7BIgUDKKeXM19KnJttuGwMCtP3+4JcquIsZx9wQTTYmIpa+5P4evTOtjVZ+nzUUdQkwH1jVZSuneWb9iTVblnB7/pqJng2OZNwE+kqi6mXfAj2cWTWexPVUx"
                + "R7wZbwrhAqcjM4xfHzPphHF7Zufxo51hZrHtw5rHZOYK2KSBqovJYhMnEHiY1omTM8qlJS0yxFspO3W97V8xc1vDFLRuaCfClIHAXXN91G7zVq6agQ+V0Doe"
                + "9DFyt12OlI9nlVRXZWVLygeij08BDH2dwICWDUfdfQpuoDbV3biW0Ufo+asXbQ5jOjOhhN5lasXrJ+3TBCNFvGi8y9oooG4QtFhyH3cHwtTTrFybNa3mH13Q"
                + "jarGECZyXNcTrkLAToLAjWzbRGW6xc4o64fEvwAeBjqlVSiKCOzWxr8oarpITNsWwJ61JkpByoK8awYd6cgHlrjp2QZSYi5dnKRi1ud4+CyMbVm/CKVqH0Vy"
                + "mq3KhADFZukajP4JcV8bEFyGdwdxggcrQg0T47wB/MYnAn1zxXoMQMUSW5IWYE1GeuZ9Vqb0nst/cSwpnjFWHahMyHcvz99DwyKWnzkrSL4Jbb+jkMmh3lE=",
        ]
        // Constants checked by the tests (the blobs' SHA-256 and the pilot's signature).
        return XboxXVDTrust(keys: blobs.map { try! XboxRSAPublicKey(blob: Array(Data(base64Encoded: $0)!)) })
    }()
}

enum XboxXVDSignature {
    static let size = 0x200
    /// The signed bytes: the header after its signature, up to its end (xvdtool's
    /// `XvdHeader` is 0x200 + 0xE00 bytes).
    static let signed = size..<0x1000
    static let saltLength = 32

    /// Throws unless the header (its first 0x1000 bytes at least) is signed by one of
    /// `trust`'s keys and keeps its data encrypted. The signature covers the volume flags,
    /// the content ID and the hash tree's top hash, so it vouches for every hashed page.
    static func verify(_ header: [UInt8], trust: XboxXVDTrust) throws {
        guard header.count >= signed.upperBound else { throw XboxXVD.damaged("its header is cut short") }
        let signature = Array(header[0..<size])
        // xvdtool's rule: past its first 0x20 bytes, an unsigned package's signature is zero.
        guard signature[0x20...].contains(where: { $0 != 0 }) else {
            throw ClientError.verificationFailed("Xbox package is not signed")
        }
        let message = Array(header[signed])
        guard trust.keys.contains(where: { pss(signature, message: message, key: $0) }) else {
            throw ClientError.verificationFailed("Xbox package is not signed by Microsoft")
        }
        guard header.readLE32(at: 0x208) & XboxXVDHeader.encryptionDisabled == 0 else {
            throw ClientError.unsupported("Xbox package has its encryption disabled")
        }
    }

    /// RSASSA-PSS-VERIFY with SHA-256 and MGF1-SHA-256, a 32-byte salt (RFC 8017 8.1.2, 9.1.2).
    static func pss(_ signature: [UInt8], message: [UInt8], key: XboxRSAPublicKey) -> Bool {
        let k = key.n.count, hLen = 32
        guard signature.count == k, XboxMontgomery.less(XboxRSA.limbs(signature), XboxRSA.limbs(key.n)) else { return false }
        // emBits = modBits - 1; the modulus's top bit is set, so emLen = k.
        let emBits = k * 8 - 1, emLen = k
        let em = XboxRSA.power(signature, key.e, modulus: key.n)
        guard emLen >= hLen + saltLength + 2, em[emLen - 1] == 0xBC else { return false }
        let maskedDB = Array(em[0..<(emLen - hLen - 1)]), h = Array(em[(emLen - hLen - 1)..<(emLen - 1)])
        let topBits = 8 * emLen - emBits
        guard maskedDB[0] & ~(0xFF >> topBits) == 0 else { return false }
        var db = mgf1(h, count: maskedDB.count)
        for i in db.indices { db[i] ^= maskedDB[i] }
        db[0] &= 0xFF >> topBits
        let ps = emLen - hLen - saltLength - 2
        guard db[0..<ps].allSatisfy({ $0 == 0 }), db[ps] == 0x01 else { return false }
        let salt = Array(db[(db.count - saltLength)...])
        let expected = SHA256Stream.hash([UInt8](repeating: 0, count: 8) + SHA256Stream.hash(message) + salt)
        return expected == h
    }

    /// MGF1 with SHA-256 (RFC 8017 B.2.1).
    static func mgf1(_ seed: [UInt8], count: Int) -> [UInt8] {
        var out: [UInt8] = [], counter: UInt32 = 0
        while out.count < count {
            out += SHA256Stream.hash(seed + [UInt8(counter >> 24), UInt8(counter >> 16 & 0xFF), UInt8(counter >> 8 & 0xFF), UInt8(counter & 0xFF)])
            counter += 1
        }
        return Array(out[0..<count])
    }
}
