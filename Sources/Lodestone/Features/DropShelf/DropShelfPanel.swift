import AppKit
import UniformTypeIdentifiers

/// The drop shelf: a small floating target near the pointer. Files dropped on it turn it into a list
/// of the actions Lodestone offers for them, as buttons. Non-activating, so the app you dragged from
/// stays in front. Built once and reused.
@MainActor
final class DropShelfPanel: NSObject {
    enum State { case hidden, waiting, actions }

    /// Asked for the actions that accept the dropped files.
    var actionsFor: (([URL]) -> [FileAction])?
    /// Runs an action the user picked.
    var onPick: ((FileAction, [URL]) -> Void)?
    var onDrop: (([URL], [FileAction]) -> Void)?

    private(set) var state = State.hidden
    let panel: ShelfWindow
    private let effect = NSVisualEffectView()
    private let target = DropTargetView()
    private let content = NSStackView()
    private var files: [URL] = []

    static let waitingSize = NSSize(width: 200, height: 132)
    static let width: CGFloat = 240

    override init() {
        panel = ShelfWindow(contentRect: NSRect(origin: .zero, size: Self.waitingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onEscape = { [weak self] in self?.hide() }

        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        target.onEnter = { [weak self] in self?.setHighlighted(true) }
        target.onExit = { [weak self] in self?.setHighlighted(false) }
        target.onDrop = { [weak self] urls in self?.dropped(urls) }
        target.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(target)
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        // Inside the target, so a drag over a label still finds the target up its superview chain.
        target.addSubview(content)
        NSLayoutConstraint.activate([
            target.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            target.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            target.topAnchor.constraint(equalTo: effect.topAnchor),
            target.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: target.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: target.trailingAnchor),
            content.topAnchor.constraint(equalTo: target.topAnchor),
        ])
    }

    var isVisible: Bool { state != .hidden }
    var frame: NSRect { panel.frame }

    // MARK: States

    /// Shows the empty drop target up and to the right of `point` (screen coordinates), so it's never
    /// under the pointer and the user drags onto it.
    /// `key`: take Esc (not during a drag, where it would cancel the drag in the source app).
    func showWaiting(near point: NSPoint, key: Bool = false) {
        files = []
        state = .waiting
        target.accepting = true
        setContent([
            Self.symbol("tray.and.arrow.down", size: 30),
            Self.label("Drop for Lodestone", size: 13, weight: .semibold),
            Self.label("Convert, merge, compress…", size: 11, color: .secondaryLabelColor),
        ], spacing: 6, topInset: 22)
        setHighlighted(false)
        place(size: Self.waitingSize, near: point)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        if key { panel.makeKey() }
    }

    func dropped(_ urls: [URL]) {
        let actions = actionsFor?(urls) ?? []
        onDrop?(urls, actions)
        files = urls
        state = .actions
        target.accepting = false
        var views: [NSView] = [Self.label(Self.describe(urls), size: 12, weight: .semibold)]
        if actions.isEmpty {
            views.append(Self.label("Lodestone has no actions for these files.", size: 11, color: .secondaryLabelColor, wraps: true))
        }
        for action in actions {
            let button = Self.button(action.title) { [weak self] in
                guard let self else { return }
                let files = self.files
                self.hide()
                self.onPick?(action, files)
            }
            views.append(button)
        }
        let close = Self.button(actions.isEmpty ? "Close" : "Cancel") { [weak self] in self?.hide() }
        close.bezelStyle = .inline
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        views.append(close)
        setContent(views, spacing: 6, topInset: 14)
        content.layoutSubtreeIfNeeded()
        let height = content.fittingSize.height
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: Self.width, height: height)
        panel.setFrame(constrained(frame), display: true, animate: true)
        // Key, so Esc closes it. The app you dragged from stays active.
        panel.makeKey()
    }

    func hide() {
        state = .hidden
        files = []
        panel.orderOut(nil)
    }

    // MARK: Layout helpers

    private func setContent(_ views: [NSView], spacing: CGFloat, topInset: CGFloat) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach(content.addArrangedSubview)
        content.spacing = spacing
        content.edgeInsets.top = topInset
        for view in views where view is NSButton && (view as? NSButton)?.isBordered == true {
            view.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        }
    }

    private func setHighlighted(_ on: Bool) {
        effect.layer?.borderWidth = on ? 2 : 0
        effect.layer?.borderColor = NSColor.controlAccentColor.cgColor
        effect.material = on ? .selection : .hudWindow
    }

    private func place(size: NSSize, near point: NSPoint) {
        let frame = NSRect(x: point.x + 28, y: point.y + 20, width: size.width, height: size.height)
        panel.setFrame(constrained(frame, around: point), display: true)
    }

    /// Keeps the frame on the pointer's screen; flips to the left or below when it would run off.
    private func constrained(_ frame: NSRect, around point: NSPoint? = nil) -> NSRect {
        let p = point ?? NSPoint(x: frame.minX, y: frame.maxY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) ?? NSScreen.main else { return frame }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        var f = frame
        if f.maxX > visible.maxX, let point { f.origin.x = point.x - 28 - f.width }
        if f.maxY > visible.maxY, let point { f.origin.y = point.y - 20 - f.height }
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }

    static func describe(_ urls: [URL]) -> String {
        if urls.count == 1 { return urls[0].lastPathComponent }
        let types = Set(urls.compactMap { (try? $0.resourceValues(forKeys: [.contentTypeKey]))?.contentType })
        let noun: String
        if types.allSatisfy({ $0.conforms(to: .pdf) }) { noun = "PDFs" }
        else if types.allSatisfy({ $0.conforms(to: .image) }) { noun = "images" }
        else if types.allSatisfy({ $0.conforms(to: .movie) }) { noun = "videos" }
        else if types.allSatisfy({ $0.conforms(to: .audio) }) { noun = "audio files" }
        else { noun = "files" }
        return "\(urls.count) \(noun)"
    }

    private static func symbol(_ name: String, size: CGFloat) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        view.symbolConfiguration = .init(pointSize: size, weight: .regular)
        view.contentTintColor = .secondaryLabelColor
        return view
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
                              wraps: Bool = false) -> NSTextField {
        let label = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .center
        label.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingMiddle
        label.preferredMaxLayoutWidth = width - 28
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private static func button(_ title: String, action: @escaping @MainActor () -> Void) -> NSButton {
        let button = SettingsUI.button(title, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        return button
    }
}

/// Becomes key (for Esc) without activating the app.
final class ShelfWindow: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Accepts file drops over the whole shelf while it's waiting.
private final class DropTargetView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onDrop: (([URL]) -> Void)?
    /// Off while the shelf shows actions.
    var accepting = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepting, !urls(sender).isEmpty else { return [] }
        onEnter?()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onExit?() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(sender)
        guard accepting, !files.isEmpty else { return false }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onDrop?(files) }
        }
        return true
    }
}
