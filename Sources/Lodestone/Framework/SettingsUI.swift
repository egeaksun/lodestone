import AppKit
import LodestoneCore

/// Building blocks for feature Settings tabs. Controls are bound to setting keys: they read the
/// current value, write through `SettingsStore` (so changes are validated and logged), and update
/// themselves when the value changes elsewhere (for example from the CLI).
@MainActor
enum SettingsUI {
    static let width: CGFloat = 460

    /// A checkbox for a bool setting.
    static func checkbox(_ context: AppContext, _ key: String, title: String? = nil) -> NSButton {
        let box = BoundCheckbox(context: context, key: key)
        box.title = title ?? context.settings.definition(key)?.title ?? key
        return box
    }

    /// A pop-up menu for a choice setting. `labels` maps stored values to display names.
    static func popup(_ context: AppContext, _ key: String, labels: [String: String] = [:]) -> NSPopUpButton {
        BoundPopup(context: context, key: key, labels: labels)
    }

    /// A slider for a numeric setting, with a live value label.
    static func slider(_ context: AppContext, _ key: String, format: @escaping (Double) -> String = { String(Int($0)) }) -> NSView {
        BoundSlider(context: context, key: key, format: format)
    }

    /// A push button that runs a closure.
    static func button(_ title: String, action: @escaping @MainActor () -> Void) -> NSButton {
        let target = ClosureTarget(action)
        let button = NSButton(title: title, target: target, action: #selector(ClosureTarget.invoke))
        objc_setAssociatedObject(button, &closureKey, target, .OBJC_ASSOCIATION_RETAIN)
        return button
    }

    private static var closureKey = 0

    /// A label: control row.
    static func row(_ label: String, _ control: NSView) -> NSView {
        let text = NSTextField(labelWithString: label)
        text.alignment = .right
        text.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let stack = NSStackView(views: [text, control])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 10
        return stack
    }

    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width - 56
        return label
    }

    static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    static func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: width - 56).isActive = true
        return box
    }

    /// A vertical stack of rows, leading-aligned, as a tab's content.
    static func stack(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    /// Shortcut recorders for groups of commands, with a gap between groups.
    static func shortcutGrid(_ context: AppContext, groups: [[String]]) -> NSView {
        ShortcutGrid(context: context, groups: groups)
    }
}

private final class BoundCheckbox: NSButton {
    private let context: AppContext
    private let key: String
    private var observer: NSObjectProtocol?

    init(context: AppContext, key: String) {
        self.context = context
        self.key = key
        super.init(frame: .zero)
        setButtonType(.switch)
        target = self
        action = #selector(changed)
        refresh()
        observer = NotificationCenter.default.addObserver(forName: .lodestoneSettingChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                if n.userInfo?["key"] as? String == self?.key { self?.refresh() }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() { state = context.settings.bool(key) ? .on : .off }

    @objc private func changed() {
        try? context.settings.set(key, .bool(state == .on))
    }
}

private final class BoundPopup: NSPopUpButton {
    private let context: AppContext
    private let key: String
    private var values: [String] = []
    private var observer: NSObjectProtocol?

    init(context: AppContext, key: String, labels: [String: String]) {
        self.context = context
        self.key = key
        super.init(frame: .zero, pullsDown: false)
        if case .choice(let choices) = context.settings.definition(key)?.kind {
            values = choices
            addItems(withTitles: choices.map { labels[$0] ?? $0 })
        }
        target = self
        action = #selector(changed)
        refresh()
        observer = NotificationCenter.default.addObserver(forName: .lodestoneSettingChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                if n.userInfo?["key"] as? String == self?.key { self?.refresh() }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        if let i = values.firstIndex(of: context.settings.string(key)) { selectItem(at: i) }
    }

    @objc private func changed() {
        guard indexOfSelectedItem >= 0, indexOfSelectedItem < values.count else { return }
        try? context.settings.set(key, .string(values[indexOfSelectedItem]))
    }
}

private final class BoundSlider: NSStackView {
    private let context: AppContext
    private let key: String
    private let slider = NSSlider()
    private let label = NSTextField(labelWithString: "")
    private let format: (Double) -> String
    private var isInteger = false
    private var observer: NSObjectProtocol?

    init(context: AppContext, key: String, format: @escaping (Double) -> String) {
        self.context = context
        self.key = key
        self.format = format
        super.init(frame: .zero)
        switch context.settings.definition(key)?.kind {
        case .int(let r):
            slider.minValue = Double(r.lowerBound)
            slider.maxValue = Double(r.upperBound)
            isInteger = true
        case .double(let r):
            slider.minValue = r.lowerBound
            slider.maxValue = r.upperBound
        default: break
        }
        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        orientation = .horizontal
        spacing = 8
        addArrangedSubview(slider)
        addArrangedSubview(label)
        refresh()
        observer = NotificationCenter.default.addObserver(forName: .lodestoneSettingChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                if n.userInfo?["key"] as? String == self?.key { self?.refresh() }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        let v = context.settings.double(key)
        slider.doubleValue = v
        label.stringValue = format(v)
    }

    @objc private func changed() {
        let v = isInteger ? slider.doubleValue.rounded() : slider.doubleValue
        label.stringValue = format(v)
        // Store when the drag ends, not on every tick.
        if NSApp.currentEvent?.type == .leftMouseUp || NSApp.currentEvent?.type == .keyDown {
            try? context.settings.set(key, .number(v))
        }
    }
}

/// Label + recorder rows for commands. Refreshes when shortcuts change anywhere.
private final class ShortcutGrid: NSStackView {
    private let context: AppContext
    private var recorders: [String: ShortcutRecorder] = [:]
    private var observer: NSObjectProtocol?

    init(context: AppContext, groups: [[String]]) {
        self.context = context
        super.init(frame: .zero)
        let grid = NSGridView()
        grid.columnSpacing = 12
        grid.rowSpacing = 8
        grid.rowAlignment = .firstBaseline
        for (index, group) in groups.enumerated() {
            for (i, id) in group.enumerated() {
                let recorder = ShortcutRecorder()
                recorder.onChange = { [weak self] combo in
                    self?.context.shortcuts.set(combo, for: id)
                    self?.context.log.info("shortcuts", "set", ["id": .string(id), "shortcut": combo.map { .string(KeyComboText.format($0)) } ?? .null])
                    self?.context.shortcutsChanged()
                }
                recorder.onRecordingChange = { [weak self] recording in self?.context.setShortcutsSuspended(recording) }
                recorders[id] = recorder
                let title = context.commands[id]?.title ?? id
                let row = grid.addRow(with: [NSTextField(labelWithString: title + ":"), recorder])
                if index > 0 && i == 0 { row.topPadding = 14 }
            }
        }
        grid.column(at: 0).xPlacement = .trailing
        orientation = .vertical
        alignment = .centerX
        addArrangedSubview(grid)
        refresh()
        observer = NotificationCenter.default.addObserver(forName: .lodestoneShortcutsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { recorders.values.forEach { $0.stop() } }
    }

    private func refresh() {
        for (id, recorder) in recorders {
            recorder.combo = context.shortcuts.combo(for: id)
            recorder.isUnavailable = context.unavailableShortcuts.contains(id)
        }
    }
}
