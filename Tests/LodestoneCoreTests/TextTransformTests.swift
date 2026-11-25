import Foundation
@testable import LodestoneCore
import XCTest

final class JSONTextTests: XCTestCase {
    func testPrettyKeepsOrderAndLiterals() throws {
        let input = #"{"b":1.50,"a":[1,2,{"z":null,"y":true}],"big":12345678901234567890,"s":"x\/\u00e9\n","e":{},"f":[]}"#
        XCTAssertEqual(try JSONText.pretty(input), """
        {
          "b": 1.50,
          "a": [
            1,
            2,
            {
              "z": null,
              "y": true
            }
          ],
          "big": 12345678901234567890,
          "s": "x\\/\\u00e9\\n",
          "e": {},
          "f": []
        }
        """)
    }

    func testPrettySortedKeys() throws {
        XCTAssertEqual(try JSONText.pretty(#"{"b":{"d":1,"c":2},"a":0}"#, sortKeys: true), """
        {
          "a": 0,
          "b": {
            "c": 2,
            "d": 1
          }
        }
        """)
    }

    func testMinify() throws {
        XCTAssertEqual(try JSONText.minify("{\n  \"a\" : [ 1 , 2 ],\n  \"b\": \"x y\"\n}\n"), #"{"a":[1,2],"b":"x y"}"#)
        XCTAssertEqual(try JSONText.minify(" 42 "), "42")
        XCTAssertEqual(try JSONText.minify("\u{FEFF}[]"), "[]")
    }

    func testInvalidJSONReportsPosition() {
        func message(_ text: String) -> String {
            do { _ = try JSONText.pretty(text); return "no error" } catch let e as TextTransformError {
                XCTAssertEqual(e.summary, "Not valid JSON")
                return e.message
            } catch { return "\(error)" }
        }
        XCTAssertEqual(message("{\n  \"a\": 1,\n}"), "Not valid JSON: expected a quoted key, found '}' at line 3, column 1")
        XCTAssertEqual(message("{'a': 1}"), "Not valid JSON: expected a quoted key, found ''' at line 1, column 2")
        XCTAssertEqual(message("[1, 2"), "Not valid JSON: unexpected end of text, expected ',' or ']' at line 1, column 6")
        XCTAssertEqual(message("{\"a\" 1}"), "Not valid JSON: expected ':' after a key, found '1' at line 1, column 6")
        XCTAssertEqual(message("01"), "Not valid JSON: numbers can't have leading zeros at line 1, column 1")
        XCTAssertEqual(message("\"abc"), "Not valid JSON: unterminated string at line 1, column 1")
        XCTAssertEqual(message("tru"), "Not valid JSON: unexpected 't' at line 1, column 1")
        XCTAssertEqual(message("{} x"), "Not valid JSON: unexpected 'x' after the end of the JSON value at line 1, column 4")
        XCTAssertEqual(message("   "), "Not valid JSON: the text is empty")
        XCTAssertEqual(message("\"a\\qb\""), "Not valid JSON: invalid escape '\\q' at line 1, column 3")
        XCTAssertEqual(message("1."), "Not valid JSON: expected a digit after '.' at line 1, column 3")
    }

    func testEscapeUnescapeRoundTrip() throws {
        let text = "He said \"hi\"\n\tC:\\path é 🎉 \u{01}"
        let escaped = JSONText.escape(text)
        XCTAssertEqual(escaped, #"He said \"hi\"\n\tC:\\path é 🎉 \u0001"#)
        XCTAssertEqual(try JSONText.unescape(escaped), text)
        XCTAssertEqual(try JSONText.unescape("\"" + escaped + "\""), text)
    }

    func testUnescapeUnicodeEscapes() throws {
        XCTAssertEqual(try JSONText.unescape(#"caf\u00e9 \ud83c\udf89 \/"#), "café 🎉 /")
        XCTAssertThrowsError(try JSONText.unescape(#"bad \x"#))
        XCTAssertThrowsError(try JSONText.unescape(#"bad \u12"#))
    }
}

final class TextCodecTests: XCTestCase {
    func testBase64() throws {
        XCTAssertEqual(TextCodec.base64Encode("hello?>"), "aGVsbG8/Pg==")
        XCTAssertEqual(TextCodec.base64Encode("hello?>", urlSafe: true), "aGVsbG8_Pg")
        XCTAssertEqual(try TextCodec.base64Decode("aGVsbG8/Pg=="), "hello?>")
        XCTAssertEqual(try TextCodec.base64Decode("aGVsbG8_Pg"), "hello?>")
        XCTAssertEqual(try TextCodec.base64Decode(" aGVs\nbG8= "), "hello")
        XCTAssertEqual(try TextCodec.base64Decode(TextCodec.base64Encode("Ünïcødé 🎉")), "Ünïcødé 🎉")
    }

    func testBase64Errors() {
        XCTAssertThrowsError(try TextCodec.base64Decode("not base64!")) { XCTAssertEqual(($0 as? TextTransformError)?.summary, "Not valid Base64") }
        XCTAssertThrowsError(try TextCodec.base64Decode("")) { XCTAssertEqual(($0 as? TextTransformError)?.summary, "Not valid Base64") }
        XCTAssertThrowsError(try TextCodec.base64Decode("/w==")) { XCTAssertEqual(($0 as? TextTransformError)?.summary, "Decoded Base64 isn't text") }
    }

    func testURL() throws {
        XCTAssertEqual(TextCodec.urlEncode("a b&c=d/é~_.-"), "a%20b%26c%3Dd%2F%C3%A9~_.-")
        XCTAssertEqual(try TextCodec.urlDecode("a%20b%26c%3Dd%2F%C3%A9"), "a b&c=d/é")
        XCTAssertEqual(try TextCodec.urlDecode("a+b"), "a+b")
        XCTAssertThrowsError(try TextCodec.urlDecode("100%"))
    }

    func testHTMLEntities() {
        XCTAssertEqual(HTMLEntities.encode(#"<a href="x">Tom & Jerry's</a>"#), "&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry&#39;s&lt;/a&gt;")
        XCTAssertEqual(HTMLEntities.decode("&lt;p&gt;Tom &amp; Jerry&#39;s &#x1F389; &copy; &unknown; AT&T &#;"), "<p>Tom & Jerry's 🎉 © &unknown; AT&T &#;")
        let text = #"<b>"quoted" & 'single'</b>"#
        XCTAssertEqual(HTMLEntities.decode(HTMLEntities.encode(text)), text)
    }
}

final class JWTTests: XCTestCase {
    // {"alg":"HS256","typ":"JWT"} . {"sub":"1234567890","name":"John Doe","iat":1516239022,"exp":1516242622}
    let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyLCJleHAiOjE1MTYyNDI2MjJ9.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

    func testDecode() throws {
        let decoded = try JWT.decode("Bearer " + token, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(decoded.header, "{\n  \"alg\": \"HS256\",\n  \"typ\": \"JWT\"\n}")
        XCTAssertEqual(decoded.dates.map(\.claim), ["iat", "exp"])
        XCTAssertEqual(decoded.text, """
        Header
        {
          "alg": "HS256",
          "typ": "JWT"
        }

        Payload
        {
          "sub": "1234567890",
          "name": "John Doe",
          "iat": 1516239022,
          "exp": 1516242622
        }

        Issued at (iat):  2018-01-18T01:30:22Z
        Expires (exp):    2018-01-18T02:30:22Z (expired)

        Signature not verified.
        """)
    }

    func testNotExpired() throws {
        let decoded = try JWT.decode(token, now: Date(timeIntervalSince1970: 1_516_240_000))
        XCTAssertTrue(decoded.text.contains("2018-01-18T02:30:22Z (not expired)"))
    }

    func testErrors() {
        XCTAssertThrowsError(try JWT.decode("abc")) { XCTAssertEqual(($0 as? TextTransformError)?.summary, "Not a JWT") }
        XCTAssertThrowsError(try JWT.decode("a.b.c")) { XCTAssertEqual(($0 as? TextTransformError)?.message, "Not a JWT: the header isn't Base64-encoded JSON") }
    }
}

final class TimestampTests: XCTestCase {
    func testNumberToISO() throws {
        XCTAssertEqual(try Timestamp.convert("1700000000"), "2023-11-14T22:13:20Z")
        XCTAssertEqual(try Timestamp.convert(" 1700000000123\n"), "2023-11-14T22:13:20.123Z")
        XCTAssertEqual(try Timestamp.convert("1700000000123456"), "2023-11-14T22:13:20.123Z")
        XCTAssertEqual(try Timestamp.convert("1700000000123456789"), "2023-11-14T22:13:20.123Z")
        XCTAssertEqual(try Timestamp.convert("0"), "1970-01-01T00:00:00Z")
        XCTAssertEqual(try Timestamp.convert("1700000000.5"), "2023-11-14T22:13:20.500Z")
    }

    func testUnitDetection() {
        XCTAssertEqual(Timestamp.unit(of: 1_700_000_000), .seconds)
        XCTAssertEqual(Timestamp.unit(of: 99_999_999_999), .seconds)
        XCTAssertEqual(Timestamp.unit(of: 1_700_000_000_000), .milliseconds)
        XCTAssertEqual(Timestamp.unit(of: 1_700_000_000_000_000), .microseconds)
        XCTAssertEqual(Timestamp.unit(of: 1.7e18), .nanoseconds)
    }

    func testISOToNumber() throws {
        XCTAssertEqual(try Timestamp.convert("2023-11-14T22:13:20Z"), "1700000000")
        XCTAssertEqual(try Timestamp.convert("2023-11-14T22:13:20.123Z"), "1700000000.123")
        XCTAssertEqual(try Timestamp.convert("2023-11-15T01:13:20+03:00"), "1700000000")
        XCTAssertEqual(try Timestamp.convert("2023-11-14 22:13:20"), "1700000000")
        XCTAssertEqual(try Timestamp.convert("2023-11-14"), "1699920000")
        XCTAssertThrowsError(try Timestamp.convert("yesterday"))
        XCTAssertThrowsError(try Timestamp.convert(""))
    }
}

final class TextCaseTests: XCTestCase {
    func testWords() {
        XCTAssertEqual(TextCase.words("fooBarBaz"), ["foo", "Bar", "Baz"])
        XCTAssertEqual(TextCase.words("HTTPServerError"), ["HTTP", "Server", "Error"])
        XCTAssertEqual(TextCase.words("base64UrlDecode"), ["base64", "Url", "Decode"])
        XCTAssertEqual(TextCase.words("snake_case-and kebab"), ["snake", "case", "and", "kebab"])
        XCTAssertEqual(TextCase.words("CONSTANT_VALUE"), ["CONSTANT", "VALUE"])
        XCTAssertEqual(TextCase.words("  __ "), [])
    }

    func testConversions() {
        let input = "user profile_imageURL"
        XCTAssertEqual(TextCase.convert(input, to: .camel), "userProfileImageUrl")
        XCTAssertEqual(TextCase.convert(input, to: .pascal), "UserProfileImageUrl")
        XCTAssertEqual(TextCase.convert(input, to: .snake), "user_profile_image_url")
        XCTAssertEqual(TextCase.convert(input, to: .kebab), "user-profile-image-url")
        XCTAssertEqual(TextCase.convert(input, to: .constant), "USER_PROFILE_IMAGE_URL")
        XCTAssertEqual(TextCase.convert("XMLHttpRequest", to: .snake), "xml_http_request")
        XCTAssertEqual(TextCase.convert("userId", to: .title), "User Id")
    }

    func testTitleCaseSentence() {
        XCTAssertEqual(TextCase.convert("the QUICK brown fox, jumps!", to: .title), "The Quick Brown Fox, Jumps!")
    }

    func testPerLineKeepsIndentAndEndings() {
        XCTAssertEqual(TextCase.convert("fooBar\n  bazQux\n", to: .snake), "foo_bar\n  baz_qux\n")
        XCTAssertEqual(TextCase.convert("fooBar\r\nbazQux", to: .kebab), "foo-bar\r\nbaz-qux")
    }

    func testTransformNames() {
        XCTAssertEqual(TextTransform.base64UrlDecode.name, "base64-url-decode")
        XCTAssertEqual(TextTransform.sha256.name, "sha256")
        XCTAssertEqual(TextTransform.md5.name, "md5")
        XCTAssertEqual(TextTransform.jsonPrettySorted.name, "json-pretty-sorted")
        XCTAssertEqual(TextTransform(name: "json-pretty"), .jsonPretty)
        XCTAssertEqual(TextTransform(name: "jsonPretty"), .jsonPretty)
        XCTAssertEqual(TextTransform(name: "text.jsonPretty"), .jsonPretty)
        XCTAssertEqual(TextTransform(name: "SNAKE_CASE"), .snakeCase)
        XCTAssertNil(TextTransform(name: "rot13"))
        // Every transform's CLI name round-trips and is unique.
        XCTAssertEqual(Set(TextTransform.allCases.map(\.name)).count, TextTransform.allCases.count)
        for t in TextTransform.allCases { XCTAssertEqual(TextTransform(name: t.name), t) }
        // Every transform appears in exactly one menu group.
        XCTAssertEqual(TextTransform.groups.flatMap(\.transforms).sorted { $0.rawValue < $1.rawValue },
                       TextTransform.allCases.sorted { $0.rawValue < $1.rawValue })
    }
}

final class TextLinesTests: XCTestCase {
    func testSort() {
        XCTAssertEqual(TextLines.sort("b\nfile10\nA\nfile2\na\n"), "A\na\nb\nfile2\nfile10\n")
        XCTAssertEqual(TextLines.sort("b\r\na"), "a\r\nb")
    }

    func testDedupeAndReverse() {
        XCTAssertEqual(TextLines.dedupe("x\ny\nx\nz\ny"), "x\ny\nz")
        XCTAssertEqual(TextLines.reverse("1\n2\n3\n"), "3\n2\n1\n")
        XCTAssertEqual(TextLines.reverse(""), "")
    }

    func testWhitespace() throws {
        XCTAssertEqual(TextLines.collapseWhitespace("  a \t b\n\n c  "), "a b c")
        XCTAssertEqual(try TextTransform.trim.apply("\n  hello world \t\n"), "hello world")
    }

    func testCounts() {
        XCTAssertEqual(TextCounts("Hello brave new world\nSecond line\n"), TextCounts(characters: 34, words: 6, lines: 2))
        XCTAssertEqual(TextCounts(""), TextCounts(characters: 0, words: 0, lines: 0))
        XCTAssertEqual(TextCounts("one"), TextCounts(characters: 3, words: 1, lines: 1))
        XCTAssertEqual(TextCounts("a\r\nb").lines, 2)
        XCTAssertEqual(TextCounts("🎉 é").characters, 3)
        XCTAssertEqual(TextCounts("one").description, "3 characters, 1 word, 1 line")
    }

    func testHashes() {
        XCTAssertEqual(TextHash.hex("hello", .md5), "5d41402abc4b2a76b9719d911017c592")
        XCTAssertEqual(TextHash.hex("hello", .sha1), "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
        XCTAssertEqual(TextHash.hex("hello", .sha256), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(TextHash.hex("", .sha256), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testUUID() throws {
        let a = try TextTransform.uuid.apply("ignored"), b = try TextTransform.uuid.apply("")
        XCTAssertNotEqual(a, b)
        let pattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#
        XCTAssertNotNil(a.range(of: pattern, options: .regularExpression), a)
    }

    func testEveryTransformRunsOnPlainText() {
        for t in TextTransform.allCases {
            switch t {
            case .jsonPretty, .jsonPrettySorted, .jsonMinify, .jwtDecode, .timestamp, .base64Decode, .base64UrlDecode:
                XCTAssertThrowsError(try t.apply("hello world!"), t.name)
            default:
                XCTAssertNoThrow(try t.apply("hello world!"), t.name)
            }
        }
    }
}

extension TextCounts {
    init(characters: Int, words: Int, lines: Int) {
        self.init("")
        self.characters = characters
        self.words = words
        self.lines = lines
    }
}
