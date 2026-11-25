import AppKit

/// Settings window: a General tab, then one toolbar tab per feature that provides a settings view.
/// Built on first open and kept for reuse.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let tabs = NSTabViewController()
    private var tabIndex: [String: Int] = [:]
    private let onShow: () -> Void

    init(general: NSView, features: [Feature], onShow: @escaping () -> Void) {
        self.onShow = onShow
        tabs.tabStyle = .toolbar
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        tabs.addTabViewItem(Self.tab("General", symbol: "gearshape", content: general))
        tabIndex["general"] = 0
        for feature in features {
            guard let view = feature.makeSettingsView() else { continue }
            tabIndex[feature.id] = tabs.tabViewItems.count
            tabs.addTabViewItem(Self.tab(feature.title, symbol: feature.symbol, content: view))
        }
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(tab featureID: String?) {
        if let featureID, let index = tabIndex[featureID] { tabs.selectedTabViewItemIndex = index }
        onShow()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) { onShow() }

    private static func tab(_ title: String, symbol: String, content: NSView) -> NSTabViewItem {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -28),
            container.widthAnchor.constraint(equalToConstant: SettingsUI.width),
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
}
