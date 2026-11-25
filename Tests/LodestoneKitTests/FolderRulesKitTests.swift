import XCTest
import LodestoneCore
@testable import LodestoneKit

final class FolderRulesKitTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        // Resolved: FSEvents reports real paths (/private/var/...), not /var/...
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lodestone-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dir = URL(fileURLWithPath: FolderWatcher.realPath(dir.path))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testStoreRoundTrip() throws {
        let store = RuleStore(url: dir.appendingPathComponent("rules.json"))
        XCTAssertEqual(store.load(), [], "missing file: no rules")
        let rules = [FolderRule(folder: "/in", pattern: "Screen*", kinds: [.video], format: .mp4, preset: "balanced", originals: .trash),
                     FolderRule(enabled: false, folder: "/other", kinds: [.image, .audio])]
        try store.save(rules)
        XCTAssertEqual(store.load(), rules)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        try Data("not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), [], "unreadable: no rules, file left alone")
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), "not json")
    }

    func testWatcherReportsNewFiles() throws {
        let seen = expectation(description: "event for the new file")
        seen.assertForOverFulfill = false
        let target = dir.appendingPathComponent("Screen Recording.mov").path
        let watcher = FolderWatcher(folders: [dir.path], latency: 0.1) { paths in
            if paths.contains(target) { seen.fulfill() }
        }
        XCTAssertTrue(watcher.isRunning)
        // Give the stream a moment to start before the file appears.
        Thread.sleep(forTimeInterval: 0.3)
        try Data(repeating: 1, count: 1024).write(to: URL(fileURLWithPath: target))
        wait(for: [seen], timeout: 5)
        watcher.stop()
        watcher.stop()
        XCTAssertFalse(watcher.isRunning)
    }

    func testWatcherIgnoresDirectories() throws {
        let unexpected = expectation(description: "no file events for a new folder")
        unexpected.isInverted = true
        let watcher = FolderWatcher(folders: [dir.path], latency: 0.1) { _ in unexpected.fulfill() }
        Thread.sleep(forTimeInterval: 0.3)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: false)
        wait(for: [unexpected], timeout: 1)
        watcher.stop()
    }
}

final class RealPathTests: XCTestCase {
    func testRealPath() {
        XCTAssertEqual(FolderWatcher.realPath("/tmp"), "/private/tmp")
        XCTAssertEqual(FolderWatcher.realPath("/tmp/../tmp/./"), "/private/tmp")
        XCTAssertEqual(FolderWatcher.realPath("/no/such/dir/x.mov"), "/no/such/dir/x.mov")
        XCTAssertEqual(FolderWatcher.realPath("~/"), FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
    }
}
