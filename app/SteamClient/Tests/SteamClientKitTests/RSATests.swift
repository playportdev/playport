// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import SteamClientKit

/// The password encryption of Steam's credential sign-in (Crypto/RSA.swift),
/// against a throwaway 2048-bit key made with OpenSSL for these tests only
/// (`openssl genrsa 2048`; its modulus and private exponent below, so a
/// ciphertext can be opened again here), and a ciphertext OpenSSL made with
/// `pkeyutl -encrypt -pkeyopt rsa_padding_mode:pkcs1`.
final class RSATests: XCTestCase {
    static let modulus = """
        C413D95790E979210C753BBC8DEDA5B89325001E5EACCD88FE6BE68ECF021ABE0984ECA87441B3799549725303C6AE88\
        645B6F455A1E1FC613FF140EA6770E419D12FDB1AE0F9C41278EF88FE6CDBA9EFE8B5C28E882E6D1658B2228CE917606\
        F3B7D67940392C2818CF4D06B70F7E97E6B3B173AFD538567010B943E9CA210B05374176A2B5D9DF12430A30194A9693\
        F599AF0D1172383A777336C22E5DFDEAE66A6F5CAB0E75132BF43F8EB8348B0F8D576E6D66CE64EF1474588260F69AE3\
        F2ADE848193856AFC3AFCFF8CF887D42FB9ACA9B3A79A051B2C4F1A63D8214B85D9B5A657133122202EF68C39A927E4D\
        1BE9010F4B6C51E7465A9E3137E24AB1
        """
    static let privateExponent = """
        e30646f1569db7220cca98f721009f1ac515a9763a9cab2f447cd8c80ca1403e2598e5536bd3bdd759f701b933e03fef\
        08fdec57c8f446a73468a321f63eb465e6f850508c8a296cbb55200294ff87abecc78610632616032e8398724a00393f\
        5f082ab47ef9566145414c3f6e86d3a3deb475cd88777acf25c37d1beacf9e13857385dfda1393416faa87525a8009d5\
        f7cf1f6412115bc8dd3cfc9981e5ceeccdddc77df1744b40a76e4f8a31f2cdda85be9f7534dea6e8659c8bb3a65febce\
        a8e53455b7ea80f7b2d9ad3b4a528bcac52860e07edea4116148875f0fdc270d224dc6eb9f5fcd11e668ae3a20479bb4\
        28f31df6cff61b5acfb6949117d87f
        """
    static let opensslCiphertext = """
        bcae4c8b5dae3ef162af5787e8c17bbb562f07b32c122fb9d8640add91d53ec743662fba592c86d0ea476c46acac5b71\
        e98ac0ffd19dd53a2697325bb627e4b6245cc51e43f09d938af256f395a89309dbded2e540dcd263b3329cea7a181c09\
        559aae7d524fef499c88c7dfb53816e0291677f814f857bc93c7192f330aeb3df39f2315b414efaebd25d697e2e94e0a\
        490f3435c17ba023204e58c3748e5c37cc5ac4963dd06e9c9886e48afd60cd2cd233d7af39f17a6301618281b8164136\
        dcf3728419c80cbe10470dcca0c7cca91ac250392a6a1322740c808ba5c8abc36b6dd4d4c35ea9bc25fa9a15703ec962\
        f6ca9fca2a84ccda73f4e44e8aab1ee8
        """
    static let fixedCiphertext = """
        12729e4484b5599c9e1cc62cc0b65e903dced7531c04718299c75903d0eb557ed9358767a78e7b7652d751867e3fb061\
        7c3e9e074978c519001523e96595dedc3a55d25be788aa9802e1555e69f463054d85b66f9362309f15c1de2b3e27239d\
        cbb1f05dbbb3f72000555eba1a4be316d3d37972578110cc4134e8e25b9fde5429021783b76eae3d4f376ab03d6918df\
        95ba30555b2d658abbaa32cd64d4f0e496cdd57e85577e86dba7185f809794290df9eefc23199c70979d82b56c32907f\
        1d53d129685206648d3c77c451935bde81746f401bd40ead08d56596f0ae2a6b4f74fb6b48f7f99a76480d4a5837a350\
        055cd78f2dd339f16969dede9be2cb46
        """

    static var key: RSAPublicKey { get throws { try RSAPublicKey(modulusHex: modulus, exponentHex: "010001") } }
    static var d: [UInt8] { RSAPublicKey.bytes(hex: privateExponent)! }

    /// The message a PKCS#1 v1.5 type-2 block carries, nil when the block is malformed.
    static func unpad(_ em: [UInt8]) -> [UInt8]? {
        guard em.count > 11, em[0] == 0, em[1] == 2, let zero = em[2...].firstIndex(of: 0), zero >= 10 else { return nil }
        return Array(em[(zero + 1)...])
    }

    func testOpensslCiphertextOpensWithTheKey() throws {
        let key = try Self.key
        XCTAssertEqual(key.byteCount, 256)
        let em = key.raw(RSAPublicKey.bytes(hex: Self.opensslCiphertext)!, power: Self.d)
        XCTAssertEqual(Self.unpad(em), Array("hunter2-pässwörd".utf8))
    }

    func testPublicOperationMatchesAFixedBlock() throws {
        // 00 02, 248 bytes of 7, 00, "hello": the ciphertext Python's pow() gives.
        let em = [0, 2] + [UInt8](repeating: 7, count: 248) + [0] + Array("hello".utf8)
        XCTAssertEqual(try Self.key.raw(em, power: [1, 0, 1]).hex, Self.fixedCiphertext)
    }

    func testEncryptRoundTripsAndPadsWithNonzeroBytes() throws {
        let key = try Self.key
        let password = Array("correct horse battery staple ~`!".utf8)
        let c1 = try key.encryptPKCS1(password)
        let c2 = try key.encryptPKCS1(password)
        XCTAssertEqual(c1.count, 256)
        XCTAssertNotEqual(c1, c2, "fresh random padding every time")
        for c in [c1, c2] {
            let em = key.raw(c, power: Self.d)
            XCTAssertEqual(Self.unpad(em), password)
            XCTAssertFalse(em[2..<(256 - password.count - 1)].contains(0))
        }
        // The longest message fits, one more byte does not.
        XCTAssertEqual(Self.unpad(key.raw(try key.encryptPKCS1([UInt8](repeating: 0x41, count: 245)), power: Self.d))?.count, 245)
        XCTAssertThrowsError(try key.encryptPKCS1([UInt8](repeating: 0x41, count: 246)))
        XCTAssertEqual(Self.unpad(key.raw(try key.encryptPKCS1([]), power: Self.d)), [])
    }

    func testKeyParsing() throws {
        XCTAssertEqual(RSAPublicKey.bytes(hex: "0aBc"), [0x0a, 0xbc])
        XCTAssertEqual(RSAPublicKey.bytes(hex: "abc"), [0x0a, 0xbc])
        XCTAssertNil(RSAPublicKey.bytes(hex: "zz"))
        XCTAssertNil(RSAPublicKey.bytes(hex: ""))
        XCTAssertThrowsError(try RSAPublicKey(modulusHex: "not hex", exponentHex: "010001"))
        XCTAssertThrowsError(try RSAPublicKey(modulusHex: String(repeating: "F", count: 64), exponentHex: "010001"), "too short")
        XCTAssertThrowsError(try RSAPublicKey(modulusHex: String(repeating: "F", count: 511) + "E", exponentHex: "010001"), "even")
        XCTAssertThrowsError(try RSAPublicKey(modulusHex: Self.modulus, exponentHex: "01"))
        // Leading zeros in the hex do not change the key.
        XCTAssertEqual(try RSAPublicKey(modulusHex: "0000" + Self.modulus, exponentHex: "00010001"), try Self.key)
    }
}
