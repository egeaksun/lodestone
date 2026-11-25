import AppKit
import Carbon.HIToolbox
import LodestoneCore
import LodestoneKit

/// Window snapping: shortcuts, drag-to-edge, moving windows across displays, and the window commands
/// of the CLI (`lodestone window ...`).
@MainActor
final class SnappingFeature: Feature {
    let id = "snapping"
    let title = "Snapping"
    let symbol = "rectangle.split.2x2"

    static let dragKey = "snapping.dragToSnap"
    static let cycleKey = "snapping.cycleDisplays"

    private let windows = WindowManager()
    private lazy var drag = DragSnapper(windows: windows, layout: currentLayout())
    private var context: AppContext!

    /// The Magnet setup this app replaced (Magnet's defaults plus ⌃⌥1–6 for sixths).
    private static let defaultShortcuts: [SnapAction: KeyCombo] = {
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

    private static let groups: [(String, [[SnapAction]])] = [
        ("Halves & Quarters", [[.leftHalf, .rightHalf, .topHalf, .bottomHalf], [.topLeft, .topRight, .bottomLeft, .bottomRight]]),
        ("Thirds", [[.firstThird, .centerThird, .lastThird], [.firstTwoThirds, .centerTwoThirds, .lastTwoThirds]]),
        ("Sixths", [[.sixth1, .sixth2, .sixth3, .sixth4, .sixth5, .sixth6]]),
        ("Window", [[.maximize, .center, .restore], [.nextDisplay, .previousDisplay]]),
    ]

    var settings: [SettingDefinition] {
        [
            SettingDefinition(Self.dragKey, title: "Snap windows by dragging them to screen edges", kind: .bool, default: true),
            SettingDefinition(Self.cycleKey, title: "Press a shortcut again to move the window to the next display", kind: .bool, default: true,
                              help: "Left-side positions move left; right-side and centered positions move right, wrapping around."),
        ]
    }

    var commands: [AppCommand] {
        SnapAction.allCases.map { action in
            AppCommand(action.rawValue, action.title, shortcut: Self.defaultShortcuts[action]) { [weak self] in
                self?.perform(action)
            }
        }
    }

    func start(_ context: AppContext) {
        self.context = context
        context.settings.migrate(from: "dragToSnap", to: Self.dragKey)
        context.settings.migrate(from: "cycleDisplays", to: Self.cycleKey)
        AX.configure()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.drag.layout = self.currentLayout()
                Log.shared.info("window", "displays.changed", ["count": .number(Double(NSScreen.screens.count))])
            }
        }
        updateDrag()
    }

    func accessibilityChanged(trusted: Bool) { updateDrag() }

    func settingChanged(_ key: String) {
        if key == Self.dragKey { updateDrag() }
    }

    private func updateDrag() {
        if context.settings.bool(Self.dragKey) && context.isAccessibilityTrusted { drag.start() } else { drag.stop() }
    }

    private func currentLayout() -> ScreenLayout {
        ScreenLayout(screens: NSScreen.screens.map { Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) })
    }

    static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { RunningApp(pid: $0.processIdentifier, name: $0.localizedName ?? "pid \($0.processIdentifier)",
                              bundleID: $0.bundleIdentifier, isActive: $0.isActive) }
    }

    private var promptedForAccessibility = false

    /// Shortcut and menu entry point: acts on the frontmost app's focused window.
    private func perform(_ action: SnapAction) {
        guard context.isAccessibilityTrusted else {
            Log.shared.warn("window", "snap.no_accessibility", ["action": .string(action.rawValue)])
            // The system dialog once per launch; after that a beep, so a held-down habit doesn't stack
            // dialogs. The menu keeps a "Grant Accessibility Access…" item until access is granted.
            if promptedForAccessibility {
                NSSound.beep()
            } else {
                promptedForAccessibility = true
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        // Refresh on each command: visibleFrame changes when the Dock is moved or resized.
        let layout = currentLayout()
        drag.layout = layout
        let apps = [RunningApp(pid: front.processIdentifier, name: front.localizedName ?? "?", bundleID: front.bundleIdentifier, isActive: true)]
        windows.perform(action, target: .focused(front.processIdentifier), apps: apps, layout: layout,
                        cycleDisplays: context.settings.bool(Self.cycleKey)) { result in
            switch result {
            case .success(let info):
                Log.shared.info("window", "snap", ["action": .string(action.rawValue), "app": .string(info.app), "display": .number(Double(info.display))])
            case .failure(let error):
                Log.shared.warn("window", "snap.failed", ["action": .string(action.rawValue), "app": .string(front.localizedName ?? "?"), "error": .string(error.message)])
            }
        }
    }

    // MARK: Menu & Settings

    func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for (i, (_, groups)) in Self.groups.enumerated() {
            if i > 0 { items.append(.separator()) }
            for group in groups { items.append(contentsOf: group.map { context.menuItem($0.rawValue) }) }
        }
        return [NSMenuItem(title: "Snap Window", submenu: items)]
    }

    func makeSettingsView() -> NSView? {
        let tabs = NSTabView()
        for (title, groups) in Self.groups {
            let item = NSTabViewItem()
            item.label = title
            let grid = SettingsUI.shortcutGrid(context, groups: groups.map { $0.map(\.rawValue) })
            let container = NSView()
            grid.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(grid)
            NSLayoutConstraint.activate([
                grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
                grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),
            ])
            item.view = container
            tabs.addTabViewItem(item)
        }
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.heightAnchor.constraint(equalToConstant: 360).isActive = true
        tabs.widthAnchor.constraint(equalToConstant: SettingsUI.width - 56).isActive = true

        let reset = SettingsUI.button("Restore Default Shortcuts") { [weak self] in
            guard let self else { return }
            for action in SnapAction.allCases { self.context.shortcuts.set(Self.defaultShortcuts[action], for: action.rawValue) }
            Log.shared.info("shortcuts", "reset", ["feature": "snapping"])
            self.context.shortcutsChanged()
        }

        return SettingsUI.stack([
            SettingsUI.checkbox(context, Self.dragKey),
            SettingsUI.checkbox(context, Self.cycleKey),
            SettingsUI.note("Repeating a shortcut moves the window on: left-side positions go left, right-side and centered positions go right, wrapping around at the last display."),
            tabs,
            reset,
        ])
    }

    // MARK: IPC

    private struct SnapParams: Decodable {
        var action: String
        var app: String?
        var window: UInt32?
        var display: Int?
        var cycle: Bool?
    }

    private struct TargetParams: Decodable {
        var app: String?
        var window: UInt32?
    }

    private struct MoveParams: Decodable {
        var app: String?
        var window: UInt32?
        var x: Double, y: Double, width: Double, height: Double
    }

    private struct DisplayInfo: Encodable {
        var index: Int
        var name: String
        var frame: Rect
        var visibleFrame: Rect
        var main: Bool
        var scale: Double
    }

    private func target(app: String?, window: UInt32?) throws -> WindowTarget {
        if let window { return .window(window) }
        if let app { return .app(app) }
        guard let front = NSWorkspace.shared.frontmostApplication else { throw IPCError.notFound("No frontmost app") }
        return .focused(front.processIdentifier)
    }

    private func requireTrust() throws {
        guard context.isAccessibilityTrusted else {
            throw IPCError.permission("Lodestone needs Accessibility access (System Settings → Privacy & Security → Accessibility).")
        }
    }

    func registerIPC(_ router: IPCRouter) {
        let targetDoc = #""app"?: name or bundle id, "window"?: id from window.list (default: focused window)"#

        router.register("displays.list", summary: "Displays from left to right, with frames in top-left-origin points", NoParams.self) { [weak self] _ in
            guard let self else { return [DisplayInfo]() }
            let layout = self.currentLayout()
            return layout.leftToRight.enumerated().map { n, i in
                let screen = NSScreen.screens[i]
                return DisplayInfo(index: n + 1, name: screen.localizedName, frame: Rect(layout.flip(screen.frame)),
                                   visibleFrame: Rect(layout.flip(screen.visibleFrame)), main: i == 0,
                                   scale: screen.backingScaleFactor)
            }
        }

        router.register("window.list", summary: "Standard windows of running apps", params: #"{"app"?: string}"#, TargetParams.self) { [weak self] p in
            guard let self else { return [WindowInfo]() }
            try self.requireTrust()
            var apps = Self.runningApps()
            if let q = p.app?.lowercased() {
                apps = apps.filter { $0.name.lowercased().contains(q) || $0.bundleID?.lowercased() == q }
            }
            let layout = self.currentLayout()
            return await withCheckedContinuation { c in
                self.windows.list(apps: apps, layout: layout) { c.resume(returning: $0) }
            }
        }

        router.register("window.snap", summary: "Snap a window to a position (see snap.actions)",
                        params: #"{"action": string, "display"?: int (1 = leftmost), "cycle"?: bool, "# + targetDoc + "}", SnapParams.self) { [weak self] p in
            guard let self else { throw IPCError.failed("Unavailable") }
            try self.requireTrust()
            guard let action = SnapAction(rawValue: p.action) else {
                throw IPCError.invalidParams("Unknown action '\(p.action)'. Run `lodestone window actions`.")
            }
            let target = try self.target(app: p.app, window: p.window)
            let layout = self.currentLayout()
            let info = try await withCheckedThrowingContinuation { c in
                self.windows.perform(action, target: target, apps: Self.runningApps(), layout: layout,
                                     cycleDisplays: p.cycle ?? false, display: p.display) { c.resume(with: $0) }
            }
            Log.shared.info("window", "snap", ["action": .string(action.rawValue), "app": .string(info.app), "display": .number(Double(info.display)), "via": "ipc"])
            return info
        }

        router.register("window.move", summary: "Set a window's exact frame (top-left-origin points)",
                        params: #"{"x","y","width","height": number, "# + targetDoc + "}", MoveParams.self) { [weak self] p in
            guard let self else { throw IPCError.failed("Unavailable") }
            try self.requireTrust()
            let target = try self.target(app: p.app, window: p.window)
            let frame = CGRect(x: p.x, y: p.y, width: p.width, height: p.height)
            let info = try await withCheckedThrowingContinuation { c in
                self.windows.move(target, apps: Self.runningApps(), to: frame, layout: self.currentLayout()) { c.resume(with: $0) }
            }
            Log.shared.info("window", "move", ["app": .string(info.app), "frame": try JSONValue(encoding: info.frame)])
            return info
        }

        router.register("window.focus", summary: "Bring a window and its app to the front", params: "{" + targetDoc + "}", TargetParams.self) { [weak self] p in
            guard let self else { throw IPCError.failed("Unavailable") }
            try self.requireTrust()
            let target = try self.target(app: p.app, window: p.window)
            let info = try await withCheckedThrowingContinuation { c in
                self.windows.raise(target, apps: Self.runningApps(), layout: self.currentLayout()) { c.resume(with: $0) }
            }
            NSRunningApplication(processIdentifier: info.pid)?.activate()
            Log.shared.info("window", "focus", ["app": .string(info.app)])
            return info
        }

        router.register("snap.actions", summary: "Snap actions with titles and shortcuts", NoParams.self) { [weak self] _ in
            SnapAction.allCases.map { a -> [String: String] in
                var row = ["action": a.rawValue, "title": a.title]
                if let combo = self?.context.shortcuts.combo(for: a.rawValue) { row["shortcut"] = KeyComboText.format(combo) }
                return row
            }
        }
    }
}
