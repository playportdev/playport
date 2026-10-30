// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import XboxClientKit

final class XboxCryptoTests: XCTestCase, @unchecked Sendable {
    func hex(_ value: String) -> [UInt8] {
        stride(from: 0, to: value.count, by: 2).map { i in
            let start = value.index(value.startIndex, offsetBy: i)
            return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
        }
    }
    func testAES128AndHMACAgainstFIPS197AndRFC4231() throws {
        let aes = try XboxAES128(Array(0...15))
        XCTAssertEqual(aes.block(hex("69c4e0d86a7b0430d8cdb78070b4c55a")), hex("00112233445566778899aabbccddeeff"))
        XCTAssertEqual(XboxCrypto.hmac([UInt8](repeating: 0x0b, count: 20), Array("Hi There".utf8)),
                       hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"))
    }
    func testTheSyntheticBCryptKeySignsLikePythonCryptography() throws {
        let key = try XboxRSA(xboxFixture("synthetic-rsa.bin"))
        XCTAssertEqual(try key.sign(Array("Playport synthetic RSA known-answer vector".utf8)), try xboxFixture("rsa-signature.bin"))
        XCTAssertEqual(key.privateDER(), try xboxFixture("synthetic-rsa.der"))
    }
    func testOutgoingBrokerSignaturesCoverTheTransmittedXML() async throws {
        let http = XboxFixtureHTTP(), store = MemorySecretStore()
        let session = XboxSession(store: store, http: http, now: { Date(timeIntervalSince1970: 1_793_318_400) })
        _ = try await session.prepareSignIn()
        _ = try await session.signIn(xboxSignInToken())
        let key = try XboxRSA(xboxFixture("synthetic-rsa.bin"))
        for operation in ["authenticate", "signin"] {
            let request = await http.request(operation)!
            let root = try XboxXML.parse(request.body.value)
            let security = root.child("Header")!.child("Security")!
            let signature = security.child("Signature")!, info = signature.child("SignedInfo")!
            let signed = Array(info.canonical().utf8)
            let actual = try XboxCrypto.decode(signature.value("SignatureValue")!)
            if operation == "authenticate" {
                let encoded = XboxRSA.power(actual, key.e, modulus: key.n)
                XCTAssertEqual(Array(encoded.suffix(32)), SHA256Stream.hash(signed))
                XCTAssertEqual(Array(encoded.prefix(2)), [0, 1])
            } else {
                let nonce = try XboxCrypto.decode(security.child("DerivedKeyToken")!.value("Nonce")!)
                // The fixture's HMAC proof is bytes 0...31, independently sealed
                // with Python cryptography; this is not the production extractor.
                let derived = XboxCrypto.derived(Array(0...31), nonce: nonce)
                XCTAssertEqual(actual, XboxCrypto.hmac(derived, signed))
            }
            func nodes(_ n: XboxXML) -> [XboxXML] { [n] + n.children.flatMap(nodes) }
            for reference in info.children where reference.local == "Reference" {
                let id = String(reference.attributes["URI"]!.dropFirst())
                let target = nodes(root).first { $0.attr("Id") == id }!
                XCTAssertEqual(try XboxCrypto.decode(reference.value("DigestValue")!), SHA256Stream.hash(Array(target.canonical().utf8)))
            }
        }
    }

    /// Only UTF-8 is read, and a DTD in any form is refused: a UTF-16 document (BOM or
    /// not) can't slip a DOCTYPE past a byte search, and the parser itself refuses one.
    func testXMLIsUTF8OnlyAndADTDIsRefused() throws {
        XCTAssertEqual(try XboxXML.parse(Array("<?xml version=\"1.0\" encoding=\"UTF-8\"?><a>é</a>".utf8)).text, "é")
        let dtd = "<?xml version=\"1.0\"?><!DOCTYPE a [<!ENTITY e \"x\">]><a>&e;</a>"
        func utf16(_ s: String, bom: Bool) -> [UInt8] {
            (bom ? [0xFF, 0xFE] : []) + s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        }
        for (what, bytes) in [("UTF-8 DTD", Array(dtd.utf8)), ("UTF-16 with BOM", utf16(dtd, bom: true)),
                              ("UTF-16 without BOM", utf16(dtd, bom: false)), ("UTF-16 plain", utf16("<a>x</a>", bom: true)),
                              ("Latin-1 declared", Array("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a>x</a>".utf8)),
                              ("invalid UTF-8", [0x3C, 0x61, 0x3E, 0xC3, 0x28, 0x3C, 0x2F, 0x61, 0x3E]),
                              ("DOCTYPE in lower case", Array("<!doctype a><a/>".utf8))] {
            XCTAssertThrowsError(try XboxXML.parse(bytes), what)
        }
    }
}
