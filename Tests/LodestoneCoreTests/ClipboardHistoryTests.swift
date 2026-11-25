import Foundation
@testable import LodestoneCore
import XCTest

final class ClipboardHistoryTests: XCTestCase {
    private func item(_ text: String, bytes: Int = 10, pinned: Bool = false, app: String? = nil, age: TimeInterval = 0) -> ClipboardItem {
        ClipboardItem(kind: .text, text: text, byteSize: bytes, contentHash: "t:" + text, sourceApp: app,
                      date: Date(timeIntervalSince1970: 1_000_000 - age), pinned: pinned)
    }

    func testNewestFirst() {
        var h = ClipboardHistory()
        h.insert(item("a"), limits: .init())
        h.insert(item("b"), limits: .init())
        XCTAssertEqual(h.items.map(\.text), ["b", "a"])
    }

    func testDuplicateMovesToTopAndKeepsPin() {
        var h = ClipboardHistory()
        let first = item("a", pinned: true)
        h.insert(first, limits: .init())
        h.insert(item("b"), limits: .init())
        let again = item("a")
        let removed = h.insert(again, limits: .init())
        XCTAssertEqual(h.items.map(\.text), ["a", "b"])
        XCTAssertEqual(h.items[0].id, again.id, "the newest copy replaces the old one")
        XCTAssertTrue(h.items[0].pinned, "re-copying a pinned item keeps it pinned")
        XCTAssertEqual(removed.map(\.id), [first.id], "the old copy is returned so its blobs get deleted")
    }

    func testItemCountCapEvictsOldestUnpinned() {
        var h = ClipboardHistory()
        let limits = ClipboardLimits(maxItems: 3, maxBytes: .max)
        h.insert(item("pinned", pinned: true), limits: limits)
        var evicted: [ClipboardItem] = []
        for t in ["1", "2", "3", "4", "5"] { evicted += h.insert(item(t), limits: limits) }
        XCTAssertEqual(h.items.map(\.text), ["5", "4", "3", "pinned"])
        XCTAssertEqual(evicted.map(\.text), ["1", "2"])
    }

    func testByteCapIgnoresPinnedAndKeepsNewest() {
        var h = ClipboardHistory()
        let limits = ClipboardLimits(maxItems: 100, maxBytes: 100)
        h.insert(item("big pinned", bytes: 500, pinned: true), limits: limits)
        h.insert(item("a", bytes: 40), limits: limits)
        h.insert(item("b", bytes: 40), limits: limits)
        h.insert(item("c", bytes: 40), limits: limits)
        XCTAssertEqual(h.items.map(\.text), ["c", "b", "big pinned"], "pinned bytes don't count")
        h.insert(item("huge", bytes: 1000), limits: limits)
        XCTAssertEqual(h.items.map(\.text), ["huge", "big pinned"], "the newest item is kept even when it's over the cap")
    }

    func testUnpinThenEnforce() {
        var h = ClipboardHistory()
        let limits = ClipboardLimits(maxItems: 1, maxBytes: .max)
        let pinned = item("p", pinned: true)
        h.insert(pinned, limits: limits)
        h.insert(item("x"), limits: limits)
        XCTAssertEqual(h.items.count, 2)
        h.setPinned(pinned.id, false)
        let removed = h.enforce(limits)
        XCTAssertEqual(removed.map(\.text), ["p"])
    }

    func testTouchMovesToTop() {
        var h = ClipboardHistory()
        let a = item("a")
        h.insert(a, limits: .init())
        h.insert(item("b"), limits: .init())
        XCTAssertTrue(h.touch(a.id, date: Date(timeIntervalSince1970: 5)))
        XCTAssertEqual(h.items.map(\.text), ["a", "b"])
        XCTAssertEqual(h.items[0].date, Date(timeIntervalSince1970: 5))
        XCTAssertFalse(h.touch("missing"))
    }

    func testClearKeepsPinnedUnlessAsked() {
        var h = ClipboardHistory()
        h.insert(item("p", pinned: true), limits: .init())
        h.insert(item("a"), limits: .init())
        var copy = h
        XCTAssertEqual(h.clear(keepPinned: true).map(\.text), ["a"])
        XCTAssertEqual(h.items.map(\.text), ["p"])
        XCTAssertEqual(copy.clear(keepPinned: false).count, 2)
        XCTAssertTrue(copy.items.isEmpty)
    }

    func testSearch() {
        var h = ClipboardHistory()
        h.insert(item("Hello World", app: "Safari"), limits: .init())
        h.insert(item("café menu"), limits: .init())
        h.insert(item("/Users/me/Report.pdf"), limits: .init())
        XCTAssertEqual(h.search("").count, 3)
        XCTAssertEqual(h.search("hello").map(\.text), ["Hello World"])
        XCTAssertEqual(h.search("WORLD hello").map(\.text), ["Hello World"], "every word must match, in any order")
        XCTAssertEqual(h.search("cafe").map(\.text), ["café menu"], "diacritics are ignored")
        XCTAssertEqual(h.search("report").map(\.text), ["/Users/me/Report.pdf"])
        XCTAssertEqual(h.search("safari").map(\.text), ["Hello World"], "the source app matches")
        XCTAssertTrue(h.search("hello menu").isEmpty)
    }

    func testResolve() {
        var h = ClipboardHistory()
        let a = ClipboardItem(id: "abc123", kind: .text, text: "a", byteSize: 1, contentHash: "a")
        let b = ClipboardItem(id: "abd456", kind: .text, text: "b", byteSize: 1, contentHash: "b")
        h.insert(a, limits: .init())
        h.insert(b, limits: .init())
        XCTAssertEqual(h.resolve("1")?.id, "abd456")
        XCTAssertEqual(h.resolve("2")?.id, "abc123")
        XCTAssertNil(h.resolve("3"))
        XCTAssertEqual(h.resolve("abc123")?.id, "abc123")
        XCTAssertEqual(h.resolve("ABD")?.id, "abd456", "unique prefixes work, case-insensitively")
        XCTAssertNil(h.resolve("ab"), "ambiguous prefix")
    }

    func testCodableRoundTrip() throws {
        var h = ClipboardHistory()
        h.insert(ClipboardItem(kind: .image, text: "", blobs: ["png"], imageWidth: 10, imageHeight: 20, byteSize: 99,
                               contentHash: "i:x", sourceApp: "Preview", sourceBundleID: "com.apple.Preview", pinned: true), limits: .init())
        let data = try JSONEncoder().encode(h)
        XCTAssertEqual(try JSONDecoder().decode(ClipboardHistory.self, from: data), h)
    }

    func testTitles() {
        XCTAssertEqual(ClipboardItem(kind: .text, text: "\n  \n  first line  \nsecond", byteSize: 1, contentHash: "").title, "first line")
        XCTAssertEqual(ClipboardItem(kind: .image, text: "", imageWidth: 1200, imageHeight: 800, byteSize: 1, contentHash: "").title, "Image 1200×800")
        XCTAssertEqual(ClipboardItem(kind: .files, text: "", filePaths: ["/a/x.txt", "/b/y.pdf"], byteSize: 1, contentHash: "").title, "x.txt, y.pdf")
        XCTAssertEqual(ClipboardItem(kind: .files, text: "", filePaths: ["/1", "/2", "/3", "/4"], byteSize: 1, contentHash: "").title, "1, 2 and 2 more")
    }

    func testIDsAreShortHex() {
        let id = ClipboardItem.newID()
        XCTAssertEqual(id.count, 12)
        XCTAssertTrue(id.allSatisfy(\.isHexDigit))
        XCTAssertNotEqual(id, ClipboardItem.newID())
    }
}

final class ClipboardRulesTests: XCTestCase {
    private let ignored = ClipboardRules.defaultIgnoredApps

    func testMarkerTypesAreSkipped() {
        XCTAssertEqual(ClipboardRules.skipReason(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], frontmostBundleID: nil, ignoredApps: []), .concealed)
        XCTAssertEqual(ClipboardRules.skipReason(types: ["org.nspasteboard.TransientType"], frontmostBundleID: nil, ignoredApps: []), .transient)
        XCTAssertEqual(ClipboardRules.skipReason(types: ["org.nspasteboard.AutoGeneratedType"], frontmostBundleID: nil, ignoredApps: []), .autoGenerated)
        XCTAssertNil(ClipboardRules.skipReason(types: ["public.utf8-plain-text"], frontmostBundleID: "com.apple.Safari", ignoredApps: ignored))
    }

    func testIgnoredApps() {
        XCTAssertEqual(ClipboardRules.skipReason(types: ["public.utf8-plain-text"], frontmostBundleID: "com.1password.1password", ignoredApps: ignored), .ignoredApp)
        XCTAssertEqual(ClipboardRules.skipReason(types: ["public.utf8-plain-text"], frontmostBundleID: "com.apple.passwords", ignoredApps: ignored), .ignoredApp,
                       "bundle ids compare case-insensitively")
        XCTAssertNil(ClipboardRules.skipReason(types: ["public.utf8-plain-text"], frontmostBundleID: nil, ignoredApps: ignored))
    }

    func testDefaultsCoverPasswordManagers() {
        for id in ["com.1password.1password", "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords"] {
            XCTAssertTrue(ignored.contains(id), id)
        }
    }

    func testAppListParsing() {
        XCTAssertEqual(ClipboardRules.parseAppList(" com.a , com.b\ncom.c,,com.A "), ["com.a", "com.b", "com.c"])
        XCTAssertEqual(ClipboardRules.parseAppList(""), [])
        XCTAssertEqual(ClipboardRules.parseAppList(ClipboardRules.formatAppList(ignored)), ignored)
    }

    func testRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-5), to: now), "now")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-300), to: now), "5m")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-7200), to: now), "2h")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-86400 * 3), to: now), "3d")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-86400 * 21), to: now), "3w")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(60), to: now), "now")
        XCTAssertEqual(RelativeTime.bytes(500), "500 B")
        XCTAssertEqual(RelativeTime.bytes(2048), "2 KB")
        XCTAssertEqual(RelativeTime.bytes(3 * 1_048_576 + 400_000), "3.4 MB")
    }
}
