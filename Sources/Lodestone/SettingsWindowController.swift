import AppKit
import LodestoneCore
import ServiceManagement

/// What the Settings window needs from the app.
protocol SettingsHost: AnyObject {
    var shortcuts: ShortcutStore { get }
    /// Actions whose shortcut another app already owns.
    var unavailableShortcuts: Set<SnapAction> { get }
    var dragEnabled: Bool { get set }
    var cycleDisplays: Bool { get set }
    func shortcutsChanged()
    func setShortcutsSuspended(_ suspended: Bool)
}

/// Settings window with toolbar tabs. Built on first open, then kept for reuse.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private weak var host: SettingsHost?
    private var recorders: [SnapAction: ShortcutRecorder] = [:]
    private var dragCheckbox: NSButton!
    private var cycleCheckbox: NSButton!
    private var loginCheckbox: NSButton!
    private var accessibilityLabel: NSTextField!
    private var accessibilityButton: NSButton!

    init(host: SettingsHost) {
        self.host = host
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        tabs.addTabViewItem(generalTab())
        tabs.addTabViewItem(shortcutTab("Halves & Quarters", symbol: "rectangle.split.2x2", groups: [
            [.leftHalf, .rightHalf, .topHalf, .bottomHalf],
            [.topLeft, .topRight, .bottomLeft, .bottomRight],
        ]))
        tabs.addTabViewItem(shortcutTab("Thirds", symbol: "rectangle.split.3x1", groups: [
            [.firstThird, .centerThird, .lastThird],
            [.firstTwoThirds, .centerTwoThirds, .lastTwoThirds],
        ]))
        tabs.addTabViewItem(shortcutTab("Sixths", symbol: "square.grid.3x2", groups: [
            [.sixth1, .sixth2, .sixth3, .sixth4, .sixth5, .sixth6],
        ]))
        tabs.addTabViewItem(shortcutTab("Window", symbol: "macwindow", groups: [
            [.maximize, .center, .restore],
            [.nextDisplay, .previousDisplay],
        ]))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refresh()
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        guard let host else { return }
        for (action, recorder) in recorders {
            recorder.combo = host.shortcuts.combo(for: action)
            recorder.isUnavailable = host.unavailableShortcuts.contains(action)
        }
        dragCheckbox.state = host.dragEnabled ? .on : .off
        cycleCheckbox.state = host.cycleDisplays ? .on : .off
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let trusted = AXIsProcessTrusted()
        accessibilityLabel.stringValue = trusted ? "Accessibility access is granted." : "Lodestone needs Accessibility access to move windows."
        accessibilityLabel.textColor = trusted ? .secondaryLabelColor : .systemRed
        accessibilityButton.isHidden = trusted
    }

    func windowWillClose(_ notification: Notification) {
        recorders.values.forEach { $0.stop() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refresh()
    }

    // MARK: Tabs

    private func generalTab() -> NSTabViewItem {
        dragCheckbox = NSButton(checkboxWithTitle: "Snap windows by dragging them to screen edges", target: self, action: #selector(toggleDrag))
        cycleCheckbox = NSButton(checkboxWithTitle: "Press a shortcut again to move the window to the next display", target: self, action: #selector(toggleCycle))
        let cycleHint = NSTextField(wrappingLabelWithString: "Left-side positions move left, right-side and centered positions move right, wrapping around at the last display.")
        cycleHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cycleHint.textColor = .secondaryLabelColor
        loginCheckbox = NSButton(checkboxWithTitle: "Launch Lodestone at login", target: self, action: #selector(toggleLogin))
        accessibilityLabel = NSTextField(wrappingLabelWithString: "")
        accessibilityLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        accessibilityButton = NSButton(title: "Open Accessibility Settings…", target: self, action: #selector(openAccessibility))

        let hint = NSTextField(wrappingLabelWithString: "Use the other tabs to change keyboard shortcuts. Click a shortcut, then press the new combination. Press Delete to remove it, or Escape to cancel.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [dragCheckbox, cycleCheckbox, cycleHint, loginCheckbox, separator(), accessibilityLabel, accessibilityButton, separator(), hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: cycleCheckbox)
        cycleHint.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20).isActive = true
        return tab("General", symbol: "gearshape", content: stack)
    }

    private func shortcutTab(_ title: String, symbol: String, groups: [[SnapAction]]) -> NSTabViewItem {
        let grid = NSGridView()
        grid.columnSpacing = 12
        grid.rowSpacing = 8
        grid.rowAlignment = .firstBaseline
        for (index, group) in groups.enumerated() {
            for (i, action) in group.enumerated() {
                let recorder = ShortcutRecorder()
                recorder.onChange = { [weak self] combo in
                    self?.host?.shortcuts.set(combo, for: action)
                    self?.host?.shortcutsChanged()
                }
                recorder.onRecordingChange = { [weak self] recording in
                    self?.host?.setShortcutsSuspended(recording)
                }
                recorders[action] = recorder
                let row = grid.addRow(with: [NSTextField(labelWithString: action.title + ":"), recorder])
                if index > 0 && i == 0 { row.topPadding = 14 }
            }
        }
        grid.column(at: 0).xPlacement = .trailing

        let reset = NSButton(title: "Restore Default Shortcuts", target: self, action: #selector(resetShortcuts))
        let stack = NSStackView(views: [grid, reset])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        return tab(title, symbol: symbol, content: stack)
    }

    private func tab(_ title: String, symbol: String, content: NSView) -> NSTabViewItem {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            container.widthAnchor.constraint(equalToConstant: 440),
        ])
        let controller = NSViewController()
        controller.view = container
        controller.preferredContentSize = container.fittingSize
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 384).isActive = true
        return box
    }

    // MARK: Actions

    @objc private func toggleDrag() {
        host?.dragEnabled = dragCheckbox.state == .on
    }

    @objc private func toggleCycle() {
        host?.cycleDisplays = cycleCheckbox.state == .on
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if loginCheckbox.state == .on { try service.register() } else { try service.unregister() }
        } catch {
            NSLog("Lodestone: launch at login failed: %@", error.localizedDescription)
        }
        refresh()
    }

    @objc private func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func resetShortcuts() {
        host?.shortcuts.resetToDefaults()
        host?.shortcutsChanged()
    }
}
