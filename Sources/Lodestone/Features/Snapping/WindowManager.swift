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
        /// The action that produced this frame, when there was one.
        var action: SnapAction?

        func matches(_ size: CGSize) -> Bool {
            size.isClose(to: requested.size) || size.isClose(to: actual.size)
        }

        func matches(_ frame: CGRect) -> Bool {
            frame.isClose(to: requested) || frame.isClose(to: actual)
        }
    }

    private var snaps: [WindowKey: Snap] = [:]

    /// Applies a snap action to a window.
    ///
    /// With `cycleDisplays`, repeating an action on a window that is already in that position moves it to
    /// the same position on the adjacent display, in the action's direction (left-side actions go left,
    /// right-side and centered actions go right), wrapping around at the last display. `display` (a
    /// left-to-right index) puts the window on that display instead of the one it is on.
    func perform(_ action: SnapAction, target: WindowTarget, apps: [RunningApp], layout: ScreenLayout,
                 cycleDisplays: Bool, display: Int? = nil,
                 completion: (@Sendable (Result<WindowInfo, IPCError>) -> Void)? = nil) {
        queue.async { [self] in
            let result = catchingIPC {
                guard !layout.screens.isEmpty else { throw IPCError.failed("No displays") }
                let window = try resolve(target, apps: apps)
                guard let current = AX.frame(of: window) else { throw IPCError.failed("Can't read the window's frame") }
                let key = WindowKey(element: window)
                let cocoa = layout.flip(current)
                let index = layout.screenIndex(bestFor: cocoa)
                let order = layout.leftToRight
                let chosen: Int? = try display.map { n in
                    guard n >= 1, n <= order.count else { throw IPCError.invalidParams("Display \(n) doesn't exist (1…\(order.count))") }
                    return order[n - 1]
                }

                switch action {
                case .restore:
                    guard let snap = snaps.removeValue(forKey: key) else { throw IPCError.notFound("This window has nothing to restore") }
                    AX.setFrame(of: window, to: snap.original, current: current)

                case .nextDisplay, .previousDisplay:
                    let to = chosen ?? layout.adjacentScreen(to: index, direction: action == .nextDisplay ? 1 : -1)
                    guard to != index else { break }
                    let moved = ScreenLayout.map(cocoa, from: layout.screens[index].visibleFrame, to: layout.screens[to].visibleFrame)
                    apply(window, key: key, current: current, target: layout.flip(moved), action: nil)

                default:
                    var screen = chosen ?? index
                    guard let here = action.frame(in: layout.screens[screen].visibleFrame, window: cocoa) else {
                        throw IPCError.invalidParams("\(action.rawValue) can't be applied")
                    }
                    var target = here
                    if chosen == nil && cycleDisplays && isRepeat(action, key: key, current: current, here: layout.flip(here)) {
                        screen = layout.adjacentScreen(to: index, direction: action.horizontalDirection)
                        target = action.frame(in: layout.screens[screen].visibleFrame, window: cocoa) ?? here
                    }
                    apply(window, key: key, current: current, target: layout.flip(target), action: action)
                }
                return try info(window, apps: apps, layout: layout)
            }
            completion?(result)
        }
    }

    /// Sets an exact frame, in Accessibility coordinates (top-left origin of the primary display).
    func move(_ target: WindowTarget, apps: [RunningApp], to frame: CGRect, layout: ScreenLayout,
              completion: @escaping @Sendable (Result<WindowInfo, IPCError>) -> Void) {
        queue.async { [self] in
            completion(catchingIPC {
                let window = try resolve(target, apps: apps)
                let current = AX.frame(of: window)
                AX.setFrame(of: window, to: frame, current: current)
                return try info(window, apps: apps, layout: layout)
            })
        }
    }

    /// Raises a window above its app's other windows. The caller activates the app.
    func raise(_ target: WindowTarget, apps: [RunningApp], layout: ScreenLayout,
               completion: @escaping @Sendable (Result<WindowInfo, IPCError>) -> Void) {
        queue.async { [self] in
            completion(catchingIPC {
                let window = try resolve(target, apps: apps)
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                return try info(window, apps: apps, layout: layout)
            })
        }
    }

    /// Every standard window of the given apps, front to back within each app.
    func list(apps: [RunningApp], layout: ScreenLayout, completion: @escaping @Sendable ([WindowInfo]) -> Void) {
        queue.async { [self] in
            var result: [WindowInfo] = []
            for app in apps {
                for window in AX.windows(pid: app.pid) {
                    if let i = try? info(window, app: app, layout: layout) { result.append(i) }
                }
            }
            completion(result)
        }
    }

    private func resolve(_ target: WindowTarget, apps: [RunningApp]) throws -> AXUIElement {
        switch target {
        case .focused(let pid):
            guard let window = AX.focusedWindow(pid: pid) else { throw IPCError.notFound("The frontmost app has no focused window") }
            return window
        case .window(let id):
            for app in apps {
                if let window = AX.windows(pid: app.pid).first(where: { AX.windowID($0) == id }) { return window }
            }
            throw IPCError.notFound("No window with id \(id). Run `lodestone window list`.")
        case .app(let query):
            let q = query.lowercased()
            guard let app = apps.first(where: { $0.name.lowercased() == q || $0.bundleID?.lowercased() == q })
                ?? apps.first(where: { $0.name.lowercased().contains(q) }) else {
                throw IPCError.notFound("No running app matches '\(query)'")
            }
            guard let window = AX.focusedWindow(pid: app.pid) ?? AX.windows(pid: app.pid).first else {
                throw IPCError.notFound("\(app.name) has no windows")
            }
            return window
        }
    }

    private func info(_ window: AXUIElement, apps: [RunningApp], layout: ScreenLayout) throws -> WindowInfo {
        let pid = AX.pid(of: window)
        let app = apps.first { $0.pid == pid } ?? RunningApp(pid: pid, name: "pid \(pid)", bundleID: nil, isActive: false)
        return try info(window, app: app, layout: layout)
    }

    private func info(_ window: AXUIElement, app: RunningApp, layout: ScreenLayout) throws -> WindowInfo {
        guard let frame = AX.frame(of: window) else { throw IPCError.failed("Can't read the window's frame") }
        let screen = layout.screenIndex(bestFor: layout.flip(frame))
        let display = (layout.leftToRight.firstIndex(of: screen) ?? 0) + 1
        let focused = app.isActive && AX.focusedWindow(pid: app.pid).map { CFEqual($0, window) } == true
        return WindowInfo(id: AX.windowID(window), app: app.name, bundleID: app.bundleID, pid: app.pid,
                          title: AX.string(window, kAXTitleAttribute) ?? "",
                          frame: Rect(frame), display: display, focused: focused,
                          minimized: AX.bool(window, kAXMinimizedAttribute) ?? false,
                          snappedAs: snaps[WindowKey(element: window)]?.action?.rawValue)
    }

    /// Drop at the end of a drag. When `requireMoveFrom` is set, the window only snaps if it actually moved
    /// (not resized) since that frame: this covers a drop that lands before the drag has been confirmed.
    func snap(_ window: AXUIElement, to action: SnapAction, screen: Int, layout: ScreenLayout, requireMoveFrom start: CGRect? = nil) {
        queue.async { [self] in
            guard screen < layout.screens.count, let current = AX.frame(of: window) else { return }
            if let start, !Self.isMove(from: start, to: current) { return }
            guard let target = action.frame(in: layout.screens[screen].visibleFrame, window: layout.flip(current)) else { return }
            apply(window, key: WindowKey(element: window), current: current, target: layout.flip(target), action: action)
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

    /// True when the window already sits where `action` would put it on its current display: either we put
    /// it there and it hasn't moved since (this tolerates apps that adjust the size we ask for), or its
    /// frame matches the target anyway (snapped by another tool or by hand).
    private func isRepeat(_ action: SnapAction, key: WindowKey, current: CGRect, here: CGRect) -> Bool {
        if let snap = snaps[key], snap.action == action, snap.matches(current) { return true }
        return current.isClose(to: here)
    }

    private func apply(_ window: AXUIElement, key: WindowKey, current: CGRect, target: CGRect, action: SnapAction?) {
        // Keep the first pre-snap frame while the window stays snapped, so Restore goes back to where
        // the user had it, not to an intermediate snap.
        let original = snaps[key].flatMap { $0.matches(current.size) ? $0.original : nil } ?? current
        AX.setFrame(of: window, to: target, current: current)
        let actual = AX.frame(of: window) ?? target
        if snaps.count >= 512 { snaps.removeAll(keepingCapacity: true) }
        snaps[key] = Snap(original: original, requested: target, actual: actual, action: action)
    }
}

/// Which window an operation applies to.
enum WindowTarget: Sendable {
    /// The focused window of the app with this pid (normally the frontmost app).
    case focused(pid_t)
    /// A window by its system window number (`lodestone window list` shows it).
    case window(UInt32)
    /// The focused (or first) window of an app, by name or bundle identifier.
    case app(String)
}

/// A snapshot of a running app, taken on the main thread (NSWorkspace isn't thread-safe).
struct RunningApp: Sendable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let isActive: Bool
}

/// A rectangle in the JSON shape the CLI uses.
struct Rect: Codable, Sendable {
    var x: Double, y: Double, width: Double, height: Double
    init(_ r: CGRect) {
        x = r.minX; y = r.minY; width = r.width; height = r.height
    }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// A window as reported over IPC. `frame` is in screen points with the origin at the top-left of the
/// primary display (y grows downward), the same convention as `window move`.
struct WindowInfo: Codable, Sendable {
    var id: UInt32?
    var app: String
    var bundleID: String?
    var pid: Int32
    var title: String
    var frame: Rect
    /// 1-based, counting displays from left to right.
    var display: Int
    var focused: Bool
    var minimized: Bool
    /// The snap action Lodestone last applied, if the window hasn't moved since.
    var snappedAs: String?
}

/// Runs `body`, turning any thrown error into an `IPCError` result.
func catchingIPC<T>(_ body: () throws -> T) -> Result<T, IPCError> {
    do {
        return .success(try body())
    } catch let error as IPCError {
        return .failure(error)
    } catch {
        return .failure(.failed(String(describing: error)))
    }
}
