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

    func testCenterKeepsSizeAndClamps() {
        let c = SnapAction.center.frame(in: v, window: window)!
        XCTAssertEqual(c.size, window.size)
        XCTAssertEqual(c.midX, v.midX, accuracy: 1)
        let huge = SnapAction.center.frame(in: v, window: CGRect(x: 0, y: 0, width: 5000, height: 5000))!
        XCTAssertEqual(huge, v)
    }

    func testNonRegionActions() {
        XCTAssertNil(SnapAction.restore.frame(in: v, window: window))
        XCTAssertNil(SnapAction.nextDisplay.frame(in: v, window: window))
    }
}

final class SnapZonesTests: XCTestCase {
    let f = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testInteriorHasNoZone() {
        XCTAssertNil(SnapZones.action(at: CGPoint(x: 700, y: 500), in: f))
        XCTAssertNil(SnapZones.action(at: CGPoint(x: 7, y: 500), in: f))
    }

    func testEdges() {
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 0, y: 500), in: f), .leftHalf)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1512, y: 500), in: f), .rightHalf)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 756, y: 982), in: f), .maximize)
    }

    func testCorners() {
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 0, y: 982), in: f), .topLeft)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 100, y: 980), in: f), .topLeft)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1511, y: 900), in: f), .topRight)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 2, y: 3), in: f), .bottomLeft)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1450, y: 0), in: f), .bottomRight)
    }

    func testBottomEdgeThirds() {
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 400, y: 0), in: f), .firstThird)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 756, y: 0), in: f), .centerThird)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1100, y: 0), in: f), .lastThird)
    }

    func testZonesOnSecondaryScreen() {
        let right = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 4072, y: 500), in: right), .rightHalf)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 2800, y: 1240), in: right), .maximize)
    }

    func testPortraitBottomIsBottomHalf() {
        let p = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 540, y: 0), in: p), .bottomHalf)
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

    func testMapKeepsProportions() {
        let a = layout.screens[0].visibleFrame
        let b = layout.screens[1].visibleFrame
        let leftHalf = SnapAction.leftHalf.frame(in: a, window: .zero)!
        let mapped = ScreenLayout.map(leftHalf, from: a, to: b)
        XCTAssertEqual(mapped, SnapAction.leftHalf.frame(in: b, window: .zero)!)
        XCTAssertTrue(b.contains(ScreenLayout.map(CGRect(x: 1400, y: 900, width: 900, height: 900), from: a, to: b)))
    }
}
