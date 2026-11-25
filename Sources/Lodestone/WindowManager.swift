import ApplicationServices
import LodestoneCore

/// Runs every Accessibility operation on one serial background queue, so a slow or hung app can never
/// stall the main thread, the overlay, or the cursor. All state here is confined to `queue`.
final class WindowManager {
    let queue = DispatchQueue(label: "lodestone.ax", qos: .userInteractive)

    private struct Snap {
        /// Frame before the first snap, for Restore and drag-to-unsnap. Accessibility coordinates.
        var original: CGRect
        /// The frame we asked for, and the one the app actually accepted (it may enforce a minimum size).
        var requested: CGRect
        var actual: CGRect

        func matches(_ size: CGSize) -> Bool {
            size.isClose(to: requested.size) || size.isClose(to: actual.size)
        }
    }

    private var snaps: [WindowKey: Snap] = [:]

    /// Keyboard and menu actions, applied to the focused window of `pid`.
    func perform(_ action: SnapAction, pid: pid_t, layout: ScreenLayout) {
        queue.async { [self] in
            guard !layout.screens.isEmpty,
                  let window = AX.focusedWindow(pid: pid),
                  let current = AX.frame(of: window) else { return }
            let key = WindowKey(element: window)
            let cocoa = layout.flip(current)
            let index = layout.screenIndex(bestFor: cocoa)

            switch action {
            case .restore:
                guard let snap = snaps.removeValue(forKey: key) else { return }
                AX.setFrame(of: window, to: snap.original, current: current)

            case .nextDisplay, .previousDisplay:
                let n = layout.screens.count
                guard n > 1 else { return }
                let to = (index + (action == .nextDisplay ? 1 : n - 1)) % n
                let moved = ScreenLayout.map(cocoa, from: layout.screens[index].visibleFrame, to: layout.screens[to].visibleFrame)
                apply(window, key: key, current: current, target: layout.flip(moved))

            default:
                guard let target = action.frame(in: layout.screens[index].visibleFrame, window: cocoa) else { return }
                apply(window, key: key, current: current, target: layout.flip(target))
            }
        }
    }

    /// Drop at the end of a drag. When `requireMoveFrom` is set, the window only snaps if it actually moved
    /// (not resized) since that frame: this covers a drop that lands before the drag has been confirmed.
    func snap(_ window: AXUIElement, to action: SnapAction, screen: Int, layout: ScreenLayout, requireMoveFrom start: CGRect? = nil) {
        queue.async { [self] in
            guard screen < layout.screens.count, let current = AX.frame(of: window) else { return }
            if let start, !Self.isMove(from: start, to: current) { return }
            guard let target = action.frame(in: layout.screens[screen].visibleFrame, window: layout.flip(current)) else { return }
            apply(window, key: WindowKey(element: window), current: current, target: layout.flip(target))
        }
    }

    /// Called once when a drag of `window` is confirmed. If the window is still at its snapped size, put
    /// back its pre-snap size and keep the same relative spot under the cursor.
    func unsnapForDrag(_ window: AXUIElement, cursor: CGPoint) {
        queue.async { [self] in
            let key = WindowKey(element: window)
            guard let snap = snaps[key], let current = AX.frame(of: window) else { return }
            snaps[key] = nil
            guard snap.matches(current.size) else { return }
            let size = snap.original.size
            let relative = current.width > 0 ? (cursor.x - current.minX) / current.width : 0.5
            AX.setSize(window, size)
            AX.setPosition(window, CGPoint(x: (cursor.x - relative * size.width).rounded(), y: current.minY))
        }
    }

    static func isMove(from a: CGRect, to b: CGRect) -> Bool {
        a.size.isClose(to: b.size) && !a.origin.isClose(to: b.origin)
    }

    private func apply(_ window: AXUIElement, key: WindowKey, current: CGRect, target: CGRect) {
        // Keep the first pre-snap frame while the window stays snapped, so Restore goes back to where
        // the user had it, not to an intermediate snap.
        let original = snaps[key].flatMap { $0.matches(current.size) ? $0.original : nil } ?? current
        AX.setFrame(of: window, to: target, current: current)
        let actual = AX.frame(of: window) ?? target
        if snaps.count >= 512 { snaps.removeAll(keepingCapacity: true) }
        snaps[key] = Snap(original: original, requested: target, actual: actual)
    }
}
