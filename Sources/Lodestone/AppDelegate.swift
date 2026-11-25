import AppKit
import Carbon.HIToolbox
import LodestoneCore
import ServiceManagement

private struct Shortcut {
    let action: SnapAction
    let keyCode: Int
    let modifiers: Int
    /// Shown in the menu only. Menu key equivalents of a status item never fire globally.
    let key: String
    let flags: NSEvent.ModifierFlags
}

private func arrow(_ c: Int) -> String { String(UnicodeScalar(UInt16(c)).map(Character.init) ?? " ") }

/// Magnet's default bindings, so muscle memory carries over.
private let shortcuts: [Shortcut] = {
    let co = controlKey | optionKey
    let coc = co | cmdKey
    let f: NSEvent.ModifierFlags = [.control, .option]
    let fc: NSEvent.ModifierFlags = [.control, .option, .command]
    return [
        Shortcut(action: .leftHalf, keyCode: kVK_LeftArrow, modifiers: co, key: arrow(NSLeftArrowFunctionKey), flags: f),
        Shortcut(action: .rightHalf, keyCode: kVK_RightArrow, modifiers: co, key: arrow(NSRightArrowFunctionKey), flags: f),
        Shortcut(action: .topHalf, keyCode: kVK_UpArrow, modifiers: co, key: arrow(NSUpArrowFunctionKey), flags: f),
        Shortcut(action: .bottomHalf, keyCode: kVK_DownArrow, modifiers: co, key: arrow(NSDownArrowFunctionKey), flags: f),
        Shortcut(action: .topLeft, keyCode: kVK_ANSI_U, modifiers: co, key: "u", flags: f),
        Shortcut(action: .topRight, keyCode: kVK_ANSI_I, modifiers: co, key: "i", flags: f),
        Shortcut(action: .bottomLeft, keyCode: kVK_ANSI_J, modifiers: co, key: "j", flags: f),
        Shortcut(action: .bottomRight, keyCode: kVK_ANSI_K, modifiers: co, key: "k", flags: f),
        Shortcut(action: .firstThird, keyCode: kVK_ANSI_D, modifiers: co, key: "d", flags: f),
        Shortcut(action: .centerThird, keyCode: kVK_ANSI_F, modifiers: co, key: "f", flags: f),
        Shortcut(action: .lastThird, keyCode: kVK_ANSI_G, modifiers: co, key: "g", flags: f),
        Shortcut(action: .firstTwoThirds, keyCode: kVK_ANSI_E, modifiers: co, key: "e", flags: f),
        Shortcut(action: .lastTwoThirds, keyCode: kVK_ANSI_T, modifiers: co, key: "t", flags: f),
        Shortcut(action: .maximize, keyCode: kVK_Return, modifiers: co, key: "\r", flags: f),
        Shortcut(action: .center, keyCode: kVK_ANSI_C, modifiers: co, key: "c", flags: f),
        Shortcut(action: .restore, keyCode: kVK_Delete, modifiers: co, key: "\u{8}", flags: f),
        Shortcut(action: .nextDisplay, keyCode: kVK_RightArrow, modifiers: coc, key: arrow(NSRightArrowFunctionKey), flags: fc),
        Shortcut(action: .previousDisplay, keyCode: kVK_LeftArrow, modifiers: coc, key: arrow(NSLeftArrowFunctionKey), flags: fc),
    ]
}()

/// Menu groups: halves, quarters, thirds, then whole-window actions.
private let menuGroups: [[SnapAction]] = [
    [.leftHalf, .rightHalf, .topHalf, .bottomHalf],
    [.topLeft, .topRight, .bottomLeft, .bottomRight],
    [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds],
    [.maximize, .center, .restore],
    [.nextDisplay, .previousDisplay],
]

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let windows = WindowManager()
    private let hotKeys = HotKeys()
    private lazy var drag = DragSnapper(windows: windows, layout: currentLayout())
    private var statusItem: NSStatusItem!
    private var trustTimer: Timer?
    private var failedShortcuts: [SnapAction] = []

    private let dragKey = "dragToSnap"
    private var dragEnabled: Bool {
        get { UserDefaults.standard.object(forKey: dragKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: dragKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AX.configure()
        registerShortcuts()
        buildStatusItem()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.drag.layout = self.currentLayout()
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            accessibilityGranted()
        } else {
            // Poll only until the user grants access, then never again.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.trustTimer = nil
                self?.accessibilityGranted()
            }
        }
    }

    private func accessibilityGranted() {
        if dragEnabled { drag.start() }
    }

    private func currentLayout() -> ScreenLayout {
        ScreenLayout(screens: NSScreen.screens.map { Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) })
    }

    private func registerShortcuts() {
        for s in shortcuts {
            let action = s.action
            if !hotKeys.register(keyCode: s.keyCode, modifiers: s.modifiers, { [weak self] in self?.perform(action) }) {
                failedShortcuts.append(action)
            }
        }
        if !failedShortcuts.isEmpty {
            NSLog("Lodestone: shortcuts already in use by another app: %@", failedShortcuts.map(\.title).joined(separator: ", "))
        }
    }

    private func perform(_ action: SnapAction) {
        guard AXIsProcessTrusted() else {
            promptForAccessibility()
            return
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        // Refresh on each command: visibleFrame changes when the Dock is moved or resized.
        let layout = currentLayout()
        drag.layout = layout
        windows.perform(action, pid: pid, layout: layout)
    }

    // MARK: Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "Lodestone")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let byAction = Dictionary(shortcuts.map { ($0.action, $0) }, uniquingKeysWith: { a, _ in a })
        for (i, group) in menuGroups.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            for action in group {
                let item = NSMenuItem(title: action.title, action: #selector(menuAction(_:)), keyEquivalent: byAction[action]?.key ?? "")
                item.keyEquivalentModifierMask = byAction[action]?.flags ?? []
                item.representedObject = action.rawValue
                item.target = self
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Snap by Dragging to Screen Edges", action: #selector(toggleDrag(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Grant Accessibility Access…", action: #selector(openAccessibility), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Lodestone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let trusted = AXIsProcessTrusted()
        for item in menu.items {
            switch item.action {
            case #selector(toggleDrag(_:)): item.state = dragEnabled ? .on : .off
            case #selector(toggleLogin(_:)): item.state = SMAppService.mainApp.status == .enabled ? .on : .off
            case #selector(openAccessibility): item.isHidden = trusted
            case #selector(menuAction(_:)):
                let failed = (item.representedObject as? String).flatMap(SnapAction.init(rawValue:)).map(failedShortcuts.contains) ?? false
                item.toolTip = failed ? "This shortcut is taken by another app (is Magnet still running?)" : nil
            default: break
            }
        }
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = SnapAction(rawValue: raw) else { return }
        perform(action)
    }

    @objc private func toggleDrag(_ sender: NSMenuItem) {
        dragEnabled.toggle()
        if dragEnabled && AXIsProcessTrusted() { drag.start() } else { drag.stop() }
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("Lodestone: launch at login failed: %@", error.localizedDescription)
        }
    }

    @objc private func openAccessibility() {
        promptForAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
