import Foundation
@testable import LodestoneCore
import XCTest

final class KeyComboTextTests: XCTestCase {
    func testParse() throws {
        XCTAssertEqual(try KeyComboText.parse("ctrl+opt+left"), KeyCombo(keyCode: 123, modifiers: 6144))
        XCTAssertEqual(try KeyComboText.parse("Control + Option + 1"), KeyCombo(keyCode: 18, modifiers: 6144))
        XCTAssertEqual(try KeyComboText.parse("cmd+shift+v"), KeyCombo(keyCode: 9, modifiers: 768))
        XCTAssertEqual(try KeyComboText.parse("⌃+⌥+↩"), KeyCombo(keyCode: 36, modifiers: 6144))
        XCTAssertEqual(try KeyComboText.parse("f5"), KeyCombo(keyCode: 96, modifiers: 0))
        XCTAssertEqual(try KeyComboText.parse("alt+backspace"), KeyCombo(keyCode: 51, modifiers: 2048))
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try KeyComboText.parse("ctrl+opt"))
        XCTAssertThrowsError(try KeyComboText.parse("ctrl+banana"))
        XCTAssertThrowsError(try KeyComboText.parse("a+ctrl"))
    }

    func testRoundTrip() throws {
        for text in ["ctrl+opt+left", "ctrl+opt+cmd+right", "ctrl+opt+shift+v", "cmd+,", "ctrl+opt+delete", "f12"] {
            XCTAssertEqual(KeyComboText.format(try KeyComboText.parse(text)), text)
        }
    }
}

final class JSONValueTests: XCTestCase {
    struct Sample: Codable, Equatable {
        var name: String
        var count: Int
        var tags: [String]
        var nested: [String: Double]?
    }

    func testRoundTripThroughJSONValue() throws {
        let sample = Sample(name: "a", count: 3, tags: ["x", "y"], nested: ["q": 0.5])
        let value = try JSONValue(encoding: sample)
        XCTAssertEqual(value["name"], "a")
        XCTAssertEqual(value["count"]?.int, 3)
        XCTAssertEqual(try value.decode(Sample.self), sample)
    }

    func testDecodesFromText() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":[1,true,null,"s"]}"#.utf8))
        XCTAssertEqual(value, ["a": [1, true, nil, "s"]])
    }
}

final class SettingDefinitionTests: XCTestCase {
    func testParseAndValidate() throws {
        let b = SettingDefinition("x.flag", title: "", kind: .bool, default: true)
        XCTAssertEqual(try b.parse("off"), .bool(false))
        XCTAssertThrowsError(try b.parse("maybe"))

        let i = SettingDefinition("x.count", title: "", kind: .int(range: 1...10), default: 5)
        XCTAssertEqual(try i.parse("7"), .number(7))
        XCTAssertThrowsError(try i.parse("11"))
        XCTAssertThrowsError(try i.validate(.number(2.5)))
        XCTAssertEqual(try i.validate("3"), .number(3))

        let c = SettingDefinition("x.format", title: "", kind: .choice(["webp", "png"]), default: "png")
        XCTAssertEqual(try c.validate("webp"), "webp")
        XCTAssertThrowsError(try c.validate("gif"))
    }
}
