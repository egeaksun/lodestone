import XCTest
@testable import LodestoneCore

final class FolderRulesTests: XCTestCase {
    private let recordings = FolderRule(id: "r1", folder: "/Users/me/Desktop", pattern: "Screen Recording*", kinds: [.video], format: .mp4)

    func testLocation() {
        let r = recordings
        XCTAssertEqual(RuleMatching.location("/Users/me/Desktop/Screen Recording 2026-11-25 at 10.00.mov", rule: r), .convert)
        XCTAssertEqual(RuleMatching.location("/Users/me/Desktop/screen recording.mov", rule: r), .convert, "case-insensitive")
        XCTAssertEqual(RuleMatching.location("/Users/me/Desktop/Holiday.mov", rule: r), .patternMismatch)
        XCTAssertEqual(RuleMatching.location("/Users/me/Documents/Screen Recording.mov", rule: r), .outsideFolder)
        XCTAssertEqual(RuleMatching.location("/Users/me/DesktopOther/Screen Recording.mov", rule: r), .outsideFolder, "prefix of another folder")
        XCTAssertEqual(RuleMatching.location("/Users/me/Desktop/.Screen Recording.mov", rule: r), .hidden)
        XCTAssertEqual(RuleMatching.location("/Users/me/Desktop/sub/Screen Recording.mov", rule: r), .inSubfolder)
        XCTAssertEqual(RuleMatching.location("/Users/me/Desktop/.hidden/Screen Recording.mov", rule: r), .hidden)
        XCTAssertEqual(RuleMatching.location("/Users/me/Desktop/Screen Recording.mov.crdownload", rule: r), .partial)

        var deep = r
        deep.includeSubfolders = true
        deep.folder = "/Users/me/Desktop/"
        XCTAssertEqual(RuleMatching.location("/Users/me/Desktop/sub/Screen Recording.mov", rule: deep), .convert)
    }

    func testDecide() {
        let r = recordings
        XCTAssertEqual(RuleMatching.decide("/Users/me/Desktop/Screen Recording.mov", kind: .video, rule: r), .convert)
        XCTAssertEqual(RuleMatching.decide("/Users/me/Desktop/Screen Recording.mov", kind: nil, rule: r), .wrongKind)
        XCTAssertEqual(RuleMatching.decide("/Users/me/Desktop/Screen Recording.png", kind: .image, rule: r), .wrongKind)
        // The rule's own output must not be converted again.
        XCTAssertEqual(RuleMatching.decide("/Users/me/Desktop/Screen Recording.mp4", kind: .video, rule: r), .alreadyTargetFormat)
        XCTAssertEqual(RuleMatching.decide("/Users/me/Desktop/Screen Recording.M4V", kind: .video, rule: r), .alreadyTargetFormat)

        let images = FolderRule(folder: "/in", kinds: [.image], preset: "compress")
        XCTAssertEqual(RuleMatching.decide("/in/a.png", kind: .image, rule: images), .convert, "no format: nothing is already the target")
    }

    func testGlob() {
        XCTAssertTrue(RuleMatching.glob("*", matches: "anything.mov"))
        XCTAssertTrue(RuleMatching.glob("*.MOV", matches: "clip.mov"))
        XCTAssertTrue(RuleMatching.glob("IMG_????.heic", matches: "IMG_1234.HEIC"))
        XCTAssertFalse(RuleMatching.glob("IMG_????.heic", matches: "IMG_12345.heic"))
        XCTAssertTrue(RuleMatching.glob("a*b*c", matches: "aXXbYYc"))
        XCTAssertFalse(RuleMatching.glob("a*b*c", matches: "aXXbYY"))
        XCTAssertTrue(RuleMatching.glob("", matches: ""))
        XCTAssertFalse(RuleMatching.glob("", matches: "x"))
    }

    func testProblems() {
        let kinds: (String) -> MediaKind? = { ["balanced": .video, "compress": .image, "audio-small": .audio][$0] }
        XCTAssertEqual(RuleMatching.problems(recordings, presetKind: kinds), [])

        var bad = recordings
        bad.kinds = []
        XCTAssertEqual(RuleMatching.problems(bad, presetKind: kinds).count, 1)

        bad = FolderRule(folder: "/in", kinds: [.image, .video], format: .mp4)
        XCTAssertEqual(RuleMatching.problems(bad, presetKind: kinds), ["Images can't be converted to MP4."])

        bad = FolderRule(folder: "relative", kinds: [.video], format: .mp4, preset: "compress")
        let problems = RuleMatching.problems(bad, presetKind: kinds)
        XCTAssertEqual(problems.count, 2)
        XCTAssertTrue(problems[1].contains("'compress' is for images"))

        // Video to MP3 uses an audio preset.
        let extract = FolderRule(folder: "/in", kinds: [.video], format: .mp3, preset: "audio-small")
        XCTAssertEqual(RuleMatching.problems(extract, presetKind: kinds), [])
        XCTAssertEqual(RuleMatching.problems(FolderRule(folder: "/in", kinds: [.video], preset: "nope"), presetKind: kinds),
                       ["No preset 'nope'. See `lodestone presets list`."])
    }

    func testNamesAndDecoding() throws {
        XCTAssertEqual(recordings.name, "Desktop: Screen Recording* → MP4")
        XCTAssertEqual(FolderRule(folder: "/x/In", kinds: [.image], preset: "compress").name, "In: Images → same format")

        // An older file without the optional fields still loads, with defaults.
        let json = #"{"id": "abc", "folder": "/in", "kinds": ["audio"], "format": "flac"}"#
        let rule = try JSONDecoder().decode(FolderRule.self, from: Data(json.utf8))
        XCTAssertTrue(rule.enabled)
        XCTAssertEqual(rule.originals, .keep)
        XCTAssertEqual(rule.name, "in: Audio → FLAC")

        let round = try JSONDecoder().decode(FolderRule.self, from: JSONEncoder().encode(recordings))
        XCTAssertEqual(round, recordings)
    }

    func testSettle() {
        var s = SettleTracker()
        s.add("/a")
        XCTAssertFalse(s.check("/a", size: 100), "first sighting only records the size")
        XCTAssertFalse(s.check("/a", size: 200), "still growing")
        XCTAssertTrue(s.check("/a", size: 200), "unchanged: ready")
        XCTAssertTrue(s.isEmpty)

        s.add("/b")
        XCTAssertFalse(s.check("/b", size: 0))
        XCTAssertFalse(s.check("/b", size: 0), "empty files never count as finished")
        s.add("/b")
        XCTAssertFalse(s.check("/b", size: 10), "a new event restarts the wait")
        XCTAssertFalse(s.check("/b", size: nil), "gone")
        XCTAssertTrue(s.isEmpty)
        XCTAssertFalse(s.check("/never-added", size: 5))
    }
}

final class FolderRuleOutputTests: XCTestCase {
    func testPlainOutput() {
        let r = FolderRule(folder: "/in", kinds: [.video], format: .mp4)
        XCTAssertEqual(RuleMatching.plainOutput(for: "/in/clip.mov", rule: r), "/in/clip.mp4")
        var elsewhere = r
        elsewhere.outputFolder = "/out"
        XCTAssertEqual(RuleMatching.plainOutput(for: "/in/clip.mov", rule: elsewhere), "/out/clip.mp4")
        let jpeg = FolderRule(folder: "/in", kinds: [.image], format: .jpeg)
        XCTAssertEqual(RuleMatching.plainOutput(for: "/in/a.b.png", rule: jpeg), "/in/a.b.jpg")
        XCTAssertNil(RuleMatching.plainOutput(for: "/in/a.png", rule: FolderRule(folder: "/in", kinds: [.image], preset: "compress")))
    }
}
