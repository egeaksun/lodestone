import CoreGraphics

/// One display, in Cocoa global coordinates (origin at the bottom-left of the primary screen, y up).
public struct Screen: Equatable, Sendable {
    public let frame: CGRect
    /// Frame minus the menu bar and Dock.
    public let visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// An immutable snapshot of the display arrangement. Cheap to copy across threads.
public struct ScreenLayout: Equatable, Sendable {
    public let screens: [Screen]
    /// Height of the primary screen, the pivot between Cocoa and Accessibility coordinates.
    public let primaryHeight: CGFloat

    /// `screens[0]` must be the primary (menu bar) screen, as `NSScreen.screens` guarantees.
    public init(screens: [Screen]) {
        self.screens = screens
        primaryHeight = screens.first?.frame.height ?? 0
    }

    /// Converts between Cocoa coordinates and Accessibility coordinates (origin top-left, y down).
    /// The conversion is its own inverse.
    public func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    public func flip(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// Index of the screen under a cursor location. Closed bounds, because the cursor can sit exactly on maxX/maxY.
    public func screenIndex(containing p: CGPoint) -> Int? {
        for i in screens.indices {
            let f = screens[i].frame
            if p.x >= f.minX, p.x <= f.maxX, p.y >= f.minY, p.y <= f.maxY { return i }
        }
        return nil
    }

    /// Index of the screen showing the largest part of `rect`, or the nearest screen if none overlaps.
    public func screenIndex(bestFor rect: CGRect) -> Int {
        var best = 0
        var bestArea: CGFloat = -1
        for i in screens.indices {
            let overlap = screens[i].frame.intersection(rect)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = i
            }
        }
        if bestArea > 0 { return best }

        let c = CGPoint(x: rect.midX, y: rect.midY)
        var bestDistance = CGFloat.infinity
        for i in screens.indices {
            let f = screens[i].frame
            let dx = f.midX - c.x, dy = f.midY - c.y
            let d = dx * dx + dy * dy
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        return best
    }

    /// Moves `rect` from one visible area to another, keeping its proportional position and size.
    public static func map(_ rect: CGRect, from a: CGRect, to b: CGRect) -> CGRect {
        let sx = b.width / a.width
        let sy = b.height / a.height
        let w = min((rect.width * sx).rounded(), b.width)
        let h = min((rect.height * sy).rounded(), b.height)
        var x = (b.minX + (rect.minX - a.minX) * sx).rounded()
        var y = (b.minY + (rect.minY - a.minY) * sy).rounded()
        x = min(max(x, b.minX), b.maxX - w)
        y = min(max(y, b.minY), b.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
