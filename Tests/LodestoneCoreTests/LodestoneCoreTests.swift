import CoreGraphics
@testable import LodestoneCore
import XCTest

final class SnapActionTests: XCTestCase {
    // 1512x982 visible area offset by a Dock at the bottom and the menu bar at the top.
    let v = CGRect(x: 0, y: 70, width: 1512, height: 875)
    let window = CGRect(x: 100, y: 100, width: 800, height: 600)

    func testHalvesTileWithoutGaps() {
        let l = SnapAction.leftHalf.frame(in: v, window: window)!
        let r = SnapAction.rightHalf.frame(in: v, window: window)!
        XCTAssertEqual(l.minX, v.minX)
        XCTAssertEqual(l.maxX, r.minX)
        XCTAssertEqual(r.maxX, v.maxX)
        XCTAssertEqual(l.height, v.height)
    }

    func testTopIsHigherYInCocoa() {
        let top = SnapAction.topHalf.frame(in: v, window: window)!
        let bottom = SnapAction.bottomHalf.frame(in: v, window: window)!
        XCTAssertEqual(top.maxY, v.maxY)
        XCTAssertEqual(bottom.minY, v.minY)
        XCTAssertEqual(bottom.maxY, top.minY)
    }

    func testQuarters() {
        let tl = SnapAction.topLeft.frame(in: v, window: window)!
        let br = SnapAction.bottomRight.frame(in: v, window: window)!
        XCTAssertEqual(tl.minX, v.minX)
        XCTAssertEqual(tl.maxY, v.maxY)
        XCTAssertEqual(br.maxX, v.maxX)
        XCTAssertEqual(br.minY, v.minY)
        XCTAssertEqual(tl.maxX, br.minX)
        XCTAssertEqual(tl.minY, br.maxY)
    }

    func testThirdsAreWholePointsAndCoverScreen() {
        let a = SnapAction.firstThird.frame(in: v, window: window)!
        let b = SnapAction.centerThird.frame(in: v, window: window)!
        let c = SnapAction.lastThird.frame(in: v, window: window)!
        XCTAssertEqual(a.maxX, b.minX)
        XCTAssertEqual(b.maxX, c.minX)
        XCTAssertEqual(c.maxX, v.maxX)
        for r in [a, b, c] { XCTAssertEqual(r.minX, r.minX.rounded()) }
        XCTAssertEqual(SnapAction.firstTwoThirds.frame(in: v, window: window)!.maxX, b.maxX)
    }

    func testThirdsStackVerticallyOnPortrait() {
        let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        let first = SnapAction.firstThird.frame(in: portrait, window: window)!
        XCTAssertEqual(first.width, 1080)
        XCTAssertEqual(first.maxY, 1920)
        XCTAssertEqual(first.height, 640)
    }

    func testSixthsTileLeftToRight() {
        let sixths: [SnapAction] = [.sixth1, .sixth2, .sixth3, .sixth4, .sixth5, .sixth6]
        let frames = sixths.map { $0.frame(in: v, window: window)! }
        XCTAssertEqual(frames.first!.minX, v.minX)
        XCTAssertEqual(frames.last!.maxX, v.maxX)
        for (a, b) in zip(frames, frames.dropFirst()) { XCTAssertEqual(a.maxX, b.minX) }
        for r in frames {
            XCTAssertEqual(r.width, 252)
            XCTAssertEqual(r.height, v.height)
        }
    }

    func testCenterTwoThirds() {
        let r = SnapAction.centerTwoThirds.frame(in: v, window: window)!
        XCTAssertEqual(r.minX, 252)
        XCTAssertEqual(r.maxX, 1260)
    }

    func testCenterKeepsSizeAndClamps() {
        let c = SnapAction.center.frame(in: v, window: window)!
        XCTAssertEqual(c.size, window.size)
        XCTAssertEqual(c.midX, v.midX, accuracy: 1)
        let huge = SnapAction.center.frame(in: v, window: CGRect(x: 0, y: 0, width: 5000, height: 5000))!
        XCTAssertEqual(huge, v)
    }

    func testHorizontalDirection() {
        for a in [SnapAction.leftHalf, .topLeft, .bottomLeft, .firstThird, .firstTwoThirds, .sixth1, .sixth3] {
            XCTAssertEqual(a.horizontalDirection, -1, a.rawValue)
        }
        for a in [SnapAction.rightHalf, .topRight, .bottomRight, .lastThird, .lastTwoThirds, .sixth4, .sixth6] {
            XCTAssertEqual(a.horizontalDirection, 1, a.rawValue)
        }
        for a in [SnapAction.maximize, .center, .topHalf, .bottomHalf, .centerThird, .centerTwoThirds, .restore] {
            XCTAssertEqual(a.horizontalDirection, 0, a.rawValue)
        }
    }

    func testNonRegionActions() {
        XCTAssertNil(SnapAction.restore.frame(in: v, window: window))
        XCTAssertNil(SnapAction.nextDisplay.frame(in: v, window: window))
    }
}

final class SnapZonesTests: XCTestCase {
    // 24 columns of 63pt, 12 rows of ~81.8pt.
    let f = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testInteriorHasNoZone() {
        XCTAssertNil(SnapZones.action(at: CGPoint(x: 700, y: 500), in: f))
        XCTAssertNil(SnapZones.action(at: CGPoint(x: 7, y: 500), in: f))
    }

    func testSideEdges() {
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 0, y: 500), in: f), .leftHalf)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1512, y: 500), in: f), .rightHalf)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 0, y: 850), in: f), .topHalf)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1512, y: 850), in: f), .topHalf)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 0, y: 120), in: f), .bottomHalf)
    }

    func testTopEdgeIsMaximizeBetweenCorners() {
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 756, y: 982), in: f), .maximize)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 100, y: 980), in: f), .maximize)
    }

    func testCornersAreOneCell() {
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 0, y: 982), in: f), .topLeft)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 40, y: 980), in: f), .topLeft)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1511, y: 950), in: f), .topRight)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 2, y: 3), in: f), .bottomLeft)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1480, y: 0), in: f), .bottomRight)
    }

    func testBottomEdgeThirdsAndTwoThirds() {
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 300, y: 0), in: f), .firstThird)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 500, y: 0), in: f), .firstTwoThirds)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 756, y: 0), in: f), .centerThird)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1000, y: 0), in: f), .lastTwoThirds)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1200, y: 0), in: f), .lastThird)
    }

    func testZonesOnSecondaryScreen() {
        let right = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 4072, y: 500), in: right), .rightHalf)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 2800, y: 1240), in: right), .maximize)
    }

    func testPortrait() {
        let p = CGRect(x: 0, y: 0, width: 1080, height: 1920) // 12 columns of 90pt, 24 rows of 80pt
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 300, y: 0), in: p), .leftHalf)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 800, y: 0), in: p), .rightHalf)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 0, y: 1920 - 80 * 6.5), in: p), .firstThird)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1080, y: 960), in: p), .centerThird)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 0, y: 1920 - 80 * 20.5), in: p), .bottomHalf)
    }
}

final class ScreenLayoutTests: XCTestCase {
    let layout = ScreenLayout(screens: [
        Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949)),
        Screen(frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440), visibleFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1415)),
    ])

    func testFlipIsInvolution() {
        let r = CGRect(x: 10, y: 20, width: 300, height: 400)
        XCTAssertEqual(layout.flip(layout.flip(r)), r)
        XCTAssertEqual(layout.flip(r).minY, 982 - 420)
        XCTAssertEqual(layout.flip(CGPoint(x: 5, y: 982)), CGPoint(x: 5, y: 0))
    }

    func testScreenContainingPoint() {
        XCTAssertEqual(layout.screenIndex(containing: CGPoint(x: 100, y: 100)), 0)
        XCTAssertEqual(layout.screenIndex(containing: CGPoint(x: 2000, y: -100)), 1)
        XCTAssertNil(layout.screenIndex(containing: CGPoint(x: 100, y: -100)))
    }

    func testBestScreenByOverlap() {
        XCTAssertEqual(layout.screenIndex(bestFor: CGRect(x: 1400, y: 0, width: 400, height: 300)), 1)
        XCTAssertEqual(layout.screenIndex(bestFor: CGRect(x: 1200, y: 0, width: 400, height: 300)), 0)
        XCTAssertEqual(layout.screenIndex(bestFor: CGRect(x: 9000, y: 0, width: 10, height: 10)), 1)
    }

    func testLeftToRightOrderIgnoresNSScreenOrder() {
        // Primary (menu bar) screen in the middle, others listed in arbitrary order.
        let three = ScreenLayout(screens: [
            Screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050)),
            Screen(frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080)),
            Screen(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)),
        ])
        XCTAssertEqual(three.leftToRight, [2, 0, 1])
        XCTAssertEqual(three.adjacentScreen(to: 2, direction: 1), 0)
        XCTAssertEqual(three.adjacentScreen(to: 0, direction: 1), 1)
        XCTAssertEqual(three.adjacentScreen(to: 1, direction: 1), 2)
        XCTAssertEqual(three.adjacentScreen(to: 0, direction: -1), 2)
        XCTAssertEqual(three.adjacentScreen(to: 2, direction: -1), 1)
        XCTAssertEqual(three.adjacentScreen(to: 0, direction: 0), 1)
    }

    func testAdjacentScreenWithOneScreen() {
        let one = ScreenLayout(screens: [layout.screens[0]])
        XCTAssertEqual(one.adjacentScreen(to: 0, direction: 1), 0)
    }

    func testMapKeepsProportions() {
        let a = layout.screens[0].visibleFrame
        let b = layout.screens[1].visibleFrame
        let leftHalf = SnapAction.leftHalf.frame(in: a, window: .zero)!
        let mapped = ScreenLayout.map(leftHalf, from: a, to: b)
        XCTAssertEqual(mapped, SnapAction.leftHalf.frame(in: b, window: .zero)!)
        XCTAssertTrue(b.contains(ScreenLayout.map(CGRect(x: 1400, y: 900, width: 900, height: 900), from: a, to: b)))
    }
}
