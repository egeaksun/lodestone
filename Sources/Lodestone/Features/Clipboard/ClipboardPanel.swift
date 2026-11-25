import AppKit
import ImageIO
import LodestoneCore

/// The clipboard history panel: a floating, non-activating panel, so the app the user was in stays
/// frontmost (and receives the paste) while the search field takes typing. Built once and reused.
@MainActor
final class ClipboardPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    /// Pastes an item into the frontmost app; `plain` strips formatting.
    var onPaste: ((ClipboardItem, _ plain: Bool) -> Void)?
    var onTogglePin: ((ClipboardItem) -> Void)?
    var onDelete: ((ClipboardItem) -> Void)?
    /// Loads a stored representation, called on a background queue (thumbnails).
    var loadBlob: (@Sendable (ClipboardItem, String) -> Data?)?

    let panel: HistoryPanel
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var allItems: [ClipboardItem] = []
    private var shown: [ClipboardItem] = []
    private var emptyMessage = "Nothing copied yet"
    private var now = Date()
    private let thumbnails = NSCache<NSString, NSImage>()
    private var icons: [String: NSImage] = [:]
    private let thumbnailQueue = DispatchQueue(label: "lodestone.clipboard.thumbnails", qos: .userInitiated)

    static let size = NSSize(width: 440, height: 460)

    override init() {
        panel = HistoryPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                             backing: .buffered, defer: false)
        super.init()
        panel.controller = self
        panel.delegate = self
        build()
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: Showing

    /// Shows the panel near the mouse pointer with `items` (newest first).
    func show(_ items: [ClipboardItem], emptyMessage: String) {
        self.emptyMessage = emptyMessage
        searchField.stringValue = ""
        setItems(items, keepSelection: false)
        position()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(searchField)
    }

    /// Replaces the items, keeping the selected item selected when it still exists.
    func setItems(_ items: [ClipboardItem], keepSelection: Bool = true) {
        let selectedID = keepSelection ? selected?.id : nil
        let selectedRow = table.selectedRow
        allItems = items
        now = Date()
        applySearch()
        if let selectedID, let row = shown.firstIndex(where: { $0.id == selectedID }) {
            select(row)
        } else if keepSelection, selectedRow >= 0, !shown.isEmpty {
            select(min(selectedRow, shown.count - 1))
        }
    }

    func close() {
        panel.orderOut(nil)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: Self.size)
        var origin = NSPoint(x: mouse.x - 40, y: mouse.y - Self.size.height + 20)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - Self.size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: false)
    }

    // MARK: Layout

    private func build() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        panel.contentView = background

        searchField.placeholderString = "Search clipboard history"
        searchField.delegate = self
        searchField.font = .systemFont(ofSize: 15)
        searchField.controlSize = .large
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 56
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.refusesFirstResponder = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 13)

        let hint = NSTextField(labelWithString: "↩ Paste    ⌥↩ Plain Text    ⌘1–9 Quick Paste    ⌘P Pin    ⌘⌫ Delete")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center

        let divider = NSBox()
        divider.boxType = .separator

        for view in [searchField, divider, scroll, emptyLabel, hint] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            divider.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),
            hint.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            hint.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            hint.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -9),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    // MARK: Search & selection

    @objc private func searchChanged() {
        applySearch()
    }

    private func applySearch() {
        shown = ClipboardHistory(items: allItems).search(searchField.stringValue)
        table.reloadData()
        emptyLabel.stringValue = allItems.isEmpty ? emptyMessage : "No matches"
        emptyLabel.isHidden = !shown.isEmpty
        if !shown.isEmpty { select(0) }
    }

    private var selected: ClipboardItem? {
        let row = table.selectedRow
        return row >= 0 && row < shown.count ? shown[row] : nil
    }

    private func select(_ row: Int) {
        guard !shown.isEmpty else { return }
        let row = min(max(row, 0), shown.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0, table.clickedRow < shown.count else { return }
        onPaste?(shown[table.clickedRow], NSEvent.modifierFlags.contains(.option))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): select(table.selectedRow - 1)
        case #selector(NSResponder.moveDown(_:)): select(table.selectedRow + 1)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.scrollToBeginningOfDocument(_:)): select(0)
        case #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.scrollToEndOfDocument(_:)): select(shown.count - 1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): select(table.selectedRow - 8)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): select(table.selectedRow + 8)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if let item = selected { onPaste?(item, NSApp.currentEvent?.modifierFlags.contains(.option) ?? false) } else { NSSound.beep() }
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty { close() } else { searchField.stringValue = ""; applySearch() }
        case #selector(NSResponder.deleteBackward(_:)) where searchField.stringValue.isEmpty:
            deleteSelected()
        default:
            return false
        }
        return true
    }

    /// ⌘1–9 (⌥ for plain text), ⌘P, ⌘⌫. Returns true when handled.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        guard flags.contains(.command), flags.isSubset(of: [.command, .option]) else { return false }
        let key = event.charactersIgnoringModifiers ?? ""
        if let n = Int(key), (1...9).contains(n) {
            if n <= shown.count { onPaste?(shown[n - 1], flags.contains(.option)) } else { NSSound.beep() }
            return true
        }
        switch event.keyCode {
        case 35: // P
            if let item = selected { onTogglePin?(item) }
            return true
        case 51: // delete
            deleteSelected()
            return true
        default:
            return false
        }
    }

    private func deleteSelected() {
        if let item = selected { onDelete?(item) } else { NSSound.beep() }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        EmphasizedRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: ClipboardRowView.identifier, owner: nil) as? ClipboardRowView) ?? ClipboardRowView()
        let item = shown[row]
        cell.itemID = item.id
        cell.title.stringValue = Self.preview(item)
        cell.title.maximumNumberOfLines = item.kind == .image ? 1 : 2
        var meta = [item.sourceApp ?? "Unknown app", RelativeTime.short(from: item.date, to: now)]
        if item.kind == .image { meta.append(RelativeTime.bytes(item.byteSize)) }
        if item.kind == .richText { meta.append("formatted") }
        cell.meta.stringValue = meta.joined(separator: " · ")
        cell.appIcon.image = appIcon(item.sourceBundleID)
        cell.pin.isHidden = !item.pinned
        cell.shortcut.stringValue = row < 9 ? "⌘\(row + 1)" : ""
        cell.preview.image = leadingImage(item, cell: cell)
        return cell
    }

    static func preview(_ item: ClipboardItem) -> String {
        switch item.kind {
        case .image, .files: return item.title
        case .text, .richText:
            // First two non-empty lines, whitespace collapsed.
            let lines = item.text.prefix(600).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(2)
            return lines.isEmpty ? "(whitespace)" : lines.joined(separator: "\n")
        }
    }

    private func leadingImage(_ item: ClipboardItem, cell: ClipboardRowView) -> NSImage? {
        switch item.kind {
        case .text: return NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "Text")
        case .richText: return NSImage(systemSymbolName: "textformat", accessibilityDescription: "Formatted text")
        case .files:
            guard let first = item.filePaths.first else { return nil }
            return icon(key: "file:" + first) { NSWorkspace.shared.icon(forFile: first) }
        case .image:
            if let cached = thumbnails.object(forKey: item.id as NSString) { return cached }
            let id = item.id
            let load = loadBlob
            thumbnailQueue.async { [weak self] in
                guard let data = load?(item, "png"), let image = Self.thumbnail(data, maxPixels: 96) else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.thumbnails.setObject(image, forKey: id as NSString)
                    if cell.itemID == id { cell.preview.image = image }
                }
            }
            return NSImage(systemSymbolName: "photo", accessibilityDescription: "Image")
        }
    }

    private nonisolated static func thumbnail(_ data: Data, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }

    private func appIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        return icon(key: "app:" + bundleID) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    private func icon(key: String, _ make: () -> NSImage?) -> NSImage? {
        if let cached = icons[key] { return cached }
        let image = make()
        if let image { icons[key] = image }
        return image
    }
}

/// The panel takes key status without activating Lodestone (see `.nonactivatingPanel`).
final class HistoryPanel: NSPanel {
    weak var controller: ClipboardPanelController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if MainActor.assumeIsolated({ controller?.handleKeyEquivalent(event) }) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// Draws the selection in the accent color even though the table isn't first responder (the search
/// field is).
private final class EmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

private final class ClipboardRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ClipboardRow")

    var itemID = ""
    let preview = NSImageView()
    let title = NSTextField(labelWithString: "")
    let meta = NSTextField(labelWithString: "")
    let appIcon = NSImageView()
    let pin = NSImageView()
    let shortcut = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        preview.imageScaling = .scaleProportionallyDown
        preview.contentTintColor = .secondaryLabelColor
        preview.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byWordWrapping
        title.cell?.truncatesLastVisibleLine = true
        title.cell?.wraps = true
        title.maximumNumberOfLines = 2
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        pin.contentTintColor = .systemOrange
        pin.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        shortcut.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        shortcut.textColor = .tertiaryLabelColor
        shortcut.alignment = .right
        shortcut.setContentHuggingPriority(.required, for: .horizontal)
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)

        title.usesSingleLineMode = false
        title.preferredMaxLayoutWidth = ClipboardPanelController.size.width - 130
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        appIcon.widthAnchor.constraint(equalToConstant: 13).isActive = true
        appIcon.heightAnchor.constraint(equalToConstant: 13).isActive = true
        let metaRow = NSStackView(views: [appIcon, meta, pin])
        metaRow.spacing = 4
        metaRow.setCustomSpacing(5, after: meta)
        let text = NSStackView(views: [title, metaRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        for view in [preview, text, shortcut] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = title
        imageView = preview
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            preview.centerYAnchor.constraint(equalTo: centerYAnchor),
            preview.widthAnchor.constraint(equalToConstant: 34),
            preview.heightAnchor.constraint(equalToConstant: 34),
            text.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
