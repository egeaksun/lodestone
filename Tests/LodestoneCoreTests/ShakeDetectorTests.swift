import XCTest
@testable import LodestoneCore

final class ShakeDetectorTests: XCTestCase {
    /// Moves the pointer through `xs`, `step` seconds apart, in 5-point increments like real events.
    private func feed(_ d: inout ShakeDetector, _ xs: [Double], step: Double = 0.01, start: Double = 0) -> Int? {
        var t = start
        var x = xs[0]
        var events = 0
        _ = d.add(x: x, time: t)
        for target in xs.dropFirst() {
            while x != target {
                x += max(-5, min(5, target - x))
                t += step
                events += 1
                if d.add(x: x, time: t) { return events }
            }
        }
        return nil
    }

    func testShakeIsRecognized() {
        var d = ShakeDetector()
        XCTAssertNotNil(feed(&d, [500, 560, 500, 560, 500]))
    }

    func testStraightDragIsNotAShake() {
        var d = ShakeDetector()
        XCTAssertNil(feed(&d, [100, 900]))
        XCTAssertNil(feed(&d, [900, 100]))
    }

    func testSmallJitterIsNotAShake() {
        var d = ShakeDetector()
        XCTAssertNil(feed(&d, [500, 515, 500, 515, 500, 515, 500, 515, 500]))
    }

    func testSlowBackAndForthIsNotAShake() {
        var d = ShakeDetector()
        // 0.1 s per 5 points: each stroke takes over a second.
        XCTAssertNil(feed(&d, [500, 560, 500, 560, 500], step: 0.1))
    }

    func testDetectorRestartsAfterAShake() {
        var d = ShakeDetector()
        XCTAssertNotNil(feed(&d, [500, 560, 500, 560, 500]))
        XCTAssertNil(feed(&d, [500, 560], start: 1))
        d.reset()
        XCTAssertNotNil(feed(&d, [300, 240, 300, 240, 300], start: 2))
    }
}
