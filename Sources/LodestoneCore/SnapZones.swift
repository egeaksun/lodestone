import CoreGraphics

/// Maps a cursor position during a window drag to a snap action. Pure arithmetic: this runs on every
/// mouse-dragged event, so it must never touch the Accessibility API or allocate.
///
/// The layout follows Magnet's default activation areas. The screen is divided into a grid (24 columns ×
/// 12 rows on landscape screens, 12 × 24 on portrait screens), and the cell along the edge the cursor
/// touches decides the action. Each corner is a single cell.
public enum SnapZones {
    /// - Parameters:
    ///   - p: Cursor location, Cocoa coordinates.
    ///   - frame: Full frame of the screen under the cursor.
    ///   - edge: How close to an edge (points) the cursor must be.
    public static func action(at p: CGPoint, in frame: CGRect, edge: CGFloat = 6) -> SnapAction? {
        let left = p.x <= frame.minX + edge
        let right = p.x >= frame.maxX - edge
        let top = p.y >= frame.maxY - edge
        let bottom = p.y <= frame.minY + edge
        guard left || right || top || bottom else { return nil }

        let landscape = frame.width >= frame.height
        let cols = landscape ? 24 : 12
        let rows = landscape ? 12 : 24
        let col = min(max(Int((p.x - frame.minX) / frame.width * CGFloat(cols)), 0), cols - 1)
        let row = min(max(Int((frame.maxY - p.y) / frame.height * CGFloat(rows)), 0), rows - 1)

        if (top && col == 0) || (left && row == 0) { return .topLeft }
        if (top && col == cols - 1) || (right && row == 0) { return .topRight }
        if (bottom && col == 0) || (left && row == rows - 1) { return .bottomLeft }
        if (bottom && col == cols - 1) || (right && row == rows - 1) { return .bottomRight }
        if top { return .maximize }

        if landscape {
            if left || right {
                switch row {
                case ...2: return .topHalf
                case 9...: return .bottomHalf
                default: return left ? .leftHalf : .rightHalf
                }
            }
            switch col {
            case ...6: return .firstThird
            case 7...8: return .firstTwoThirds
            case 9...14: return .centerThird
            case 15...16: return .lastTwoThirds
            default: return .lastThird
            }
        }

        // Portrait: the side edges hold the stacked halves, thirds and two-thirds; the bottom edge splits left/right.
        if left || right {
            switch row {
            case ...4: return .topHalf
            case 5...7: return .firstThird
            case 8...9: return .firstTwoThirds
            case 10...13: return .centerThird
            case 14...15: return .lastTwoThirds
            case 16...18: return .lastThird
            default: return .bottomHalf
            }
        }
        return col < cols / 2 ? .leftHalf : .rightHalf
    }
}
