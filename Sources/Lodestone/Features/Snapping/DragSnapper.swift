import AppKit
import LodestoneCore

/// Drag-to-edge snapping, built to cost close to nothing while you move windows.
///
/// - Mouse events arrive through passive global monitors (`NSEvent.addGlobalMonitorForEvents`). They are
///   copies sent after the fact, so the window server never waits on this process the way it does for an
///   active `CGEventTap`.
/// - The leftMouseDragged monitor exists only while the button is down.
/// - Per dragged event the work is one rectangle test. Accessibility is used about three times per gesture:
///   find the window under the cursor, confirm it moved, and, on drop, set its frame. All of that runs on
///   the window manager's background queue.
/// - The overlay is only touched when the zone changes.
final class DragSnapper {
    private struct Zone: Equatable {
        let action: SnapAction
        let screen: Int
    }

    var layout: ScreenLayout

    private let windows: WindowManager
    private let overlay = SnapOverlay()
    private var downMonitor: Any?
    private var upMonitor: Any?
    private var dragMonitor: Any?

    // State for the current gesture, main thread only. `gesture` invalidates async results from older gestures.
    private var gesture = 0
    private var origin = CGPoint.zero
    private var cursor = CGPoint.zero
    private var lookupStarted = false
    private var window: AXUIElement?
    private var startFrame: CGRect?
    private var confirmed = false
    private var checking = false
    private var recheck = false
    private var distanceChecked = false
    private var zone: Zone?

    init(windows: WindowManager, layout: ScreenLayout) {
        self.windows = windows
        self.layout = layout
    }

    var isRunning: Bool { downMonitor != nil }

    func start() {
        guard downMonitor == nil else { return }
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in self?.mouseDown(e) }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.mouseUp() }
    }

    func stop() {
        for m in [downMonitor, upMonitor, dragMonitor] { if let m { NSEvent.removeMonitor(m) } }
        downMonitor = nil
        upMonitor = nil
        dragMonitor = nil
        reset()
    }

    private func reset() {
        gesture &+= 1
        lookupStarted = false
        window = nil
        startFrame = nil
        confirmed = false
        checking = false
        recheck = false
        distanceChecked = false
        zone = nil
        overlay.hide()
    }

    private func mouseDown(_ e: NSEvent) {
        reset()
        // For global events (no window), locationInWindow is the screen location in Cocoa coordinates.
        origin = e.locationInWindow
        cursor = origin
        if dragMonitor == nil {
            dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] e in self?.dragged(e) }
        }
    }

    private func mouseUp() {
        if let m = dragMonitor {
            NSEvent.removeMonitor(m)
            dragMonitor = nil
        }
        if let zone, let window {
            if confirmed {
                windows.snap(window, to: zone.action, screen: zone.screen, layout: layout)
            } else if let startFrame {
                windows.snap(window, to: zone.action, screen: zone.screen, layout: layout, requireMoveFrom: startFrame)
            }
        }
        reset()
    }

    private func dragged(_ e: NSEvent) {
        let p = e.locationInWindow
        cursor = p
        let distance = abs(p.x - origin.x) + abs(p.y - origin.y)

        if !lookupStarted {
            guard distance > 4 else { return }
            lookupStarted = true
            lookUpWindow(at: p)
        }

        let newZone = zone(at: p)
        let zoneChanged = newZone != zone
        zone = newZone

        if confirmed {
            if zoneChanged { showZone() }
            return
        }
        guard window != nil else { return }
        // Text selections and other in-window drags never move the window. Check only twice: once the
        // cursor has travelled a bit, and whenever it enters a zone.
        if !distanceChecked && distance > 24 {
            distanceChecked = true
            confirmMove()
        } else if zoneChanged && newZone != nil {
            confirmMove()
        }
    }

    private func zone(at p: CGPoint) -> Zone? {
        guard let i = layout.screenIndex(containing: p),
              let action = SnapZones.action(at: p, in: layout.screens[i].frame) else { return nil }
        return Zone(action: action, screen: i)
    }

    private func lookUpWindow(at p: CGPoint) {
        let g = gesture
        let axPoint = layout.flip(p)
        windows.queue.async { [weak self] in
            let window = AX.window(at: axPoint)
            let frame = window.flatMap(AX.frame(of:))
            DispatchQueue.main.async {
                guard let self, self.gesture == g, let window, let frame else { return }
                self.window = window
                self.startFrame = frame
            }
        }
    }

    private func confirmMove() {
        guard let window, let start = startFrame else { return }
        if checking {
            recheck = true
            return
        }
        checking = true
        let g = gesture
        windows.queue.async { [weak self] in
            let frame = AX.frame(of: window)
            DispatchQueue.main.async {
                guard let self, self.gesture == g else { return }
                self.checking = false
                if let frame, WindowManager.isMove(from: start, to: frame) {
                    self.confirmed = true
                    self.windows.unsnapForDrag(window, cursor: self.layout.flip(self.cursor))
                    self.showZone()
                } else if self.recheck {
                    self.recheck = false
                    self.confirmMove()
                }
            }
        }
    }

    private func showZone() {
        guard let zone, zone.screen < layout.screens.count,
              let rect = zone.action.frame(in: layout.screens[zone.screen].visibleFrame, window: .zero) else {
            overlay.hide()
            return
        }
        overlay.show(rect)
    }
}
