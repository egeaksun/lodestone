import AppKit
import LodestoneCore
import LodestoneKit

/// The drop shelf: shake files while dragging them and a drop target appears next to the pointer,
/// so files reach Lodestone's actions without the menu bar (which may be hidden).
///
/// Idle cost: passive global monitors for mouse down and up (they see clicks, nothing else). The
/// dragged-event monitor exists only while the button is down, and each event only feeds the shake
/// detector's arithmetic. The drag pasteboard is read once, after a shake.
@MainActor
final class DropShelfFeature: Feature {
    let id = "shelf"
    let title = "Drop Shelf"
    let symbol = "tray.and.arrow.down"

    static let enabledKey = "shelf.enabled"
    static let showID = "shelf.show"

    private var context: AppContext!
    /// Created the first time it's shown.
    private var panel: DropShelfPanel?
    private var shelf: DropShelfPanel {
        if let panel { return panel }
        let made = makeShelf()
        panel = made
        return made
    }
    private var downMonitor: Any?
    private var upMonitor: Any?
    private var dragMonitor: Any?
    private var detector = ShakeDetector()
    private var shownThisGesture = false
    /// The drag pasteboard's change count when the shelf last appeared, so one drag shows it once.
    private var lastDragChange = -1

    var settings: [SettingDefinition] {
        [SettingDefinition(Self.enabledKey, title: "Show the drop shelf when you shake files while dragging", kind: .bool, default: true)]
    }

    var commands: [AppCommand] {
        [AppCommand(Self.showID, "Show Drop Shelf") { [weak self] in self?.showForCommand() }]
    }

    func start(_ context: AppContext) {
        self.context = context
        update()
    }

    func settingChanged(_ key: String) {
        if key == Self.enabledKey { update() }
    }

    private func update() {
        if context.settings.bool(Self.enabledKey) { startMonitoring() } else { stopMonitoring() }
    }

    // MARK: Gesture

    private func startMonitoring() {
        guard downMonitor == nil else { return }
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }
        Log.shared.info(id, "monitor.start")
    }

    private func stopMonitoring() {
        guard downMonitor != nil else { return }
        for m in [downMonitor, upMonitor, dragMonitor] { if let m { NSEvent.removeMonitor(m) } }
        downMonitor = nil
        upMonitor = nil
        dragMonitor = nil
        panel?.hide()
        Log.shared.info(id, "monitor.stop")
    }

    private func mouseDown() {
        // A click elsewhere dismisses a shelf that's showing actions.
        if let panel, panel.isVisible, !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) { panel.hide() }
        detector.reset()
        shownThisGesture = false
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            MainActor.assumeIsolated { self?.dragged(event) }
        }
    }

    /// Hot path: arithmetic only until a shake is recognized.
    private func dragged(_ event: NSEvent) {
        guard !shownThisGesture else { return }
        // Global monitor events carry screen coordinates.
        let x = Double(event.locationInWindow.x)
        guard detector.add(x: x, time: event.timestamp) else { return }
        shownThisGesture = true
        shake()
    }

    private func mouseUp() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        // The drop (if any) lands around mouse-up; an untouched shelf goes away once the drag is over.
        guard let panel, panel.state == .waiting, shownThisGesture else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, panel.state == .waiting, NSEvent.pressedMouseButtons & 1 == 0 else { return }
            panel.hide()
            Log.shared.debug(self.id, "dismissed")
        }
    }

    private func shake() {
        let pasteboard = NSPasteboard(name: .drag)
        let change = pasteboard.changeCount
        guard change != lastDragChange,
              pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        lastDragChange = change
        shelf.showWaiting(near: NSEvent.mouseLocation)
        Log.shared.info(id, "show", ["via": "shake"])
    }

    private func showForCommand() {
        shelf.showWaiting(near: NSEvent.mouseLocation, key: true)
        Log.shared.info(id, "show", ["via": "command"])
    }

    private func makeShelf() -> DropShelfPanel {
        let shelf = DropShelfPanel()
        shelf.actionsFor = { [weak self] urls in self?.context.fileActions(for: urls) ?? [] }
        shelf.onDrop = { [weak self] urls, actions in
            Log.shared.info(self?.id ?? "shelf", "drop", ["count": .number(Double(urls.count)),
                                                          "actions": .array(actions.map { .string($0.id) })])
        }
        shelf.onPick = { [weak self] action, urls in
            Log.shared.info(self?.id ?? "shelf", "action", ["action": .string(action.id), "count": .number(Double(urls.count))])
            action.perform(urls)
        }
        return shelf
    }

    // MARK: Settings

    func makeSettingsView() -> NSView? {
        SettingsUI.stack([
            SettingsUI.checkbox(context, Self.enabledKey),
            SettingsUI.note("Start dragging files from Finder or anywhere else, then shake the pointer left and right a few times. A drop target appears next to the pointer; drop the files on it to see what Lodestone can do with them: convert, compress, merge PDFs, remove a background, and so on. It works with the menu bar hidden."),
            SettingsUI.note("Dropping files on the menu bar icon still works, and so does Finder's right-click menu: Quick Actions or Services → Lodestone Actions…"),
            SettingsUI.separator(),
            SettingsUI.header("Shortcut"),
            SettingsUI.note("Opens the drop shelf at the pointer without a drag, for when you'd rather bring the files to it."),
            SettingsUI.shortcutGrid(context, groups: [[Self.showID]]),
        ], spacing: 10)
    }
}
