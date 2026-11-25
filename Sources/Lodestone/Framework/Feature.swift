import AppKit
import LodestoneCore
import LodestoneKit

/// An action users can run from a global shortcut, the menu bar, or `lodestone run <id>`.
struct AppCommand {
    /// Snap actions use their raw value ("leftHalf"); other features use "<feature>.<name>".
    let id: String
    let title: String
    let defaultShortcut: KeyCombo?
    /// Runs on the main thread. Long work must hop to a background queue.
    let perform: @MainActor () -> Void

    init(_ id: String, _ title: String, shortcut: KeyCombo? = nil, perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.defaultShortcut = shortcut
        self.perform = perform
    }
}

/// Something that can be done with files dropped on the menu bar icon or sent from Finder
/// (right-click → Services). The app shows every action whose `accepts` returns true.
struct FileAction {
    /// Also the NSUserData of a Finder service entry in Info.plist that runs this action directly.
    let id: String
    let title: String
    let accepts: ([URL]) -> Bool
    let perform: @MainActor ([URL]) -> Void
}

/// One self-contained piece of functionality: snapping, the converter, clipboard history, ...
///
/// Features plug into the app through this protocol and the shared `AppContext`; the app delegate
/// knows nothing about individual features beyond the list in `FeatureRegistry`. A feature must
/// cost nothing while idle: install monitors and timers only while enabled, never poll on a hot path.
@MainActor
protocol Feature: AnyObject {
    /// Stable identifier, also the prefix of its command, setting and IPC names ("clipboard").
    var id: String { get }
    var title: String { get }
    /// SF Symbol for the Settings tab.
    var symbol: String { get }

    var commands: [AppCommand] { get }
    var settings: [SettingDefinition] { get }
    var fileActions: [FileAction] { get }

    /// Called once after launch, after commands, settings and IPC methods are registered.
    func start(_ context: AppContext)
    /// Items for this feature's section of the menu bar menu. Rebuilt every time the menu opens.
    func menuItems() -> [NSMenuItem]
    /// Content of this feature's Settings tab, or nil for none. Called when the window is first built.
    func makeSettingsView() -> NSView?
    func registerIPC(_ router: IPCRouter)
    func accessibilityChanged(trusted: Bool)
    func settingChanged(_ key: String)
}

extension Feature {
    var commands: [AppCommand] { [] }
    var settings: [SettingDefinition] { [] }
    var fileActions: [FileAction] { [] }
    func start(_ context: AppContext) {}
    func menuItems() -> [NSMenuItem] { [] }
    func makeSettingsView() -> NSView? { nil }
    func registerIPC(_ router: IPCRouter) {}
    func accessibilityChanged(trusted: Bool) {}
    func settingChanged(_ key: String) {}
}

extension NSMenuItem {
    /// A menu item that runs a closure. Retains the closure for the item's lifetime.
    convenience init(title: String, keyEquivalent: String = "", action: @escaping @MainActor () -> Void) {
        self.init(title: title, action: #selector(ClosureTarget.invoke), keyEquivalent: keyEquivalent)
        let target = ClosureTarget(action)
        self.target = target
        representedObject = target
    }

    /// A submenu item.
    convenience init(title: String, submenu items: [NSMenuItem]) {
        self.init(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        submenu = menu
    }
}

final class ClosureTarget: NSObject {
    private let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @MainActor @objc func invoke() { action() }
}
