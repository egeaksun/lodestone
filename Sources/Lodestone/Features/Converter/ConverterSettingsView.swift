import AppKit
import LodestoneCore
import LodestoneKit

/// The Converter tab in Settings: default format and preset per kind, where files go, what happens
/// afterwards, and which optional tools are installed.
@MainActor
enum ConverterSettingsView {
    typealias Key = ConverterFeature.Key

    static func make(feature: ConverterFeature) -> NSView {
        let context = feature.context!
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        for kind in MediaKind.allCases {
            var labels: [String: String] = [ConverterFeature.sameFormat: "Same as original"]
            for f in OutputFormat.targets(for: kind) {
                labels[f.rawValue] = kind == .video && f == .gif ? "Animated GIF" : f.title + (kind == .video && f.isAudio ? " (audio only)" : "")
            }
            let format = SettingsUI.popup(context, Key.format(kind), labels: labels)
            format.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let preset = PresetSettingPopup(feature: feature, kind: kind)
            preset.widthAnchor.constraint(equalToConstant: 180).isActive = true
            grid.addRow(with: [NSTextField(labelWithString: kind.pluralTitle + ":"), format, preset])
        }
        grid.column(at: 0).xPlacement = .trailing

        let location = SettingsUI.popup(context, Key.outputLocation, labels: [
            "source": "Next to the original", "downloads": "Downloads", "folder": "A chosen folder",
        ])
        let folderLabel = FolderLabel(context: context)
        let choose = SettingsUI.button("Choose…") {
            let open = NSOpenPanel()
            open.canChooseDirectories = true
            open.canChooseFiles = false
            open.canCreateDirectories = true
            open.prompt = "Choose"
            guard open.runModal() == .OK, let url = open.url else { return }
            try? context.settings.set(Key.outputFolder, .string(url.path))
            try? context.settings.set(Key.outputLocation, "folder")
        }
        choose.controlSize = .small
        let folderRow = NSStackView(views: [choose, folderLabel])
        folderRow.spacing = 8

        let after = SettingsUI.popup(context, Key.afterConvert, labels: [
            "reveal": "Show the files in Finder", "notify": "Show a notification", "nothing": "Do nothing",
        ])
        let originals = SettingsUI.popup(context, Key.originals, labels: ["keep": "Keep them", "trash": "Move them to the Trash"])

        let open = SettingsUI.button("Open Convert Panel…") { feature.openPanel([]) }

        return SettingsUI.stack([
            SettingsUI.header("Defaults"),
            grid,
            SettingsUI.note("Used by the Convert panel and the quick actions (drop files on the menu bar icon). Same as original keeps each image's format, which suits Compress and Resize."),
            SettingsUI.separator(),
            SettingsUI.row("Save converted files:", location),
            SettingsUI.row("", folderRow),
            SettingsUI.row("After converting:", after),
            SettingsUI.row("Originals:", originals),
            SettingsUI.note("Existing files are never replaced: a taken name gets \" (converted)\"."),
            SettingsUI.separator(),
            SettingsUI.header("Tools"),
            toolStatus(),
            open,
        ], spacing: 10)
    }

    private static func toolStatus() -> NSView {
        let uses: [ExternalTool: String] = [
            .ffmpeg: "video, audio, GIF", .ffprobe: "reading media", .cwebp: "WebP", .avifenc: "AVIF",
        ]
        var rows: [NSView] = []
        for tool in [ExternalTool.ffmpeg, .ffprobe, .cwebp, .avifenc] {
            let installed = tool.url != nil
            let mark = NSTextField(labelWithString: installed ? "✓" : "✗")
            mark.textColor = installed ? .systemGreen : .systemOrange
            mark.widthAnchor.constraint(equalToConstant: 14).isActive = true
            let name = NSTextField(labelWithString: "\(tool.rawValue) — \(uses[tool] ?? "")")
            var views: [NSView] = [mark, name]
            if !installed {
                let hint = NSTextField(labelWithString: tool.installHint)
                hint.textColor = .secondaryLabelColor
                hint.isSelectable = true
                views.append(hint)
            }
            let row = NSStackView(views: views)
            row.spacing = 6
            rows.append(row)
        }
        if ExternalTool.ffmpeg.url == nil {
            rows.append(SettingsUI.note("Without ffmpeg, MP4, MOV and M4A still work through macOS (fewer options)."))
        }
        return SettingsUI.stack(rows, spacing: 4)
    }
}

/// The preset for a kind, listing the presets that suit the kind's current default format
/// (built-in and saved). Rebuilds when the format or presets change.
@MainActor
private final class PresetSettingPopup: NSPopUpButton {
    private let feature: ConverterFeature
    private let kind: MediaKind
    private var ids: [String] = []
    private var observer: NSObjectProtocol?

    init(feature: ConverterFeature, kind: MediaKind) {
        self.feature = feature
        self.kind = kind
        super.init(frame: .zero, pullsDown: false)
        target = self
        action = #selector(changed)
        refresh()
        observer = NotificationCenter.default.addObserver(forName: .lodestoneSettingChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let key = n.userInfo?["key"] as? String else { return }
                if key == ConverterFeature.Key.format(self.kind) || key == ConverterFeature.Key.preset(self.kind) { self.refresh() }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilt when the menu opens too, so presets saved from the CLI show up.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        refresh()
        super.willOpenMenu(menu, with: event)
    }

    private func refresh() {
        let target = feature.defaultTarget(for: kind)
        let presetKind = target.format.flatMap { ConvertRoute(source: kind, format: $0)?.presetKind } ?? kind
        let presets = feature.converter.presets.forKind(presetKind).filter { BuiltInPresets.suits($0, format: target.format) }
        ids = presets.map(\.id)
        removeAllItems()
        addItems(withTitles: presets.map { $0.name + ($0.builtIn ? "" : " ★") })
        if let i = ids.firstIndex(of: target.preset ?? "") { selectItem(at: i) }
        toolTip = presets.first { $0.id == target.preset }?.summary
    }

    @objc private func changed() {
        guard indexOfSelectedItem >= 0, indexOfSelectedItem < ids.count else { return }
        try? feature.context.settings.set(ConverterFeature.Key.preset(kind), .string(ids[indexOfSelectedItem]))
    }
}

/// Shows the chosen output folder; updates when the setting changes.
@MainActor
private final class FolderLabel: NSTextField {
    private let context: AppContext
    private var observer: NSObjectProtocol?

    init(context: AppContext) {
        self.context = context
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        drawsBackground = false
        textColor = .secondaryLabelColor
        lineBreakMode = .byTruncatingMiddle
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        refresh()
        observer = NotificationCenter.default.addObserver(forName: .lodestoneSettingChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                if (n.userInfo?["key"] as? String)?.hasPrefix("converter.output") == true { self?.refresh() }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        let path = context.settings.string(ConverterFeature.Key.outputFolder)
        stringValue = path.isEmpty ? "No folder chosen" : (path as NSString).abbreviatingWithTildeInPath
        toolTip = path.isEmpty ? nil : path
    }
}
