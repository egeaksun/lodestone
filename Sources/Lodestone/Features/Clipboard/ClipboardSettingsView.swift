import AppKit
import LodestoneCore
import UniformTypeIdentifiers

/// The Clipboard tab of Settings.
@MainActor
enum ClipboardSettingsView {
    static func make(_ context: AppContext, stats: @escaping () -> (items: Int, bytes: Int)?, clear: @escaping () -> Void) -> NSView {
        let usage = NSTextField(labelWithString: "")
        usage.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        usage.textColor = .secondaryLabelColor
        var clearButton: NSButton?
        let refreshUsage = {
            clearButton?.isEnabled = (stats()?.items ?? 0) > 0
            if let s = stats() {
                usage.stringValue = "\(s.items) item\(s.items == 1 ? "" : "s"), \(RelativeTime.bytes(s.bytes))"
            } else {
                usage.stringValue = "History is off"
            }
        }
        let button = SettingsUI.button("Clear History…") {
            clear()
            refreshUsage()
        }
        clearButton = button
        refreshUsage()
        let clearRow = NSStackView(views: [button, usage])
        clearRow.spacing = 10
        clearRow.alignment = .firstBaseline
        // Refresh the count when the window is shown again.
        let refresher = UsageRefresher(view: usage, refresh: refreshUsage)
        objc_setAssociatedObject(usage, &UsageRefresher.key, refresher, .OBJC_ASSOCIATION_RETAIN)

        let grid = SettingsUI.shortcutGrid(context, groups: [[ClipboardFeature.historyCommand, ClipboardFeature.pastePlainCommand,
                                                              ClipboardFeature.togglePauseCommand]])

        return SettingsUI.stack([
            SettingsUI.checkbox(context, ClipboardFeature.enabledKey),
            SettingsUI.checkbox(context, ClipboardFeature.persistKey),
            SettingsUI.row("Items to keep:", SettingsUI.slider(context, ClipboardFeature.maxItemsKey)),
            SettingsUI.row("Storage limit:", SettingsUI.slider(context, ClipboardFeature.maxStorageKey) { "\(Int($0)) MB" }),
            SettingsUI.note("Pinned items don't count against either limit. History is stored in ~/Library/Application Support/Lodestone/Clipboard, readable only by you."),
            clearRow,
            SettingsUI.separator(),
            SettingsUI.header("Ignored apps"),
            SettingsUI.note("Copies made while one of these apps is in front aren't recorded. Passwords and other items that apps mark as concealed or transient are never recorded."),
            IgnoredAppsEditor(context: context),
            SettingsUI.separator(),
            SettingsUI.checkbox(context, ClipboardFeature.restoreKey),
            SettingsUI.separator(),
            grid,
        ], spacing: 10)
    }
}

private final class UsageRefresher: NSObject {
    static var key = 0
    private var observer: NSObjectProtocol?

    init(view: NSView, refresh: @escaping @MainActor () -> Void) {
        super.init()
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak view] n in
            MainActor.assumeIsolated {
                if let view, (n.object as? NSWindow) === view.window { refresh() }
            }
        }
    }
}

/// A list of ignored apps (bundle ids in `clipboard.ignoredApps`), with Add and Remove.
private final class IgnoredAppsEditor: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    private let context: AppContext
    private let table = NSTableView()
    private var ids: [String] = []
    private var observer: NSObjectProtocol?
    private var removeButton: NSButton!
    private var addButton: NSButton!

    init(context: AppContext) {
        self.context = context
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6

        table.addTableColumn(NSTableColumn(identifier: .init("app")))
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: SettingsUI.width - 56).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 112).isActive = true

        addButton = SettingsUI.button("Add App…") { [weak self] in self?.showAddMenu() }
        removeButton = SettingsUI.button("Remove") { [weak self] in self?.removeSelected() }
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.spacing = 8
        addArrangedSubview(scroll)
        addArrangedSubview(buttons)

        refresh()
        observer = NotificationCenter.default.addObserver(forName: .lodestoneSettingChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                if n.userInfo?["key"] as? String == ClipboardFeature.ignoredAppsKey { self?.refresh() }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        ids = ClipboardRules.parseAppList(context.settings.string(ClipboardFeature.ignoredAppsKey))
        table.reloadData()
        updateButtons()
    }

    private func updateButtons() {
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    private func save(_ ids: [String]) {
        try? context.settings.set(ClipboardFeature.ignoredAppsKey, .string(ClipboardRules.formatAppList(ids)))
    }

    private func add(_ bundleID: String) {
        guard !ids.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) else { return }
        save(ids + [bundleID])
    }

    private func removeSelected() {
        let rows = table.selectedRowIndexes
        save(ids.enumerated().filter { !rows.contains($0.offset) }.map(\.element))
        table.deselectAll(nil)
    }

    private func showAddMenu() {
        let menu = NSMenu()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { app in !ids.contains { $0.caseInsensitiveCompare(app.bundleIdentifier!) == .orderedSame } }
            .sorted { ($0.localizedName ?? "") .localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        if running.isEmpty {
            let none = NSMenuItem(title: "No other running apps", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for app in running {
            let item = NSMenuItem(title: app.localizedName ?? app.bundleIdentifier!) { [weak self] in self?.add(app.bundleIdentifier!) }
            if let icon = app.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Choose an App…") { [weak self] in self?.chooseApp() })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addButton.bounds.height + 4), in: addButton)
    }

    private func chooseApp() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.application]
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        open.allowsMultipleSelection = true
        guard open.runModal() == .OK else { return }
        var updated = ids
        for url in open.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, !updated.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { continue }
            updated.append(id)
        }
        save(updated)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { ids.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = ids[row]
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        let icon = NSImageView(image: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let label = NSTextField(labelWithString: name ?? ClipboardRules.knownAppNames[id] ?? id)
        label.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: name == nil && ClipboardRules.knownAppNames[id] != nil ? "not installed" : id)
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, label, detail])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        return stack
    }
}
