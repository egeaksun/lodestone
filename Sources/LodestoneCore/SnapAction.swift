import CoreGraphics

public enum SnapAction: String, CaseIterable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case maximize, center, restore
    case nextDisplay, previousDisplay

    public var title: String {
        switch self {
        case .leftHalf: "Left"
        case .rightHalf: "Right"
        case .topHalf: "Top"
        case .bottomHalf: "Bottom"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .firstThird: "Left Third"
        case .centerThird: "Center Third"
        case .lastThird: "Right Third"
        case .firstTwoThirds: "Left Two Thirds"
        case .lastTwoThirds: "Right Two Thirds"
        case .maximize: "Maximize"
        case .center: "Center"
        case .restore: "Restore"
        case .nextDisplay: "Next Display"
        case .previousDisplay: "Previous Display"
        }
    }

    /// Target frame inside `visible` (Cocoa coordinates). Nil for actions that do not target a fixed region.
    /// Thirds run left-to-right on landscape screens and top-to-bottom on portrait screens.
    public func frame(in v: CGRect, window: CGRect) -> CGRect? {
        let landscape = v.width >= v.height
        func thirds(_ a: Int, _ b: Int) -> CGRect {
            landscape ? cell(v, cols: a, b, of: 3, rows: 0, 1, of: 1)
                : cell(v, cols: 0, 1, of: 1, rows: a, b, of: 3)
        }
        switch self {
        case .leftHalf: return cell(v, cols: 0, 1, of: 2, rows: 0, 1, of: 1)
        case .rightHalf: return cell(v, cols: 1, 2, of: 2, rows: 0, 1, of: 1)
        case .topHalf: return cell(v, cols: 0, 1, of: 1, rows: 0, 1, of: 2)
        case .bottomHalf: return cell(v, cols: 0, 1, of: 1, rows: 1, 2, of: 2)
        case .topLeft: return cell(v, cols: 0, 1, of: 2, rows: 0, 1, of: 2)
        case .topRight: return cell(v, cols: 1, 2, of: 2, rows: 0, 1, of: 2)
        case .bottomLeft: return cell(v, cols: 0, 1, of: 2, rows: 1, 2, of: 2)
        case .bottomRight: return cell(v, cols: 1, 2, of: 2, rows: 1, 2, of: 2)
        case .firstThird: return thirds(0, 1)
        case .centerThird: return thirds(1, 2)
        case .lastThird: return thirds(2, 3)
        case .firstTwoThirds: return thirds(0, 2)
        case .lastTwoThirds: return thirds(1, 3)
        case .maximize: return v
        case .center:
            let w = min(window.width, v.width)
            let h = min(window.height, v.height)
            return CGRect(x: (v.midX - w / 2).rounded(), y: (v.midY - h / 2).rounded(), width: w, height: h)
        case .restore, .nextDisplay, .previousDisplay:
            return nil
        }
    }
}

/// Grid cell spanning columns [c0, c1) of `nc` and rows [r0, r1) of `nr`, with row 0 at the top.
/// Edges are rounded to whole points so adjacent cells tile without gaps or overlap.
private func cell(_ v: CGRect, cols c0: Int, _ c1: Int, of nc: Int, rows r0: Int, _ r1: Int, of nr: Int) -> CGRect {
    func x(_ i: Int) -> CGFloat { (v.minX + v.width * CGFloat(i) / CGFloat(nc)).rounded() }
    func y(_ i: Int) -> CGFloat { (v.maxY - v.height * CGFloat(i) / CGFloat(nr)).rounded() }
    let minX = x(c0), maxX = x(c1)
    let maxY = y(r0), minY = y(r1)
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}
