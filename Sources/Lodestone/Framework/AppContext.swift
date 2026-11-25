import AppKit
import ApplicationServices
import LodestoneCore
import LodestoneKit
import UserNotifications

/// Shared services handed to every feature.
@MainActor
final class AppContext {
    let shortcuts: ShortcutStore
    let settings: SettingsStore
    let activities = ActivityCenter()
    let log = Log.shared

    /// Every registered command by ID. Filled by the app delegate before features start.
    var commands: [String: AppCommand] = [:]
    /// Commands whose shortcut another app already owns.
    var unavailableShortcuts: Set<String> = []

    /// Set by the app delegate.
    var setShortcutsSuspendedHandler: ((Bool) -> Void)?
    var openSettingsHandler: ((String?) -> Void)?
    var rebuildShortcutsHandler: (() -> Void)?
    var fileActionsHandler: (([URL]) -> [FileAction])?

    /// Every feature's file actions that accept `urls` (what a drop on the menu bar icon offers).
    func fileActions(for urls: [URL]) -> [FileAction] { fileActionsHandler?(urls) ?? [] }

    init(shortcuts: ShortcutStore, settings: SettingsStore) {
        self.shortcuts = shortcuts
        self.settings = settings
    }

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Pauses global shortcuts (while a shortcut recorder is listening).
    func setShortcutsSuspended(_ suspended: Bool) { setShortcutsSuspendedHandler?(suspended) }

    /// Re-registers global shortcuts after a change and refreshes every shortcut control.
    func shortcutsChanged() {
        rebuildShortcutsHandler?()
        NotificationCenter.default.post(name: .lodestoneShortcutsChanged, object: nil)
    }

    /// Runs a command by ID. Returns false if there is no such command.
    @discardableResult
    func run(_ commandID: String) -> Bool {
        guard let command = commands[commandID] else { return false }
        log.info("command", "run", ["id": .string(commandID)])
        command.perform()
        return true
    }

    /// A menu item for a command, showing its current shortcut.
    func menuItem(_ commandID: String, title: String? = nil) -> NSMenuItem {
        let command = commands[commandID]
        let item = NSMenuItem(title: title ?? command?.title ?? commandID) { [weak self] in self?.run(commandID) }
        if let combo = shortcuts.combo(for: commandID) {
            item.keyEquivalent = KeyNames.menuKeyEquivalent(Int(combo.keyCode)) ?? ""
            item.keyEquivalentModifierMask = KeyNames.modifierFlags(combo.modifiers)
        }
        return item
    }

    /// Opens Settings, optionally on a feature's tab.
    func openSettings(tab featureID: String? = nil) { openSettingsHandler?(featureID) }

    /// Brings the app forward so a window it shows gets focus. The app still has no Dock icon.
    func activate() {
        NSApp.activate()
    }

    /// Sends ⌘V to the frontmost app, after the given delay (to let a panel close and focus return).
    /// Needs Accessibility access.
    func paste(after delay: TimeInterval = 0.05) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let vKey: CGKeyCode = 9 // kVK_ANSI_V
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Posts a user notification (asks for permission the first time).
    func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

extension Notification.Name {
    /// Posted after any setting changes. `userInfo["key"]` is the setting key.
    static let lodestoneSettingChanged = Notification.Name("lodestone.settingChanged")
    static let lodestoneShortcutsChanged = Notification.Name("lodestone.shortcutsChanged")
}

/// Long-running work (conversions, PDF compression) shown in the menu bar: the icon gets a
/// percentage, and the menu lists each activity with a Cancel item.
@MainActor
final class ActivityCenter {
    final class Activity {
        let id = UUID()
        var title: String
        /// 0...1, or nil when unknown.
        var progress: Double?
        var detail: String?
        let cancel: (() -> Void)?

        init(title: String, cancel: (() -> Void)?) {
            self.title = title
            self.cancel = cancel
        }
    }

    private(set) var activities: [Activity] = []
    /// Called whenever an activity starts, changes or ends. The app delegate redraws the status item.
    var onChange: (() -> Void)?

    @discardableResult
    func begin(_ title: String, cancel: (() -> Void)? = nil) -> Activity {
        let activity = Activity(title: title, cancel: cancel)
        activities.append(activity)
        onChange?()
        return activity
    }

    func update(_ activity: Activity, progress: Double?, detail: String? = nil) {
        activity.progress = progress
        if let detail { activity.detail = detail }
        onChange?()
    }

    func end(_ activity: Activity) {
        activities.removeAll { $0.id == activity.id }
        onChange?()
    }

    /// Average progress of all activities with known progress, for the menu bar label.
    var overallProgress: Double? {
        let known = activities.compactMap(\.progress)
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +) / Double(known.count)
    }
}
