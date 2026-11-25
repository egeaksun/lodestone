import AppKit
import LodestoneCore
import LodestoneKit

/// The Folder Rules tab: the on/off switches, the list of rules, and the rule editor.
@MainActor
enum RulesSettingsView {
    static func make(feature: RulesFeature, context: AppContext) -> NSView {
        SettingsUI.stack([
            SettingsUI.checkbox(context, RulesFeature.enabledKey),
            SettingsUI.note("New files that land in a watched folder are converted once they've finished being written. Files already there are left alone; use Run Now for those."),
            RulesList(feature: feature),
            SettingsUI.separator(),
            SettingsUI.checkbox(context, RulesFeature.notifyKey),
            SettingsUI.shortcutGrid(context, groups: [["rules.toggle"]]),
        ], spacing: 10)
    }
}

private final class RulesList: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    private let feature: RulesFeature
    private let table = NSTableView()
    private var addButton: NSButton!
    private var editButton: NSButton!
    private var removeButton: NSButton!
    private var runButton: NSButton!
    private let emptyLabel = NSTextField(labelWithString: "No rules yet. Add one to convert new files automatically.")

    init(feature: RulesFeature) {
        self.feature = feature
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6

        table.addTableColumn(NSTableColumn(identifier: .init("rule")))
        table.headerView = nil
        table.rowHeight = 40
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: SettingsUI.width - 56).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 168).isActive = true

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        addButton = SettingsUI.button("Add Rule…") { [weak self] in self?.showAddMenu() }
        editButton = SettingsUI.button("Edit…") { [weak self] in self?.editSelected() }
        removeButton = SettingsUI.button("Remove") { [weak self] in self?.removeSelected() }
        runButton = SettingsUI.button("Run Now") { [weak self] in self?.runSelected() }
        runButton.toolTip = "Convert the matching files already in the folder"
        let buttons = NSStackView(views: [addButton, editButton, removeButton, runButton])
        buttons.spacing = 8
        addArrangedSubview(scroll)
        addArrangedSubview(buttons)

        feature.onRulesChanged = { [weak self] in self?.reload() }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var rules: [FolderRule] { feature.rules }

    private var selected: FolderRule? {
        let row = table.selectedRow
        return row >= 0 && row < rules.count ? rules[row] : nil
    }

    private func reload() {
        let id = selected?.id
        table.reloadData()
        if let id, let row = rules.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        emptyLabel.isHidden = !rules.isEmpty
        updateButtons()
    }

    private func updateButtons() {
        let has = selected != nil
        editButton.isEnabled = has
        removeButton.isEnabled = has
        runButton.isEnabled = has && selected?.enabled == true
    }

    // MARK: Actions

    private func showAddMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "New Rule…") { [weak self] in
            self?.edit(FolderRule(folder: Self.desktop, kinds: [.video], format: .mp4), isNew: true)
        })
        menu.addItem(.separator())
        let templates: [(String, FolderRule)] = [
            ("Screen Recordings → MP4", FolderRule(name: "Screen recordings → MP4", folder: Self.screenshotFolder, pattern: "Screen Recording*",
                                                    kinds: [.video], format: .mp4, preset: "balanced")),
            ("Screenshots → compressed", FolderRule(name: "Screenshots → compressed", folder: Self.screenshotFolder, pattern: "Screenshot*",
                                                     kinds: [.image], preset: "compress")),
        ]
        for (title, rule) in templates {
            menu.addItem(NSMenuItem(title: title) { [weak self] in self?.edit(rule, isNew: true) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addButton.bounds.height + 4), in: addButton)
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        editSelected()
    }

    private func editSelected() {
        guard let rule = selected else { return }
        edit(rule, isNew: false)
    }

    private func edit(_ rule: FolderRule, isNew: Bool) {
        var draft = rule
        while let edited = RuleEditor.run(draft, isNew: isNew, window: window) {
            do {
                try feature.save(edited)
                if let row = rules.firstIndex(where: { $0.id == edited.id }) { table.selectRowIndexes([row], byExtendingSelection: false) }
                return
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "This rule can't be saved"
                alert.informativeText = (error as? IPCError)?.message ?? error.localizedDescription
                alert.runModal()
                draft = edited
            }
        }
    }

    private func removeSelected() {
        guard let rule = selected else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(rule.name)”?"
        alert.informativeText = "Files it already converted stay where they are."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = try? feature.remove(rule.id)
    }

    private func runSelected() {
        guard let rule = selected else { return }
        do {
            let preview = try feature.runNow(rule, dryRun: true)
            let alert = NSAlert()
            if preview.convert.isEmpty {
                alert.messageText = "Nothing to convert"
                alert.informativeText = "No file in \((rule.folder as NSString).abbreviatingWithTildeInPath) matches “\(rule.name)”."
                alert.runModal()
                return
            }
            let names = preview.convert.prefix(8).map { ($0 as NSString).lastPathComponent }.joined(separator: "\n")
            let more = preview.convert.count > 8 ? "\n…and \(preview.convert.count - 8) more" : ""
            alert.messageText = "Convert \(preview.convert.count) file\(preview.convert.count == 1 ? "" : "s") now?"
            alert.informativeText = names + more
            alert.addButton(withTitle: "Convert")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            _ = try feature.runNow(rule, dryRun: false)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rule = rules[row]
        let toggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        toggle.state = rule.enabled ? .on : .off
        toggle.toolTip = rule.enabled ? "Turn this rule off" : "Turn this rule on"
        let target = ClosureTarget { [weak self] in _ = try? self?.feature.setEnabled(rule.id, !rule.enabled) }
        toggle.target = target
        toggle.action = #selector(ClosureTarget.invoke)
        objc_setAssociatedObject(toggle, &RulesList.targetKey, target, .OBJC_ASSOCIATION_RETAIN)

        let name = NSTextField(labelWithString: rule.name)
        name.lineBreakMode = .byTruncatingTail
        name.textColor = rule.enabled ? .labelColor : .secondaryLabelColor
        let folder = (rule.folder as NSString).abbreviatingWithTildeInPath + (rule.includeSubfolders ? " (and subfolders)" : "")
        let detail = NSTextField(labelWithString: "\(folder) — \(rule.summary)")
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.lineBreakMode = .byTruncatingMiddle
        for label in [name, detail] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let stack = NSStackView(views: [toggle, text])
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        return stack
    }

    nonisolated(unsafe) private static var targetKey = 0

    // MARK: Places

    static var desktop: String { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].path }

    /// Where screenshots and screen recordings go: the Screenshot app's setting, else the Desktop.
    static var screenshotFolder: String {
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !location.isEmpty {
            let path = (location as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { return path }
        }
        return desktop
    }
}

/// A compact editor for one rule, shown as an alert with a form.
@MainActor
private enum RuleEditor {
    static func run(_ rule: FolderRule, isNew: Bool, window: NSWindow?) -> FolderRule? {
        var rule = rule
        // An automatic name stays automatic (empty field), so it follows a change of folder or format.
        let name = NSTextField(string: rule.name == rule.defaultName ? "" : rule.name)
        name.placeholderString = "Named after the folder and format"
        name.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let folderLabel = NSTextField(labelWithString: (rule.folder as NSString).abbreviatingWithTildeInPath)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        let chooseFolder = SettingsUI.button("Choose…") {
            if let path = pickFolder(rule.folder) {
                rule.folder = path
                folderLabel.stringValue = (path as NSString).abbreviatingWithTildeInPath
            }
        }
        let folderRow = NSStackView(views: [folderLabel, chooseFolder])
        folderRow.spacing = 8
        let subfolders = NSButton(checkboxWithTitle: "Include subfolders", target: nil, action: nil)
        subfolders.state = rule.includeSubfolders ? .on : .off

        let pattern = NSTextField(string: rule.pattern ?? "")
        pattern.placeholderString = "Any name, or e.g. Screen Recording*"
        pattern.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let kindBoxes = MediaKind.allCases.map { kind -> NSButton in
            let box = NSButton(checkboxWithTitle: kind.pluralTitle, target: nil, action: nil)
            box.state = rule.kinds.contains(kind) ? .on : .off
            return box
        }
        let kindsRow = NSStackView(views: kindBoxes)
        kindsRow.spacing = 12

        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        format.addItem(withTitle: "Same format")
        format.lastItem?.representedObject = ""
        format.menu?.addItem(.separator())
        for f in OutputFormat.allCases {
            format.addItem(withTitle: f.title)
            format.lastItem?.representedObject = f.rawValue
        }
        format.selectItem(at: rule.format.flatMap { f in format.itemArray.firstIndex { $0.representedObject as? String == f.rawValue } } ?? 0)

        let preset = NSPopUpButton(frame: .zero, pullsDown: false)
        func reloadPresets() {
            let current = preset.selectedItem?.representedObject as? String ?? rule.preset ?? ""
            let kinds = MediaKind.allCases.enumerated().filter { kindBoxes[$0.offset].state == .on }.map(\.element)
            let target = OutputFormat(rawValue: format.selectedItem?.representedObject as? String ?? "")
            let needed = Set(kinds.map { kind in target.flatMap { ConvertRoute(source: kind, format: $0)?.presetKind } ?? kind })
            preset.removeAllItems()
            preset.addItem(withTitle: "Default")
            preset.lastItem?.representedObject = ""
            if needed.count == 1, let kind = needed.first {
                preset.menu?.addItem(.separator())
                for p in Converter.shared.presets.forKind(kind) where BuiltInPresets.suits(p, format: target) {
                    preset.addItem(withTitle: p.name)
                    preset.lastItem?.representedObject = p.id
                }
            }
            preset.selectItem(at: preset.itemArray.firstIndex { $0.representedObject as? String == current } ?? 0)
        }
        let refresh = ClosureTarget { reloadPresets() }
        for control in [format] + kindBoxes as [NSControl] {
            control.target = refresh
            control.action = #selector(ClosureTarget.invoke)
        }
        reloadPresets()

        let output = NSPopUpButton(frame: .zero, pullsDown: false)
        output.addItem(withTitle: "Next to the original")
        output.addItem(withTitle: rule.outputFolder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Choose a Folder…")
        output.addItem(withTitle: "Choose a Folder…")
        if rule.outputFolder == nil { output.removeItem(at: 1) }
        output.selectItem(at: rule.outputFolder == nil ? 0 : 1)
        var outputFolder = rule.outputFolder
        let outputTarget = ClosureTarget {
            guard output.indexOfSelectedItem == output.numberOfItems - 1 else {
                if output.indexOfSelectedItem == 0 { outputFolder = nil }
                return
            }
            if let path = pickFolder(outputFolder ?? rule.folder) {
                outputFolder = path
                if output.numberOfItems == 3 { output.removeItem(at: 1) }
                output.insertItem(withTitle: (path as NSString).abbreviatingWithTildeInPath, at: 1)
                output.selectItem(at: 1)
            } else {
                output.selectItem(at: outputFolder == nil ? 0 : 1)
            }
        }
        output.target = outputTarget
        output.action = #selector(ClosureTarget.invoke)

        let originals = NSPopUpButton(frame: .zero, pullsDown: false)
        originals.addItems(withTitles: ["Keep them", "Move them to the Trash"])
        originals.selectItem(at: rule.originals == .trash ? 1 : 0)

        let rows: [(String, NSView)] = [
            ("Name:", name), ("Folder:", folderRow), ("", subfolders), ("File names:", pattern), ("Convert:", kindsRow),
            ("To:", format), ("Preset:", preset), ("Save to:", output), ("Originals:", originals),
        ]
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.layoutSubtreeIfNeeded()
        grid.frame.size = grid.fittingSize

        let alert = NSAlert()
        alert.messageText = isNew ? "New Folder Rule" : "Edit Folder Rule"
        alert.informativeText = "New files matching the rule are converted as soon as they've finished being written."
        alert.accessoryView = grid
        alert.addButton(withTitle: isNew ? "Add Rule" : "Save")
        alert.addButton(withTitle: "Cancel")
        // Keep the closure targets alive while the alert runs.
        let response = withExtendedLifetime([refresh, outputTarget, chooseFolder]) { alert.runModal() }
        guard response == .alertFirstButtonReturn else { return nil }

        rule.includeSubfolders = subfolders.state == .on
        rule.pattern = pattern.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? nil : pattern.stringValue.trimmingCharacters(in: .whitespaces)
        rule.kinds = MediaKind.allCases.enumerated().filter { kindBoxes[$0.offset].state == .on }.map(\.element)
        rule.format = OutputFormat(rawValue: format.selectedItem?.representedObject as? String ?? "")
        let presetID = preset.selectedItem?.representedObject as? String ?? ""
        rule.preset = presetID.isEmpty ? nil : presetID
        rule.outputFolder = outputFolder
        rule.originals = originals.indexOfSelectedItem == 1 ? .trash : .keep
        let typed = name.stringValue.trimmingCharacters(in: .whitespaces)
        rule.name = typed.isEmpty ? rule.defaultName : typed
        return rule
    }

    private static func pickFolder(_ start: String) -> String? {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.directoryURL = URL(fileURLWithPath: start)
        open.prompt = "Choose"
        return open.runModal() == .OK ? open.url?.path : nil
    }
}
