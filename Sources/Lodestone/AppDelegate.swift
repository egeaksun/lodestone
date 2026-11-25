import AppKit
import LodestoneCore
import LodestoneKit
import ServiceManagement

/// Wires features into the app: shortcuts, the menu bar menu, Settings, file drops, Finder services
/// and the IPC server the CLI talks to. Feature-specific behavior lives in the features.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let features: [Feature] = FeatureRegistry.make()
    private let shortcuts = ShortcutStore()
    private let settingsStore = SettingsStore()
    private lazy var context = AppContext(shortcuts: shortcuts, settings: settingsStore)
    private let router = IPCRouter()
    private var ipcServer: IPCServer?
    private let hotKeys = HotKeys()
    private var statusItem: NSStatusItem!
    private var dropTarget: StatusItemDropTarget?
    private var settingsWindow: SettingsWindowController?
    private var general: GeneralSettings?
    private var trustTimer: Timer?

    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.shared.process = "app"
        Log.shared.info("app", "launch", ["version": .string(Self.version), "accessibility": .bool(AXIsProcessTrusted())])

        for feature in features {
            settingsStore.register(feature.settings)
            for command in feature.commands {
                context.commands[command.id] = command
                shortcuts.register(command.id, default: command.defaultShortcut)
            }
            feature.registerIPC(router)
        }
        registerBuiltInIPC()

        settingsStore.onChange = { [weak self] key in
            NotificationCenter.default.post(name: .lodestoneSettingChanged, object: nil, userInfo: ["key": key])
            self?.features.forEach { $0.settingChanged(key) }
        }
        context.setShortcutsSuspendedHandler = { [weak self] suspended in
            if suspended { self?.hotKeys.unregisterAll() } else { self?.applyShortcuts() }
        }
        context.rebuildShortcutsHandler = { [weak self] in self?.applyShortcuts() }
        context.openSettingsHandler = { [weak self] tab in self?.openSettings(tab: tab) }
        context.fileActionsHandler = { [weak self] urls in self?.fileActions(for: urls) ?? [] }
        context.activities.onChange = { [weak self] in self?.updateStatusItem() }

        buildMainMenu()
        buildStatusItem()
        applyShortcuts()
        features.forEach { $0.start(context) }
        startIPC()

        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        watchAccessibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipcServer?.stop()
        Log.shared.info("app", "quit")
        Log.shared.flush()
    }

    /// Opening the app again from Finder or Spotlight while it runs shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(tab: nil)
        return false
    }

    private func watchAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { return }
        Log.shared.warn("app", "accessibility.missing")
        // Poll only until access is granted, then never again.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            MainActor.assumeIsolated {
                self?.trustTimer = nil
                Log.shared.info("app", "accessibility.granted")
                self?.features.forEach { $0.accessibilityChanged(trusted: true) }
            }
        }
    }

    // MARK: Shortcuts

    private func applyShortcuts() {
        hotKeys.unregisterAll()
        var unavailable: Set<String> = []
        for id in shortcuts.ids {
            guard let combo = shortcuts.combo(for: id), context.commands[id] != nil else { continue }
            let ok = hotKeys.register(keyCode: Int(combo.keyCode), modifiers: Int(combo.modifiers)) { [weak self] in
                MainActor.assumeIsolated { _ = self?.context.commands[id]?.perform() }
            }
            if !ok { unavailable.insert(id) }
        }
        if !unavailable.isEmpty && unavailable != context.unavailableShortcuts {
            Log.shared.warn("shortcuts", "register.failed", ["ids": .array(unavailable.sorted().map { .string($0) })])
        }
        context.unavailableShortcuts = unavailable
    }

    // MARK: IPC

    private func startIPC() {
        let router = self.router
        let server = IPCServer { request in
            await router.handle(request)
        }
        do {
            try server.start()
            ipcServer = server
        } catch {
            Log.shared.error("ipc", "start.failed", .error(error))
        }
    }

    private struct KeyParams: Decodable { var key: String }
    private struct SetParams: Decodable { var key: String; var value: JSONValue }
    private struct IDParams: Decodable { var id: String }
    private struct ShortcutParams: Decodable { var id: String; var shortcut: String? }
    private struct FilesParams: Decodable { var paths: [String]; var action: String? }
    private struct LoginParams: Decodable { var enabled: Bool? }
    private struct OpenParams: Decodable { var id: String? }

    private func registerBuiltInIPC() {
        router.register("app.status", summary: "Version, permissions, features and file locations", NoParams.self) { [weak self] _ -> JSONValue in
            [
                "version": .string(Self.version),
                "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                "accessibility": .bool(AXIsProcessTrusted()),
                "screenRecording": .bool(CGPreflightScreenCaptureAccess()),
                "launchAtLogin": .bool(SMAppService.mainApp.status == .enabled),
                "features": .array((self?.features ?? []).map { .string($0.id) }),
                "logs": .string(Paths.logs.path),
                "logRetentionDays": .number(Double(Log.retentionDays)),
                "socket": .string(Paths.socket.path),
                "activities": .array((self?.context.activities.activities ?? []).map {
                    ["title": .string($0.title), "progress": $0.progress.map { .number($0) } ?? .null]
                }),
            ]
        }

        router.register("methods", summary: "Every IPC method with its parameters", NoParams.self) { [weak self] _ -> JSONValue in
            .array((self?.router.methods.values.sorted { $0.name < $1.name } ?? []).map {
                ["method": .string($0.name), "summary": .string($0.summary), "params": .string($0.params)]
            })
        }

        router.register("commands.list", summary: "Commands that can be bound to shortcuts or run", NoParams.self) { [weak self] _ -> JSONValue in
            guard let self else { return [] }
            return .array(self.shortcuts.ids.compactMap { id -> JSONValue? in
                guard let command = self.context.commands[id] else { return nil }
                return ["id": .string(id), "title": .string(command.title),
                        "shortcut": self.shortcuts.combo(for: id).map { .string(KeyComboText.format($0)) } ?? .null]
            })
        }

        router.register("commands.run", summary: "Run a command as if its shortcut was pressed", params: #"{"id": string}"#, IDParams.self) { [weak self] p in
            guard self?.context.run(p.id) == true else { throw IPCError.notFound("Unknown command '\(p.id)'. Run `lodestone commands`.") }
            return OK()
        }

        router.register("settings.list", summary: "All settings with current values", NoParams.self) { [weak self] _ -> JSONValue in
            guard let self else { return [] }
            return .array(self.settingsStore.definitions.map {
                ["key": .string($0.key), "title": .string($0.title), "type": .string($0.kindDescription),
                 "value": self.settingsStore.value($0.key), "default": $0.defaultValue, "help": .string($0.help)]
            })
        }
        router.register("settings.get", summary: "One setting's value", params: #"{"key": string}"#, KeyParams.self) { [weak self] p -> JSONValue in
            guard let self, self.settingsStore.definition(p.key) != nil else { throw IPCError.notFound("Unknown setting '\(p.key)'") }
            return self.settingsStore.value(p.key)
        }
        router.register("settings.set", summary: "Change a setting", params: #"{"key": string, "value": any}"#, SetParams.self) { [weak self] p -> JSONValue in
            guard let self else { throw IPCError.failed("Unavailable") }
            try self.settingsStore.set(p.key, p.value)
            return self.settingsStore.value(p.key)
        }
        router.register("settings.reset", summary: "Reset a setting to its default", params: #"{"key": string}"#, KeyParams.self) { [weak self] p -> JSONValue in
            guard let self else { throw IPCError.failed("Unavailable") }
            try self.settingsStore.reset(p.key)
            return self.settingsStore.value(p.key)
        }

        router.register("shortcuts.list", summary: "Every command's shortcut", NoParams.self) { [weak self] _ -> JSONValue in
            guard let self else { return [] }
            return .array(self.shortcuts.ids.compactMap { id -> JSONValue? in
                guard let command = self.context.commands[id] else { return nil }
                return ["id": .string(id), "title": .string(command.title),
                        "shortcut": self.shortcuts.combo(for: id).map { .string(KeyComboText.format($0)) } ?? .null,
                        "default": self.shortcuts.defaults[id].map { .string(KeyComboText.format($0)) } ?? .null,
                        "available": .bool(!self.context.unavailableShortcuts.contains(id))]
            })
        }
        router.register("shortcuts.set", summary: "Set or clear a command's shortcut",
                        params: #"{"id": string, "shortcut": "ctrl+opt+left" | null}"#, ShortcutParams.self) { [weak self] p -> JSONValue in
            guard let self else { throw IPCError.failed("Unavailable") }
            guard self.context.commands[p.id] != nil else { throw IPCError.notFound("Unknown command '\(p.id)'") }
            let combo = try p.shortcut.map(KeyComboText.parse)
            let previousOwner = combo.flatMap { self.shortcuts.id(for: $0) }
            self.shortcuts.set(combo, for: p.id)
            Log.shared.info("shortcuts", "set", ["id": .string(p.id), "shortcut": p.shortcut.map { .string($0) } ?? .null, "via": "ipc"])
            self.context.shortcutsChanged()
            return ["id": .string(p.id), "shortcut": combo.map { .string(KeyComboText.format($0)) } ?? .null,
                    "takenFrom": previousOwner.flatMap { $0 == p.id ? nil : .string($0) } ?? .null,
                    "available": .bool(!self.context.unavailableShortcuts.contains(p.id))]
        }
        router.register("shortcuts.reset", summary: "Reset every shortcut to its default", NoParams.self) { [weak self] _ in
            self?.shortcuts.resetToDefaults()
            Log.shared.info("shortcuts", "reset", ["feature": "all"])
            self?.context.shortcutsChanged()
            return OK()
        }

        router.register("files.actions", summary: "Actions available for files (what a drop on the menu bar icon offers)",
                        params: #"{"paths": [string]}"#, FilesParams.self) { [weak self] p -> JSONValue in
            let urls = p.paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            return .array((self?.fileActions(for: urls) ?? []).map { ["id": .string($0.id), "title": .string($0.title)] })
        }
        router.register("files.run", summary: "Run a file action (opens its UI, like a drop would)",
                        params: #"{"action": string, "paths": [string]}"#, FilesParams.self) { [weak self] p in
            guard let self else { throw IPCError.failed("Unavailable") }
            let urls = p.paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            guard let action = self.fileActions(for: urls).first(where: { $0.id == p.action }) else {
                throw IPCError.notFound("No action '\(p.action ?? "")' for these files. Run `lodestone files actions`.")
            }
            Log.shared.info("files", "action", ["action": .string(action.id), "count": .number(Double(urls.count)), "via": "ipc"])
            action.perform(urls)
            return OK()
        }

        router.register("app.launchAtLogin", summary: "Get, or set with {enabled}, whether Lodestone starts at login",
                        params: #"{"enabled"?: bool}"#, LoginParams.self) { p -> JSONValue in
            if let enabled = p.enabled {
                do {
                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    Log.shared.info("app", "launchAtLogin", ["enabled": .bool(enabled)])
                } catch {
                    throw IPCError.failed("Couldn't change launch at login: \(error.localizedDescription)")
                }
            }
            return .bool(SMAppService.mainApp.status == .enabled)
        }

        router.register("settings.open", summary: "Open the Settings window, optionally on a feature's tab",
                        params: #"{"id"?: feature id}"#, OpenParams.self) { [weak self] p in
            self?.openSettings(tab: p.id)
            return OK()
        }
    }

    // MARK: Files (drop on the menu bar icon, Finder services)

    func fileActions(for urls: [URL]) -> [FileAction] {
        guard !urls.isEmpty else { return [] }
        return features.flatMap(\.fileActions).filter { $0.accepts(urls) }
    }

    /// Runs the only matching action, or offers a menu of them at `point` (screen coordinates).
    func handleFiles(_ urls: [URL], at point: NSPoint, source: String) {
        let actions = fileActions(for: urls)
        Log.shared.info("files", "received", ["count": .number(Double(urls.count)), "source": .string(source),
                                              "actions": .array(actions.map { .string($0.id) })])
        switch actions.count {
        case 0:
            NSSound.beep()
        case 1:
            actions[0].perform(urls)
        default:
            let menu = NSMenu()
            for action in actions {
                menu.addItem(NSMenuItem(title: action.title) {
                    Log.shared.info("files", "action", ["action": .string(action.id), "count": .number(Double(urls.count))])
                    action.perform(urls)
                })
            }
            NSApp.activate()
            menu.popUp(positioning: nil, at: point, in: nil)
        }
    }

    /// NSServices entry point (Info.plist, NSMessage "handleFiles"). NSUserData is a file action ID,
    /// or "actions" to offer every matching action.
    @objc func handleFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if let id = userData, id != "actions" {
            if let action = fileActions(for: urls).first(where: { $0.id == id }) {
                Log.shared.info("files", "action", ["action": .string(id), "count": .number(Double(urls.count)), "source": "service"])
                NSApp.activate()
                action.perform(urls)
            } else {
                Log.shared.warn("files", "service.no_action", ["action": .string(id)])
                NSSound.beep()
            }
            return
        }
        handleFiles(urls, at: NSEvent.mouseLocation, source: "service")
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "Lodestone")
        image?.isTemplate = true
        image?.accessibilityDescription = "Lodestone"
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        if let button = statusItem.button {
            dropTarget = StatusItemDropTarget(button: button) { [weak self] urls in
                guard let self, let window = button.window else { return }
                let point = window.convertPoint(toScreen: NSPoint(x: button.frame.minX, y: button.frame.minY))
                self.handleFiles(urls, at: point, source: "drop")
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let activities = context.activities.activities
        if activities.isEmpty {
            button.title = ""
        } else if let progress = context.activities.overallProgress {
            button.attributedTitle = NSAttributedString(string: " \(Int(progress * 100))%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            ])
        } else {
            button.title = " …"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for activity in context.activities.activities {
            var title = activity.title
            if let p = activity.progress { title += " — \(Int(p * 100))%" }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            if let detail = activity.detail {
                let d = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
                d.isEnabled = false
                d.indentationLevel = 1
                menu.addItem(d)
            }
            if let cancel = activity.cancel {
                let c = NSMenuItem(title: "Cancel") { cancel() }
                c.indentationLevel = 1
                menu.addItem(c)
            }
            menu.addItem(.separator())
        }
        for feature in features {
            let items = feature.menuItems()
            guard !items.isEmpty else { continue }
            if menu.items.last.map({ !$0.isSeparatorItem }) == true { menu.addItem(.separator()) }
            items.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        if !AXIsProcessTrusted() {
            menu.addItem(NSMenuItem(title: "Grant Accessibility Access…") { GeneralSettings.openAccessibilitySettings() })
        }
        let settings = NSMenuItem(title: "Settings…", keyEquivalent: ",") { [weak self] in self?.openSettings(tab: nil) }
        menu.addItem(settings)
        menu.addItem(withTitle: "Quit Lodestone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// Never shown (no Dock icon, no menu bar menus), but supplies ⌘W, ⌘Q and editing shortcuts
    /// (copy, paste, select all) to Lodestone's windows.
    private func buildMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Settings…", keyEquivalent: ",") { [weak self] in self?.openSettings(tab: nil) })
        appMenu.addItem(withTitle: "Quit Lodestone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let main = NSMenu()
        for (title, submenu) in [("Lodestone", appMenu), ("Edit", edit), ("Window", window)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    private func openSettings(tab: String?) {
        if settingsWindow == nil {
            let general = GeneralSettings(context: context)
            self.general = general
            settingsWindow = SettingsWindowController(general: general.makeView(), features: features) { [weak self] in
                self?.general?.refresh()
            }
        }
        settingsWindow?.show(tab: tab)
    }
}

/// Accepts files dragged onto the menu bar icon. The status bar window forwards dragging to its
/// delegate, so this registers on the button's window.
@MainActor
final class StatusItemDropTarget: NSObject, NSWindowDelegate, NSDraggingDestination {
    private let onDrop: ([URL]) -> Void

    init(button: NSStatusBarButton, onDrop: @escaping ([URL]) -> Void) {
        self.onDrop = onDrop
        super.init()
        button.window?.registerForDraggedTypes([.fileURL])
        button.window?.delegate = self
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async { self.onDrop(urls) }
        return true
    }
}
