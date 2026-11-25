import ApplicationServices

/// Thin Accessibility wrappers. Every call here is a synchronous IPC round-trip into another process,
/// so callers must stay off the main thread and make as few calls as possible.
enum AX {
    static let systemWide = AXUIElementCreateSystemWide()
    private static let ownPID = getpid()

    /// Caps how long a hung app can block the AX queue (the default is about 6 seconds).
    static func configure() {
        AXUIElementSetMessagingTimeout(systemWide, 0.3)
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
    }

    /// The window under a point in Accessibility (top-left origin) coordinates.
    static func window(at p: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &hit) == .success,
              let hit, pid(of: hit) != ownPID else { return nil }
        if let window = element(hit, kAXWindowAttribute) { return window }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role) == .success,
           (role as? String) == kAXWindowRole {
            return hit
        }
        return nil
    }

    private static let frameAttributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray

    /// Position and size in a single round-trip, in Accessibility coordinates.
    static func frame(of window: AXUIElement) -> CGRect? {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(window, frameAttributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let values = values as? [AnyObject], values.count == 2 else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard CFGetTypeID(values[0]) == AXValueGetTypeID(), CFGetTypeID(values[1]) == AXValueGetTypeID(),
              AXValueGetValue(values[0] as! AXValue, .cgPoint, &origin),
              AXValueGetValue(values[1] as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Sets a window's frame (Accessibility coordinates).
    ///
    /// Size, then position, then size again: the first resize lets the window fit where it lands, and the
    /// second applies the size the window may have refused at its old position (for example, across displays).
    /// Calls that would not change anything are skipped.
    static func setFrame(of window: AXUIElement, to target: CGRect, current: CGRect?) {
        // Apps that enable AXEnhancedUserInterface (Chromium, Electron, some others) animate every
        // AX-driven resize, which makes snapping visibly slow. Turn it off for the duration of the change.
        let app = AXUIElementCreateApplication(pid(of: window))
        var enhanced: CFTypeRef?
        let wasEnhanced = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &enhanced) == .success
            && (enhanced as? Bool) == true
        if wasEnhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer {
            if wasEnhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        }

        let sizeChanges = current.map { !$0.size.isClose(to: target.size) } ?? true
        let originChanges = current.map { !$0.origin.isClose(to: target.origin) } ?? true
        if sizeChanges { setSize(window, target.size) }
        if originChanges { setPosition(window, target.origin) }
        if sizeChanges && originChanges { setSize(window, target.size) }
    }

    static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var s = size
        if let value = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    static func setPosition(_ window: AXUIElement, _ point: CGPoint) {
        var p = point
        if let value = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    static func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

/// Hashable identity for an AX window, using CoreFoundation equality (two references to one window compare equal).
struct WindowKey: Hashable {
    let element: AXUIElement
    static func == (a: WindowKey, b: WindowKey) -> Bool { CFEqual(a.element, b.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

extension CGSize {
    func isClose(to o: CGSize, tolerance: CGFloat = 2) -> Bool {
        abs(width - o.width) <= tolerance && abs(height - o.height) <= tolerance
    }
}

extension CGRect {
    func isClose(to o: CGRect, tolerance: CGFloat = 2) -> Bool {
        origin.isClose(to: o.origin, tolerance: tolerance) && size.isClose(to: o.size, tolerance: tolerance)
    }
}

extension CGPoint {
    func isClose(to o: CGPoint, tolerance: CGFloat = 1) -> Bool {
        abs(x - o.x) <= tolerance && abs(y - o.y) <= tolerance
    }
}
