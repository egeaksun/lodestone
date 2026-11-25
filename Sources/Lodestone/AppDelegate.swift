import AppKit
import Carbon.HIToolbox
import LodestoneCore

/// Default shortcuts: the Magnet setup this app replaces (Magnet's defaults plus ⌃⌥1–6 for sixths).
private let defaultShortcuts: [SnapAction: KeyCombo] = {
    let co = UInt32(controlKey | optionKey)
    let coc = co | UInt32(cmdKey)
    func k(_ code: Int, _ mods: UInt32 = co) -> KeyCombo { KeyCombo(keyCode: UInt32(code), modifiers: mods) }
    return [
        .leftHalf: k(kVK_LeftArrow), .rightHalf: k(kVK_RightArrow), .topHalf: k(kVK_UpArrow), .bottomHalf: k(kVK_DownArrow),
        .topLeft: k(kVK_ANSI_U), .topRight: k(kVK_ANSI_I), .bottomLeft: k(kVK_ANSI_J), .bottomRight: k(kVK_ANSI_K),
        .firstThird: k(kVK_ANSI_D), .centerThird: k(kVK_ANSI_F), .lastThird: k(kVK_ANSI_G),
        .firstTwoThirds: k(kVK_ANSI_E), .centerTwoThirds: k(kVK_ANSI_R), .lastTwoThirds: k(kVK_ANSI_T),
        .sixth1: k(kVK_ANSI_1), .sixth2: k(kVK_ANSI_2), .sixth3: k(kVK_ANSI_3),
        .sixth4: k(kVK_ANSI_4), .sixth5: k(kVK_ANSI_5), .sixth6: k(kVK_ANSI_6),
        .maximize: k(kVK_Return), .center: k(kVK_ANSI_C), .restore: k(kVK_Delete),
        .nextDisplay: k(kVK_RightArrow, coc), .previousDisplay: k(kVK_LeftArrow, coc),
    ]
}()

/// Menu groups: sixths, halves, quarters, thirds, then whole-window actions.
private let menuGroups: [[SnapAction]] = [
    [.sixth1, .sixth2, .sixth3, .sixth4, .sixth5, .sixth6],
    [.leftHalf, .rightHalf, .topHalf, .bottomHalf],
    [.topLeft, .topRight, .bottomLeft, .bottomRight],
    [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .centerTwoThirds, .lastTwoThirds],
    [.maximize, .center, .restore],
    [.nextDisplay, .previousDisplay],
]

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SettingsHost {
    let shortcuts = ShortcutStore(defaults: defaultShortcuts)
    private(set) var unavailableShortcuts: Set<SnapAction> = []

    private let windows = WindowManager()
    private let hotKeys = HotKeys()
    private lazy var drag = DragSnapper(windows: windows, layout: currentLayout())
    private var statusItem: NSStatusItem!
    private var actionItems: [SnapAction: NSMenuItem] = [:]
    private var settings: SettingsWindowController?
    private var trustTimer: Timer?

    private let dragKey = "dragToSnap"
    var dragEnabled: Bool {
        get { UserDefaults.standard.object(forKey: dragKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: dragKey)
            if newValue && AXIsProcessTrusted() { drag.start() } else { drag.stop() }
        }
    }

    private let cycleKey = "cycleDisplays"
    var cycleDisplays: Bool {
        get { UserDefaults.standard.object(forKey: cycleKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: cycleKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AX.configure()
        buildMainMenu()
        buildStatusItem()
        applyShortcuts()

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

    /// Opening the app again from Finder or Spotlight while it runs shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    private func accessibilityGranted() {
        if dragEnabled { drag.start() }
        settings?.refresh()
    }

    private func currentLayout() -> ScreenLayout {
        ScreenLayout(screens: NSScreen.screens.map { Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) })
    }

    // MARK: Shortcuts

    private func applyShortcuts() {
        hotKeys.unregisterAll()
        unavailableShortcuts = []
        for action in SnapAction.allCases {
            guard let combo = shortcuts.combo(for: action) else { continue }
            let ok = hotKeys.register(keyCode: Int(combo.keyCode), modifiers: Int(combo.modifiers)) { [weak self] in
                self?.perform(action)
            }
            if !ok { unavailableShortcuts.insert(action) }
        }
        for (action, item) in actionItems {
            let combo = shortcuts.combo(for: action)
            item.keyEquivalent = combo.flatMap { KeyNames.menuKeyEquivalent(Int($0.keyCode)) } ?? ""
            item.keyEquivalentModifierMask = combo.map { KeyNames.modifierFlags($0.modifiers) } ?? []
        }
    }

    func shortcutsChanged() {
        applyShortcuts()
        settings?.refresh()
    }

    func setShortcutsSuspended(_ suspended: Bool) {
        if suspended {
            hotKeys.unregisterAll()
        } else {
            shortcutsChanged()
        }
    }

    private func perform(_ action: SnapAction) {
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        // Refresh on each command: visibleFrame changes when the Dock is moved or resized.
        let layout = currentLayout()
        drag.layout = layout
        windows.perform(action, pid: pid, layout: layout, cycleDisplays: cycleDisplays)
    }

    // MARK: Menu

    /// Never shown (the app has no Dock icon or menu bar menus), but supplies ⌘W, ⌘Q and the editing
    /// shortcuts while the Settings window is focused.
    private func buildMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Quit Lodestone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let main = NSMenu()
        for (title, submenu) in [("Lodestone", appMenu), ("Window", windowMenu)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "Lodestone")
        image?.isTemplate = true
        image?.accessibilityDescription = "Lodestone"
        statusItem.button?.image = image

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        for (i, group) in menuGroups.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            for action in group {
                let item = NSMenuItem(title: action.title, action: #selector(menuAction(_:)), keyEquivalent: "")
                item.representedObject = action.rawValue
                item.target = self
                actionItems[action] = item
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Grant Accessibility Access…", action: #selector(openAccessibility), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Lodestone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let trusted = AXIsProcessTrusted()
        for item in menu.items where item.action == #selector(openAccessibility) {
            item.isHidden = trusted
        }
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = SnapAction(rawValue: raw) else { return }
        perform(action)
    }

    @objc private func openSettings() {
        if settings == nil { settings = SettingsWindowController(host: self) }
        settings?.show()
    }

    @objc private func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
