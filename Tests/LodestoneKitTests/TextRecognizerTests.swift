import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
@testable import LodestoneKit
import LodestoneCore
import XCTest

/// Runs Vision on images drawn here, so the expected text is known.
final class TextRecognizerTests: XCTestCase {
    private func render(width: Int, height: Int, lines: [String] = [], qr: String? = nil) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black]
        var y = CGFloat(height) - 60
        for line in lines {
            if !line.isEmpty { (line as NSString).draw(at: NSPoint(x: 30, y: y), withAttributes: attrs) }
            y -= line.isEmpty ? 50 : 46
        }
        NSGraphicsContext.restoreGraphicsState()
        if let qr {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(qr.utf8)
            let image = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
            let code = CIContext().createCGImage(image, from: image.extent)!
            ctx.interpolationQuality = .none
            ctx.draw(code, in: CGRect(x: width - code.width - 30, y: 30, width: code.width, height: code.height))
        }
        return ctx.makeImage()!
    }

    func testRecognizesLinesInOrder() throws {
        let image = render(width: 800, height: 260, lines: ["The quick brown fox", "jumps over 1234 dogs.", "", "A new paragraph."])
        let result = try TextRecognizer.recognize(image, options: .init(languages: ["en-US"]))
        XCTAssertEqual(result.text, "The quick brown fox\njumps over 1234 dogs.\n\nA new paragraph.")
        XCTAssertEqual(result.width, 800)
        XCTAssertEqual(result.height, 260)
        XCTAssertTrue(result.codes.isEmpty)
        let first = try XCTUnwrap(result.lines.first)
        XCTAssertGreaterThan(first.confidence, 0.5)
        // Pixels, top-left origin: the first line starts near x = 30 at the top of the image.
        XCTAssertEqual(first.box.x, 30, accuracy: 8)
        XCTAssertLessThan(first.box.y, 60)
    }

    func testDecodesQRCodeAlongsideText() throws {
        let image = render(width: 700, height: 300, lines: ["Scan me"], qr: "https://example.com/lodestone")
        let result = try TextRecognizer.recognize(image)
        XCTAssertEqual(result.codes.map(\.payload), ["https://example.com/lodestone"])
        XCTAssertEqual(result.codes.first?.symbology, "qr")
        XCTAssertTrue(result.text.contains("Scan me"), result.text)
        XCTAssertEqual(OCRClipboard(result, preference: .code)?.message, "Copied QR link")
    }

    func testReadsFilesAndReportsBadOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("hello.png")
        let rep = NSBitmapImageRep(cgImage: render(width: 500, height: 120, lines: ["Hello Lodestone"]))
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        XCTAssertEqual(try TextRecognizer.recognize(fileAt: png).text, "Hello Lodestone")

        let bad = dir.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: bad)
        XCTAssertThrowsError(try TextRecognizer.recognize(fileAt: bad)) { XCTAssertEqual(($0 as? IPCError)?.code, "unreadable") }
        XCTAssertThrowsError(try TextRecognizer.recognize(fileAt: dir.appendingPathComponent("missing.png"))) {
            XCTAssertEqual(($0 as? IPCError)?.code, "not_found")
        }
    }

    func testLanguages() {
        XCTAssertTrue(TextRecognizer.supportedLanguages().contains("en-US"))
        let resolved = TextRecognizer.resolveLanguages(["en", "de", "xx"])
        XCTAssertEqual(resolved.languages, ["en-US", "de-DE"])
        XCTAssertEqual(resolved.unsupported, ["xx"])
    }
}
