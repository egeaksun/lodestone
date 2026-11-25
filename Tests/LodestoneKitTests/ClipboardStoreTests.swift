import AppKit
import LodestoneCore
@testable import LodestoneKit
import XCTest

final class ClipboardStoreTests: XCTestCase {
    private var dir: URL!
    private var stores: [ClipboardStore] = []

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lodestone-clipboard-\(UUID().uuidString)")
    }

    override func tearDown() {
        stores.forEach { $0.flush() } // queued writes would recreate the directory
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore(persistent: Bool, limits: ClipboardLimits = ClipboardLimits()) -> ClipboardStore {
        let store = ClipboardStore(directory: dir, persistent: persistent, limits: limits)
        stores.append(store)
        return store
    }

    private func text(_ s: String) -> (ClipboardItem, [String: Data]) {
        try! ClipboardCapture(types: ["public.utf8-plain-text"], string: s).prepare(sourceApp: "Notes", sourceBundleID: "com.apple.Notes").get()
    }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testPersistenceRoundTripWithPrivatePermissions() throws {
        let store = makeStore(persistent: true)
        let rich = try ClipboardCapture(types: ["public.rtf"], string: "Bold", rtf: Data("{\\rtf1 \\b Bold}".utf8))
            .prepare(sourceApp: "TextEdit", sourceBundleID: "com.apple.TextEdit").get()
        store.add(rich.0, blobs: rich.1)
        let plain = text("hello")
        store.add(plain.0, blobs: plain.1)
        store.setPinned(rich.0.id, true)
        store.flush()

        XCTAssertEqual(mode(dir.path), 0o700)
        XCTAssertEqual(mode(dir.appendingPathComponent("index.json").path), 0o600)
        XCTAssertEqual(mode(dir.appendingPathComponent("\(rich.0.id).rtf").path), 0o600)

        let reloaded = makeStore(persistent: true)
        XCTAssertEqual(reloaded.items.map(\.text), ["hello", "Bold"])
        XCTAssertEqual(reloaded.items.map(\.pinned), [false, true])
        XCTAssertEqual(reloaded.items[1].kind, .richText)
        XCTAssertEqual(reloaded.items[1].sourceBundleID, "com.apple.TextEdit")
        XCTAssertEqual(reloaded.data(rich.0.id, "rtf"), rich.1["rtf"])
        XCTAssertEqual(reloaded.items[0].date.timeIntervalSince1970, plain.0.date.timeIntervalSince1970, accuracy: 0.001)
    }

    func testEvictionAndDeleteRemoveBlobs() throws {
        let store = makeStore(persistent: true, limits: ClipboardLimits(maxItems: 1, maxBytes: .max))
        let long = text(String(repeating: "x", count: ClipboardLimits.indexTextLimit + 10))
        XCTAssertTrue(long.0.textTruncated)
        store.add(long.0, blobs: long.1)
        store.flush()
        XCTAssertEqual(files(), ["\(long.0.id).txt", "index.json"])
        XCTAssertEqual(store.fullText(long.0).count, ClipboardLimits.indexTextLimit + 10)

        let next = text("next")
        let removed = store.add(next.0, blobs: next.1)
        store.flush()
        XCTAssertEqual(removed.map(\.id), [long.0.id])
        XCTAssertEqual(files(), ["index.json"], "the evicted item's blob is deleted")

        XCTAssertNotNil(store.delete(next.0.id))
        XCTAssertNil(store.delete(next.0.id))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testDedupeReplacesOldCopy() {
        let store = makeStore(persistent: true)
        let a = text("same")
        store.add(a.0, blobs: a.1)
        store.add(text("other").0, blobs: [:])
        let again = text("same")
        store.add(again.0, blobs: again.1)
        XCTAssertEqual(store.items.map(\.text), ["same", "other"])
        XCTAssertEqual(store.items.first?.id, again.0.id)
    }

    func testInMemoryModeWritesNothingAndWipesOldHistory() throws {
        let persisted = makeStore(persistent: true)
        let a = text("old")
        persisted.add(a.0, blobs: a.1)
        persisted.flush()
        XCTAssertFalse(files().isEmpty)

        let memory = makeStore(persistent: false)
        let long = text(String(repeating: "y", count: ClipboardLimits.indexTextLimit + 1))
        memory.add(long.0, blobs: long.1)
        memory.flush()
        XCTAssertTrue(memory.items.count == 1)
        XCTAssertEqual(files(), [], "nothing is on disk")
        XCTAssertEqual(memory.fullText(long.0).count, ClipboardLimits.indexTextLimit + 1, "blobs are kept in memory")

        memory.setPersistent(true)
        memory.flush()
        XCTAssertEqual(files(), ["\(long.0.id).txt", "index.json"])
        memory.setPersistent(false)
        memory.flush()
        XCTAssertEqual(files(), [])
        XCTAssertEqual(memory.fullText(long.0).count, ClipboardLimits.indexTextLimit + 1, "switching off keeps the history in memory")
    }

    func testLoadDropsItemsWithMissingBlobsAndOrphanFiles() throws {
        let store = makeStore(persistent: true)
        let long = text(String(repeating: "z", count: ClipboardLimits.indexTextLimit + 1))
        store.add(long.0, blobs: long.1)
        let short = text("short")
        store.add(short.0, blobs: short.1)
        store.flush()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(long.0.id).txt"))
        try Data("junk".utf8).write(to: dir.appendingPathComponent("deadbeef0000.png"))

        let reloaded = makeStore(persistent: true)
        XCTAssertEqual(reloaded.items.map(\.id), [short.0.id])
        XCTAssertEqual(files(), ["index.json"])
    }

    func testLimitsChangeEvicts() {
        let store = makeStore(persistent: false)
        for s in ["a", "b", "c"] { let t = text(s); store.add(t.0, blobs: t.1) }
        let removed = store.setLimits(ClipboardLimits(maxItems: 1, maxBytes: .max))
        XCTAssertEqual(removed.map(\.text), ["b", "a"])
        XCTAssertEqual(store.items.map(\.text), ["c"])
    }

    func testClear() {
        let store = makeStore(persistent: false)
        for s in ["a", "b", "c"] { let t = text(s); store.add(t.0, blobs: t.1) }
        store.setPinned(store.items[2].id, true)
        XCTAssertEqual(store.clear(keepPinned: true), 2)
        XCTAssertEqual(store.items.map(\.text), ["a"])
        XCTAssertEqual(store.clear(keepPinned: false), 1)
    }
}

final class ClipboardCaptureTests: XCTestCase {
    func testTextHashesIgnoreFormatting() throws {
        let plain = try ClipboardCapture(types: [], string: "hi").prepare(sourceApp: nil, sourceBundleID: nil).get().0
        let rich = try ClipboardCapture(types: [], string: "hi", html: Data("<b>hi</b>".utf8)).prepare(sourceApp: nil, sourceBundleID: nil).get()
        XCTAssertEqual(plain.kind, .text)
        XCTAssertEqual(rich.0.kind, .richText)
        XCTAssertEqual(rich.1.keys.sorted(), ["html"])
        XCTAssertEqual(plain.contentHash, rich.0.contentHash)
    }

    func testRichTextWithoutPlainString() throws {
        let rtf = Data("{\\rtf1\\ansi {\\b Hello} there}".utf8)
        let (item, blobs) = try ClipboardCapture(types: [], rtf: rtf).prepare(sourceApp: nil, sourceBundleID: nil).get()
        XCTAssertEqual(item.text, "Hello there")
        XCTAssertEqual(blobs["rtf"], rtf)
        let html = try ClipboardCapture(types: [], html: Data("<p>A &amp; <b>B</b></p>".utf8)).prepare(sourceApp: nil, sourceBundleID: nil).get().0
        XCTAssertEqual(html.text, "A & B")
    }

    func testImagesAreStoredAsPNG() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 30, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let tiff = rep.tiffRepresentation!
        let (item, blobs) = try ClipboardCapture(types: ["public.tiff"], image: tiff).prepare(sourceApp: nil, sourceBundleID: nil).get()
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.imageWidth, 30)
        XCTAssertEqual(item.imageHeight, 20)
        XCTAssertEqual(item.title, "Image 30×20")
        XCTAssertEqual(Array(blobs["png"]!.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertTrue(item.contentHash.hasPrefix("i:"))
    }

    func testFilesAndRejections() throws {
        let (item, blobs) = try ClipboardCapture(types: [], fileURLs: [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.png")])
            .prepare(sourceApp: nil, sourceBundleID: nil).get()
        XCTAssertEqual(item.kind, .files)
        XCTAssertEqual(item.filePaths, ["/tmp/a.txt", "/tmp/b.png"])
        XCTAssertEqual(item.text, "/tmp/a.txt\n/tmp/b.png")
        XCTAssertTrue(blobs.isEmpty)

        XCTAssertThrowsError(try ClipboardCapture(types: []).prepare(sourceApp: nil, sourceBundleID: nil).get()) {
            XCTAssertEqual($0 as? ClipboardCapture.Rejection, .empty)
        }
        let huge = String(repeating: "x", count: ClipboardLimits.maxCaptureBytes + 1)
        XCTAssertThrowsError(try ClipboardCapture(types: [], string: huge).prepare(sourceApp: nil, sourceBundleID: nil).get()) {
            XCTAssertEqual($0 as? ClipboardCapture.Rejection, .tooLarge)
        }
    }
}

/// Uses a private named pasteboard, never the user's clipboard.
final class PasteboardIOTests: XCTestCase {
    private var pb: NSPasteboard!
    private var dir: URL!

    override func setUp() {
        pb = NSPasteboard(name: NSPasteboard.Name("app.lodestone.tests.\(UUID().uuidString)"))
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lodestone-pb-\(UUID().uuidString)")
    }

    override func tearDown() {
        pb.releaseGlobally()
        try? FileManager.default.removeItem(at: dir)
    }

    func testCaptureAndWriteBackRichText() throws {
        pb.clearContents()
        pb.declareTypes([.rtf, .string], owner: nil)
        let rtf = Data("{\\rtf1\\ansi {\\b Bold} text}".utf8)
        pb.setData(rtf, forType: .rtf)
        pb.setString("Bold text", forType: .string)

        let capture = try XCTUnwrap(PasteboardIO.capture(pb))
        let (item, blobs) = try capture.prepare(sourceApp: nil, sourceBundleID: nil).get()
        XCTAssertEqual(item.kind, .richText)
        let store = ClipboardStore(directory: dir, persistent: false)
        store.add(item, blobs: blobs)

        pb.clearContents()
        _ = try PasteboardIO.write(item, from: store, to: pb)
        XCTAssertEqual(pb.data(forType: .rtf), rtf)
        XCTAssertEqual(pb.string(forType: .string), "Bold text")

        _ = try PasteboardIO.write(item, from: store, to: pb, plain: true)
        XCTAssertNil(pb.data(forType: .rtf), "plain paste writes text only")
        XCTAssertEqual(pb.string(forType: .string), "Bold text")
    }

    func testPlainTextFallbacks() {
        pb.clearContents()
        pb.setData(Data("{\\rtf1\\ansi only rtf}".utf8), forType: .rtf)
        XCTAssertEqual(PasteboardIO.plainText(pb), "only rtf")
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/x.txt") as NSURL])
        XCTAssertEqual(PasteboardIO.plainText(pb), "/tmp/x.txt")
        pb.clearContents()
        XCTAssertNil(PasteboardIO.plainText(pb))
    }

    func testTransientMarkerAndSnapshotRestore() {
        pb.clearContents()
        pb.declareTypes([.html, .string], owner: nil)
        pb.setData(Data("<i>x</i>".utf8), forType: .html)
        pb.setString("x", forType: .string)
        let snapshot = PasteboardSnapshot(pb)

        PasteboardIO.setText("x", pb, transient: true)
        XCTAssertEqual(ClipboardRules.skipReason(types: PasteboardIO.types(pb), frontmostBundleID: nil, ignoredApps: []), .transient)
        XCTAssertNil(pb.data(forType: .html))

        snapshot.restore(pb)
        XCTAssertEqual(pb.data(forType: .html), Data("<i>x</i>".utf8))
        XCTAssertEqual(pb.string(forType: .string), "x")
        XCTAssertNil(ClipboardRules.skipReason(types: PasteboardIO.types(pb), frontmostBundleID: nil, ignoredApps: []))
    }

    func testImageCannotBePastedAsPlainText() throws {
        let store = ClipboardStore(directory: dir, persistent: false)
        let item = ClipboardItem(kind: .image, text: "", blobs: ["png"], byteSize: 1, contentHash: "i:1")
        XCTAssertThrowsError(try PasteboardIO.write(item, from: store, to: pb, plain: true)) {
            XCTAssertEqual(($0 as? IPCError)?.code, "no_text")
        }
    }
}
