import CoreGraphics
import Foundation
@testable import LodestoneCore
import XCTest

final class PageRangesTests: XCTestCase {
    func testParsesItems() throws {
        let r = try PageRanges.parse("1-3, 5,8-")
        XCTAssertEqual(try r.groups(pageCount: 10), [[1, 2, 3], [5], [8, 9, 10]])
        XCTAssertEqual(try r.pages(pageCount: 10), [1, 2, 3, 5, 8, 9, 10])
    }

    func testOpenStartLastAndReverse() throws {
        XCTAssertEqual(try PageRanges.parse("-3").pages(pageCount: 5), [1, 2, 3])
        XCTAssertEqual(try PageRanges.parse("last").pages(pageCount: 5), [5])
        XCTAssertEqual(try PageRanges.parse("4-last").pages(pageCount: 5), [4, 5])
        XCTAssertEqual(try PageRanges.parse("5-3").pages(pageCount: 5), [5, 4, 3])
        XCTAssertEqual(try PageRanges.parse("2,2").pages(pageCount: 5), [2, 2])
        XCTAssertEqual(try PageRanges.all.pages(pageCount: 3), [1, 2, 3])
    }

    func testRejectsBadInput() {
        for bad in ["", " ", "0", "a", "1-b", "-", "1,,2", "1-2-3", "-0"] {
            XCTAssertThrowsError(try PageRanges.parse(bad), bad)
        }
    }

    func testOutOfRange() throws {
        let r = try PageRanges.parse("2-7")
        XCTAssertThrowsError(try r.groups(pageCount: 5)) { error in
            XCTAssertEqual((error as? IPCError)?.code, "invalid_params")
            XCTAssertTrue((error as? IPCError)?.message.contains("5 pages") == true)
        }
        XCTAssertThrowsError(try PageRanges.all.groups(pageCount: 0))
    }

    func testLabel() {
        XCTAssertEqual(PageRanges.label([3]), "3")
        XCTAssertEqual(PageRanges.label([1, 2, 3]), "1-3")
        XCTAssertEqual(PageRanges.label([5, 4, 3]), "5-3")
        XCTAssertEqual(PageRanges.label([1, 3]), "1,3")
        XCTAssertEqual(PageRanges.label([]), "")
    }
}

final class SiblingFileTests: XCTestCase {
    func testNames() {
        XCTAssertEqual(SiblingFile.name(base: "Report", tag: "compressed", ext: "pdf"), "Report (compressed).pdf")
        XCTAssertEqual(SiblingFile.name(base: "Report", tag: "compressed", ext: "pdf", attempt: 2), "Report (compressed 2).pdf")
        XCTAssertEqual(SiblingFile.name(base: "Report", tag: nil, ext: "pdf", attempt: 3), "Report 3.pdf")
        XCTAssertEqual(SiblingFile.name(base: "Report", tag: "pages", ext: ""), "Report (pages)")
    }

    func testUniqueSkipsTakenNames() {
        let dir = URL(fileURLWithPath: "/x")
        let taken: Set<String> = ["/x/Cat (no background).png", "/x/Cat (no background 2).png"]
        let url = SiblingFile.unique(in: dir, base: "Cat", tag: "no background", ext: "png") { taken.contains($0.path) }
        XCTAssertEqual(url.path, "/x/Cat (no background 3).png")
    }

    func testBase() {
        XCTAssertEqual(SiblingFile.base(of: URL(fileURLWithPath: "/a/My.File.v2.pdf")), "My.File.v2")
    }
}

final class GhostscriptArgumentsTests: XCTestCase {
    func testCompressArguments() {
        let args = GhostscriptArguments.compress(input: "/in.pdf", output: "/out.pdf", level: .balanced)
        XCTAssertEqual(args.first, "-sDEVICE=pdfwrite")
        XCTAssertEqual(args.last, "/in.pdf")
        XCTAssertTrue(args.contains("-sOutputFile=/out.pdf"))
        XCTAssertTrue(args.contains("-dPDFSETTINGS=/ebook"))
        XCTAssertTrue(args.contains("-dColorImageResolution=150"))
        XCTAssertTrue(args.contains("-dGrayImageResolution=150"))
        XCTAssertTrue(args.contains("-dMonoImageResolution=300"))
        XCTAssertTrue(args.contains("-dSAFER"))
        XCTAssertTrue(args.contains("-dAutoRotatePages=/None"))
        XCTAssertFalse(args.contains("-dQUIET"), "page progress is read from the output")
    }

    func testLevelsDiffer() {
        let light = GhostscriptArguments.compress(input: "i", output: "o", level: .light)
        let strong = GhostscriptArguments.compress(input: "i", output: "o", level: .strong)
        XCTAssertTrue(light.contains("-dPDFSETTINGS=/printer"))
        XCTAssertTrue(light.contains("-dColorImageResolution=225"))
        XCTAssertTrue(strong.contains("-dPDFSETTINGS=/screen"))
        XCTAssertTrue(strong.contains("-dColorImageResolution=96"))
        XCTAssertTrue(strong.contains("-dColorImageDownsampleThreshold=1.0"))
    }

    func testProgressLines() {
        XCTAssertEqual(GhostscriptArguments.page(fromOutputLine: "Page 12"), 12)
        XCTAssertEqual(GhostscriptArguments.page(fromOutputLine: "  Page 3 "), 3)
        XCTAssertNil(GhostscriptArguments.page(fromOutputLine: "Processing pages 1 through 3."))
        XCTAssertNil(GhostscriptArguments.page(fromOutputLine: "GPL Ghostscript 10.08.0"))
    }
}

final class PageLayoutTests: XCTestCase {
    func testFitAddsMargin() {
        let r = PageLayout.place(image: CGSize(width: 400, height: 300), on: .fit, margin: 10)
        XCTAssertEqual(r.page, CGSize(width: 420, height: 320))
        XCTAssertEqual(r.imageRect, CGRect(x: 10, y: 10, width: 400, height: 300))
    }

    func testFixedSizeScalesDownAndCenters() {
        let r = PageLayout.place(image: CGSize(width: 1000, height: 2000), on: .letter, margin: 36)
        XCTAssertEqual(r.page, CGSize(width: 612, height: 792))
        // Height-limited: 720 / 2000.
        XCTAssertEqual(r.imageRect.height, 720, accuracy: 0.01)
        XCTAssertEqual(r.imageRect.width, 360, accuracy: 0.01)
        XCTAssertEqual(r.imageRect.midX, 306, accuracy: 0.01)
        XCTAssertEqual(r.imageRect.midY, 396, accuracy: 0.01)
    }

    func testLandscapeImageTurnsPage() {
        let r = PageLayout.place(image: CGSize(width: 300, height: 200), on: .a4, margin: 0)
        XCTAssertEqual(r.page.width, 841.89, accuracy: 0.01)
        XCTAssertEqual(r.page.height, 595.28, accuracy: 0.01)
        // Small images keep their size.
        XCTAssertEqual(r.imageRect.size, CGSize(width: 300, height: 200))
    }

    func testHugeMarginIsClamped() {
        let r = PageLayout.place(image: CGSize(width: 100, height: 100), on: .letter, margin: 1000)
        XCTAssertGreaterThan(r.imageRect.width, 0)
    }
}
