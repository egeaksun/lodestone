import CoreGraphics
import CoreText
import Foundation
import ImageIO
import LodestoneCore
@testable import LodestoneKit
import PDFKit
import XCTest

/// End-to-end checks of the PDF engine on small generated files (PDFKit only; no Ghostscript).
final class PDFToolsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lodestone-pdf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makePDF(_ name: String, pages: Int) -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for i in 0..<pages {
            ctx.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(name) page \(i + 1)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 24, nil),
            ]))
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    private func makePNG(_ name: String, width: Int, height: Int) -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    private func pageTexts(_ path: String) -> [String] {
        let doc = PDFDocument(url: URL(fileURLWithPath: path))!
        return (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
    }

    func testMergeKeepsOrderAndNeverOverwrites() async throws {
        let a = makePDF("A.pdf", pages: 2), b = makePDF("B.pdf", pages: 1)
        let first = try await PDFTools.merge([b, a])
        XCTAssertEqual(URL(fileURLWithPath: first.output).lastPathComponent, "B (merged).pdf")
        XCTAssertEqual(first.pages, 3)
        XCTAssertEqual(pageTexts(first.output).map { $0.contains("B.pdf") }, [true, false, false])
        let second = try await PDFTools.merge([b, a])
        XCTAssertEqual(URL(fileURLWithPath: second.output).lastPathComponent, "B (merged 2).pdf")
        // An explicit output that exists is refused.
        do {
            _ = try await PDFTools.merge([a, b], output: URL(fileURLWithPath: first.output))
            XCTFail("expected file_exists")
        } catch let error as IPCError {
            XCTAssertEqual(error.code, "file_exists")
        }
    }

    func testExtractSplitAndRotate() async throws {
        let src = makePDF("Doc.pdf", pages: 5)
        let combined = try await PDFTools.extract(src, pages: try PageRanges.parse("4-,1"), mode: .combined)
        XCTAssertEqual(combined.outputs.count, 1)
        XCTAssertEqual(combined.outputs[0].pages, [4, 5, 1])
        XCTAssertTrue(pageTexts(combined.outputs[0].path)[0].contains("page 4"))

        let perRange = try await PDFTools.extract(src, pages: try PageRanges.parse("1-2,3-5"), mode: .perRange)
        XCTAssertEqual(perRange.outputs.map(\.pages), [[1, 2], [3, 4, 5]])
        XCTAssertEqual(URL(fileURLWithPath: perRange.outputs[1].path).lastPathComponent, "Doc (pages 3-5).pdf")

        let folder = dir.appendingPathComponent("split")
        let perPage = try await PDFTools.extract(src, pages: .all, mode: .perPage, output: folder)
        XCTAssertEqual(perPage.outputs.count, 5)
        XCTAssertTrue(perPage.outputs.allSatisfy { $0.path.hasPrefix(folder.path) })

        let rotated = try await PDFTools.rotate(src, angle: -90, pages: try PageRanges.parse("2"))
        let doc = PDFDocument(url: URL(fileURLWithPath: rotated.output))!
        XCTAssertEqual((0..<5).map { doc.page(at: $0)!.rotation }, [0, 270, 0, 0, 0])
    }

    func testCompressWithPDFKitKeepsTextOrKeepsOriginal() async throws {
        let src = makePDF("Text.pdf", pages: 2)
        let r = try await PDFTools.compress(src, level: .balanced, engine: .pdfkit)
        XCTAssertEqual(r.engine, "pdfkit")
        if let output = r.output {
            XCTAssertLessThan(r.compressedBytes, r.originalBytes)
            XCTAssertTrue(pageTexts(output)[1].contains("page 2"), "text stays selectable")
        } else {
            XCTAssertTrue(r.keptOriginal)
            // Nothing was written next to the source.
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Text (compressed).pdf").path))
        }
    }

    func testFromImagesAndRender() async throws {
        let wide = makePNG("Wide.png", width: 400, height: 200)
        let tall = makePNG("Tall.png", width: 100, height: 300)
        let r = try await PDFTools.fromImages([wide, tall], pageSize: .fit, margin: 10)
        XCTAssertEqual(r.pages, 2)
        let doc = PDFDocument(url: URL(fileURLWithPath: r.output))!
        XCTAssertEqual(doc.page(at: 0)!.bounds(for: .mediaBox).size, CGSize(width: 420, height: 220))
        XCTAssertEqual(doc.page(at: 1)!.bounds(for: .mediaBox).size, CGSize(width: 120, height: 320))

        let images = try await PDFTools.toImages(URL(fileURLWithPath: r.output), format: .png, dpi: 144)
        XCTAssertEqual(images.files.count, 2)
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: images.files[0]) as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 840)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 440)
    }

    func testInfoAndErrors() async throws {
        let src = makePDF("Info.pdf", pages: 3)
        let info = try PDFTools.info(src)
        XCTAssertEqual(info.pages, 3)
        XCTAssertEqual(info.pageSize, PDFInfo.Size(width: 612, height: 792))
        XCTAssertTrue(info.hasTextLayer)
        XCTAssertFalse(info.encrypted)

        let notPDF = makePNG("NotPDF.pdf", width: 10, height: 10)
        XCTAssertThrowsError(try PDFTools.info(notPDF)) { XCTAssertEqual(($0 as? IPCError)?.code, "unreadable") }
        XCTAssertThrowsError(try PDFTools.info(dir.appendingPathComponent("missing.pdf"))) { XCTAssertEqual(($0 as? IPCError)?.code, "not_found") }
        do {
            _ = try await PDFTools.extract(src, pages: try PageRanges.parse("9"), mode: .combined)
            XCTFail("expected invalid_params")
        } catch let error as IPCError {
            XCTAssertEqual(error.code, "invalid_params")
        }
    }

    func testRemoveBackgroundFailsClearlyWithoutSubject() async throws {
        let flat = makePNG("Flat.png", width: 300, height: 200)
        do {
            _ = try await BackgroundRemoval.run(flat, crop: false)
            XCTFail("expected no_subject")
        } catch let error as IPCError {
            // Vision may be unavailable in some test environments; it must still fail with a clear code.
            XCTAssertTrue(["no_subject", "failed"].contains(error.code), error.code)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Flat (no background).png").path))
    }
}
