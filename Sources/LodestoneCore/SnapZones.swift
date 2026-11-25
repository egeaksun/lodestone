import CoreGraphics

/// Maps a cursor position during a window drag to a snap action. Pure arithmetic: this runs on every
/// mouse-dragged event, so it must never touch the Accessibility API or allocate.
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

        let cornerX = min(max(frame.width * 0.12, 80), 260)
        let cornerY = min(max(frame.height * 0.12, 80), 260)
        let nearLeft = p.x <= frame.minX + cornerX
        let nearRight = p.x >= frame.maxX - cornerX
        let nearTop = p.y >= frame.maxY - cornerY
        let nearBottom = p.y <= frame.minY + cornerY

        if (top && nearLeft) || (left && nearTop) { return .topLeft }
        if (top && nearRight) || (right && nearTop) { return .topRight }
        if (bottom && nearLeft) || (left && nearBottom) { return .bottomLeft }
        if (bottom && nearRight) || (right && nearBottom) { return .bottomRight }
        if top { return .maximize }
        if left { return .leftHalf }
        if right { return .rightHalf }

        // Bottom edge: pick a third by horizontal position (landscape) or the bottom half (portrait).
        guard frame.width >= frame.height else { return .bottomHalf }
        let t = (p.x - frame.minX) / frame.width
        return t < 1.0 / 3 ? .firstThird : t < 2.0 / 3 ? .centerThird : .lastThird
    }
}
