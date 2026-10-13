// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import PlayportKit

/// GameControlsRecords: `controls.games` read record by record (S1Probe ControlsStore).
final class GameControlsRecordsTests: XCTestCase {
    /// A later build's layout (unknown here) and a typo beside two good records.
    let stored = Data(#"""
    {"app-367520":{"layout":"off","opacity":0.5},
     "app-620":{"layout":"keyboardMouse","gyro":{"output":"mouse"},"extra":[1,true,null,"x"]},
     "app-400":{"rightStick":"sideways"},
     "app-70":{"controllerMap":{"mode":"keyboardMouse"},"lookSpeed":1.5}}
    """#.utf8)

    func testOneBadRecordKeepsTheOthersAndASetGameKeepsTheBadRecordsBytes() throws {
        var r = try XCTUnwrap(GameControlsRecords(json: stored))
        XCTAssertEqual(r["app-367520"], GameControls(layout: .off, opacity: 0.5))
        XCTAssertEqual(r["app-70"]?.lookSpeed, 1.5)
        XCTAssertNil(r["app-620"])
        XCTAssertEqual(Set(r.unreadable.keys), ["app-620", "app-400"])
        let bad620 = try XCTUnwrap(r.unreadable["app-620"]), bad400 = try XCTUnwrap(r.unreadable["app-400"])

        // Another game's change: the unreadable records go back as they came.
        r.set("app-1", GameControls(opacity: 0.8))
        r.set("app-367520", nil)
        let again = try XCTUnwrap(GameControlsRecords(json: r.json()))
        XCTAssertEqual(again.unreadable["app-620"], bad620)
        XCTAssertEqual(again.unreadable["app-400"], bad400)
        XCTAssertEqual(again["app-1"], GameControls(opacity: 0.8))
        XCTAssertNil(again["app-367520"])
        XCTAssertEqual(again["app-70"], r["app-70"])
        XCTAssertEqual(again, r)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: again.json()) as? [String: Any])
        let kept = try XCTUnwrap(object["app-620"] as? [String: Any])
        XCTAssertEqual(kept["layout"] as? String, "keyboardMouse")
        XCTAssertEqual((kept["extra"] as? [Any])?.count, 4)

        // A change to that game itself is the player's: it replaces the record.
        r.set("app-400", GameControls(rightStick: .above))
        XCTAssertNil(r.unreadable["app-400"])
        XCTAssertEqual(r["app-400"], GameControls(rightStick: .above))
        // Nothing set is no record.
        r.set("app-1", GameControls())
        XCTAssertNil(r["app-1"])
    }

    func testStoredJSONThatIsNotAnObjectIsNotRead() {
        XCTAssertNil(GameControlsRecords(json: Data("[1,2]".utf8)))
        XCTAssertNil(GameControlsRecords(json: Data("{\"app-1\":".utf8)))
        XCTAssertEqual(GameControlsRecords(json: Data("{}".utf8)), GameControlsRecords())
    }
}
