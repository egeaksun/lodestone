import Foundation
@testable import LodestoneCore
import XCTest

final class ColorValueTests: XCTestCase {
    let orange = ColorValue(red: 1, green: 136.0 / 255, blue: 0)

    func testFormats() {
        XCTAssertEqual(orange.formatted(.hex), "#ff8800")
        XCTAssertEqual(orange.formatted(.rgb), "rgb(255, 136, 0)")
        XCTAssertEqual(orange.formatted(.hsl), "hsl(32, 100%, 50%)")
        XCTAssertEqual(orange.formatted(.swiftui), "Color(red: 1, green: 0.533, blue: 0)")
        XCTAssertEqual(orange.formatted(.nscolor), "NSColor(srgbRed: 1, green: 0.533, blue: 0, alpha: 1)")
        XCTAssertEqual(orange.formatted(.uicolor), "UIColor(red: 1, green: 0.533, blue: 0, alpha: 1)")
    }

    func testAlphaFormats() {
        let c = ColorValue(red: 1, green: 136.0 / 255, blue: 0, alpha: 0.5)
        XCTAssertEqual(c.formatted(.hex), "#ff880080")
        XCTAssertEqual(c.formatted(.rgb), "rgba(255, 136, 0, 0.5)")
        XCTAssertEqual(c.formatted(.hsl), "hsla(32, 100%, 50%, 0.5)")
        XCTAssertEqual(c.formatted(.swiftui), "Color(red: 1, green: 0.533, blue: 0, opacity: 0.5)")
    }

    func testParseHex() throws {
        XCTAssertEqual(try ColorValue.parse("#ff8800").hex, "#ff8800")
        XCTAssertEqual(try ColorValue.parse("FF8800").hex, "#ff8800")
        XCTAssertEqual(try ColorValue.parse("0xff8800").hex, "#ff8800")
        XCTAssertEqual(try ColorValue.parse("#f80").hex, "#ff8800")
        XCTAssertEqual(try ColorValue.parse("#f808").hex, "#ff880088")
        XCTAssertEqual(try ColorValue.parse(" #ff880080 ").alpha, 128.0 / 255, accuracy: 1e-9)
    }

    func testParseCSS() throws {
        XCTAssertEqual(try ColorValue.parse("rgb(255, 136, 0)").hex, "#ff8800")
        XCTAssertEqual(try ColorValue.parse("rgb(255 136 0 / 50%)").hex, "#ff880080")
        XCTAssertEqual(try ColorValue.parse("rgba(255,136,0,0.5)").hex, "#ff880080")
        XCTAssertEqual(try ColorValue.parse("rgb(100%, 0%, 50%)").hex, "#ff0080")
        XCTAssertEqual(try ColorValue.parse("hsl(32, 100%, 50%)").hex, "#ff8800")
        XCTAssertEqual(try ColorValue.parse("hsl(32deg 100% 50%)").hex, "#ff8800")
        XCTAssertEqual(try ColorValue.parse("HSLA(210, 50%, 40%, 0.25)").formatted(.hsl), "hsla(210, 50%, 40%, 0.25)")
    }

    func testParseSwift() throws {
        XCTAssertEqual(try ColorValue.parse("Color(red: 1, green: 0.533, blue: 0)").hex, "#ff8800")
        XCTAssertEqual(try ColorValue.parse("NSColor(srgbRed: 1, green: 0.533, blue: 0, alpha: 0.5)").hex, "#ff880080")
        XCTAssertEqual(try ColorValue.parse("UIColor(red: 0, green: 0, blue: 1, alpha: 1)").hex, "#0000ff")
    }

    func testParseErrors() {
        for bad in ["", "#ff88f", "#gg8800", "rgb(1, 2)", "hsl(a, b, c)", "banana", "Color(white: 1)"] {
            XCTAssertThrowsError(try ColorValue.parse(bad), bad) { XCTAssertEqual(($0 as? TextTransformError)?.summary, "Not a color") }
        }
    }

    func testHSLRoundTrip() {
        for hex in ["#000000", "#ffffff", "#808080", "#ff0000", "#00ff00", "#0000ff", "#123456", "#fedcba", "#ff00ff", "#33cc99"] {
            let c = ColorValue.parseHex(hex)!
            let (h, s, l) = c.hsl
            XCTAssertEqual(ColorValue(hue: h, saturation: s, lightness: l).hex, hex)
        }
        XCTAssertEqual(ColorValue.parseHex("#808080")!.formatted(.hsl), "hsl(0, 0%, 50%)")
        XCTAssertEqual(ColorValue.parseHex("#0000ff")!.formatted(.hsl), "hsl(240, 100%, 50%)")
        XCTAssertEqual(ColorValue.parseHex("#ff0080")!.formatted(.hsl), "hsl(330, 100%, 50%)")
    }

    func testClampsAndNumbers() {
        let c = ColorValue(red: 1.5, green: -1, blue: .nan)
        XCTAssertEqual(c.hex, "#ff0000")
        XCTAssertEqual(ColorValue.number(0.5), "0.5")
        XCTAssertEqual(ColorValue.number(1), "1")
        XCTAssertEqual(ColorValue.number(0.0001), "0")
    }

    func testFormatNames() {
        XCTAssertEqual(ColorFormat(name: "SwiftUI"), .swiftui)
        XCTAssertEqual(ColorFormat(name: "css"), .rgb)
        XCTAssertEqual(ColorFormat(name: "uikit"), .uicolor)
        XCTAssertNil(ColorFormat(name: "cmyk"))
        XCTAssertEqual(orange.allFormats["hsl"], "hsl(32, 100%, 50%)")
    }

    func testHistory() {
        var h = ColorHistory()
        for i in 0..<12 { h.add(ColorValue(red: Double(i) / 255, green: 0, blue: 0)) }
        XCTAssertEqual(h.colors.count, 10)
        XCTAssertEqual(h.colors.first?.hex, "#0b0000")
        h.add(ColorValue.parseHex("#050000")!)
        XCTAssertEqual(h.colors.first?.hex, "#050000")
        XCTAssertEqual(h.colors.count, 10)
        XCTAssertEqual(h.hexStrings.filter { $0 == "#050000" }.count, 1)
        XCTAssertEqual(ColorHistory(hexStrings: h.hexStrings + ["junk"]), h)
    }
}

final class OCRModelTests: XCTestCase {
    func line(_ text: String, x: Double, y: Double, w: Double = 100, h: Double = 20) -> OCRLine {
        OCRLine(text: text, confidence: 1, box: OCRBox(x: x, y: y, width: w, height: h))
    }

    func testLayoutOrdersRowsAndParagraphs() {
        let lines = [
            line("second line", x: 10, y: 34),
            line("world", x: 120, y: 12),
            line("Hello", x: 10, y: 10),
            line("New paragraph", x: 10, y: 120),
        ]
        XCTAssertEqual(OCRLayout.text(lines), "Hello world\nsecond line\n\nNew paragraph")
        XCTAssertEqual(OCRLayout.text([]), "")
    }

    func testClipboardPreference() {
        let qr = OCRCode(payload: "https://example.com", symbology: "qr", box: OCRBox(x: 0, y: 0, width: 10, height: 10))
        let both = OCRResult(lines: [line("Scan me now", x: 0, y: 0)], codes: [qr], width: 100, height: 100, languages: [], ms: 1)
        XCTAssertEqual(OCRClipboard(both, preference: .code), OCRClipboard(text: "https://example.com", message: "Copied QR link"))
        XCTAssertEqual(OCRClipboard(both, preference: .text), OCRClipboard(text: "Scan me now", message: "Copied 3 words"))
        XCTAssertEqual(OCRClipboard(both, preference: .both)?.text, "Scan me now\n\nhttps://example.com")
        XCTAssertEqual(OCRClipboard(both, preference: .both)?.message, "Copied 3 words and a code")

        let textOnly = OCRResult(lines: [line("one", x: 0, y: 0)], codes: [], width: 1, height: 1, languages: [], ms: 1)
        XCTAssertEqual(OCRClipboard(textOnly, preference: .code)?.message, "Copied 1 word")
        let barcode = OCRResult(lines: [], codes: [OCRCode(payload: "4006381333931", symbology: "ean13", box: qr.box)],
                                width: 1, height: 1, languages: [], ms: 1)
        XCTAssertEqual(OCRClipboard(barcode, preference: .text), OCRClipboard(text: "4006381333931", message: "Copied barcode value"))
        let empty = OCRResult(lines: [], codes: [], width: 1, height: 1, languages: [], ms: 1)
        XCTAssertNil(OCRClipboard(empty, preference: .code))
        XCTAssertTrue(empty.isEmpty)
    }

    func testLanguages() {
        let supported = ["en-US", "fr-FR", "zh-Hans", "zh-Hant", "pt-BR"]
        XCTAssertEqual(OCRLanguages.parse(" en, tr;zh-Hant  fr"), ["en", "tr", "zh-Hant", "fr"])
        let r = OCRLanguages.resolve(["en", "tr", "zh-hant", "pt_BR", "en-US"], supported: supported)
        XCTAssertEqual(r.languages, ["en-US", "zh-Hant", "pt-BR"])
        XCTAssertEqual(r.unsupported, ["tr"])
        XCTAssertEqual(OCRLanguages.resolve(["zh"], supported: supported).languages, ["zh-Hans"])
    }
}

extension OCRClipboard {
    init(text: String, message: String) {
        self = OCRClipboard(OCRResult(lines: [], codes: [OCRCode(payload: "x", symbology: "qr", box: OCRBox(x: 0, y: 0, width: 1, height: 1))],
                                      width: 1, height: 1, languages: [], ms: 0), preference: .code)!
        self.text = text
        self.message = message
    }
}
