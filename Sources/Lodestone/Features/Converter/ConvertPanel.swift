import AppKit
import LodestoneCore
import LodestoneKit
import UniformTypeIdentifiers

/// The Convert panel: a compact HandBrake. A file list you can drop onto, a format and preset per
/// kind of media, a Customize disclosure with every option, the output location, and per-file
/// progress with Cancel.
@MainActor
final class ConvertPanelController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    final class Item {
        enum State {
            case pending
            case running(Double)
            case done(ConvertResult)
            case failed(String)
            case cancelled
        }

        let url: URL
        let kind: MediaKind
        var output: String?
        var state: State = .pending

        init(url: URL, kind: MediaKind) {
            self.url = url
            self.kind = kind
        }

        var needsConverting: Bool {
            if case .done = state { return false }
            return true
        }
    }

    private unowned let feature: ConverterFeature
    private(set) var items: [Item] = []
    /// Per kind. Nil (images only): keep each image's format.
    private var formats: [MediaKind: OutputFormat?] = [:]
    private var presets: [MediaKind: String] = [:]
    private var overrides: [MediaKind: ConvertOptions] = [:]
    private var outputChoice = "source"
    private var outputFolder: URL?
    private var job: Task<Void, Never>?
    private var runningItems: [Item] = []
    private var lastOutputs: [URL] = []

    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "Drop images, videos or audio here")
    private let targetsStack = NSStackView()
    private let customizeButton = NSButton()
    private let optionsStack = NSStackView()
    private let outputPopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var addButton: NSButton!
    private var removeButton: NSButton!
    private var revealButton: NSButton!
    private var cancelButton: NSButton!
    private var convertButton: NSButton!

    private static let width: CGFloat = 640

    init(feature: ConverterFeature) {
        self.feature = feature
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Convert Files"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        for kind in MediaKind.allCases {
            let target = feature.defaultTarget(for: kind)
            formats[kind] = target.format
            presets[kind] = target.preset
        }
        outputChoice = feature.context.settings.string(ConverterFeature.Key.outputLocation)
        let folder = feature.context.settings.string(ConverterFeature.Key.outputFolder)
        if !folder.isEmpty { outputFolder = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath) }
        buildUI()
        rebuildTargets()
        updateButtons()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Files

    /// Adds files (and the media inside dropped folders). Duplicates and non-media are skipped.
    func add(_ urls: [URL]) {
        var added = 0
        for url in expand(urls) {
            let standardized = url.standardizedFileURL
            guard !items.contains(where: { $0.url == standardized }), let kind = MediaProbe.quickKind(standardized) else { continue }
            items.append(Item(url: standardized, kind: kind))
            added += 1
        }
        if added < urls.count && added == 0 && !urls.isEmpty { NSSound.beep() }
        table.reloadData()
        rebuildTargets()
        updateButtons()
    }

    private func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let child = walker?.nextObject() as? URL, out.count < 1000 {
                    if MediaProbe.quickKind(child) != nil { out.append(child) }
                }
            } else {
                out.append(url)
            }
        }
        return out
    }

    private var kindsPresent: [MediaKind] {
        MediaKind.allCases.filter { kind in items.contains { $0.kind == kind } }
    }

    // MARK: Layout

    private func buildUI() {
        let content = NSView()
        window?.contentView = content

        // File list
        for (id, title, width) in [("file", "File", 200.0), ("kind", "Kind", 54.0), ("output", "Output", 160.0), ("status", "Status", 150.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 40
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.style = .inset
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true

        // The hint sits on top of the (empty) list.
        let listArea = NSView()
        listArea.translatesAutoresizingMaskIntoConstraints = false
        listArea.addSubview(scroll)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        listArea.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: listArea.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: listArea.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: listArea.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listArea.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: listArea.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listArea.centerYAnchor, constant: 10),
        ])

        addButton = SettingsUI.button("") { [weak self] in self?.chooseFiles() }
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Files")
        addButton.bezelStyle = .smallSquare
        addButton.toolTip = "Add files"
        removeButton = SettingsUI.button("") { [weak self] in self?.removeSelected() }
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")
        removeButton.bezelStyle = .smallSquare
        removeButton.toolTip = "Remove the selected files"
        let listButtons = NSStackView(views: [addButton, removeButton])
        listButtons.spacing = 0

        // Targets and options
        targetsStack.orientation = .vertical
        targetsStack.alignment = .leading
        targetsStack.spacing = 8

        customizeButton.bezelStyle = .disclosure
        customizeButton.setButtonType(.pushOnPushOff)
        customizeButton.title = ""
        customizeButton.target = self
        customizeButton.action = #selector(toggleCustomize)
        let customizeLabel = NSTextField(labelWithString: "Customize")
        let customizeRow = NSStackView(views: [customizeButton, customizeLabel])
        customizeRow.spacing = 4
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleCustomizeFromLabel))
        customizeLabel.addGestureRecognizer(click)

        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 10
        optionsStack.isHidden = true
        optionsStack.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)

        // Output
        outputPopup.target = self
        outputPopup.action = #selector(outputChanged)
        rebuildOutputPopup()
        let outputRow = NSStackView(views: [Self.label("Save to:"), outputPopup])
        outputRow.alignment = .firstBaseline
        outputRow.spacing = 8

        // Bottom bar
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        revealButton = SettingsUI.button("Show in Finder") { [weak self] in self?.reveal() }
        cancelButton = SettingsUI.button("Cancel") { [weak self] in self?.job?.cancel() }
        convertButton = SettingsUI.button("Convert") { [weak self] in self?.convert() }
        convertButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottom = NSStackView(views: [statusLabel, spacer, revealButton, cancelButton, convertButton])
        bottom.spacing = 8
        bottom.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true

        let main = NSStackView(views: [listArea, listButtons, targetsStack, customizeRow, optionsStack, SettingsUI.separatorView(Self.width - 32), outputRow, bottom])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 10
        main.setCustomSpacing(2, after: listArea)
        main.setCustomSpacing(14, after: listButtons)
        main.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(main)
        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            main.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            main.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            main.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private static func label(_ text: String, width: CGFloat = 70) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: Self.width, height: size.height)))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    // MARK: Targets (format + preset per kind)

    /// Which presets apply to a kind with its chosen format.
    private func presetKind(_ kind: MediaKind) -> MediaKind {
        guard let format = formats[kind] ?? nil else { return kind }
        return ConvertRoute(source: kind, format: format)?.presetKind ?? kind
    }

    private func preset(_ kind: MediaKind) -> Preset {
        let pk = presetKind(kind)
        let format = formats[kind] ?? nil
        if let p = feature.converter.presets.find(presets[kind] ?? ""), p.kind == pk, BuiltInPresets.suits(p, format: format) { return p }
        return feature.converter.presets.find(BuiltInPresets.defaultID(for: pk, format: format)) ?? BuiltInPresets.defaultPreset(for: pk)
    }

    private func effective(_ kind: MediaKind) -> ConvertOptions {
        preset(kind).options.overlaid(by: overrides[kind] ?? ConvertOptions())
    }

    private func override(_ kind: MediaKind, _ change: (inout ConvertOptions) -> Void) {
        var o = overrides[kind] ?? ConvertOptions()
        change(&o)
        overrides[kind] = o
    }

    private func rebuildTargets() {
        targetsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let kinds = kindsPresent
        if kinds.isEmpty {
            targetsStack.addArrangedSubview(SettingsUI.note("Add files to choose what they become. Defaults come from Settings → Converter."))
        }
        for kind in kinds {
            let formatPopup = ChoicePopup(formatChoices(kind), selected: (formats[kind] ?? nil)?.rawValue ?? ConverterFeature.sameFormat) { [weak self] value in
                self?.formatChanged(kind, value)
            }
            formatPopup.widthAnchor.constraint(equalToConstant: 170).isActive = true
            let presetList = feature.converter.presets.forKind(presetKind(kind)).filter { BuiltInPresets.suits($0, format: formats[kind] ?? nil) }
            let presetPopup = ChoicePopup(presetList.map { ($0.name + ($0.builtIn ? "" : " ★"), $0.id) }, selected: preset(kind).id) { [weak self] id in
                self?.presets[kind] = id
                self?.overrides[kind] = nil
                self?.rebuildTargets()
            }
            presetPopup.toolTip = preset(kind).summary
            presetPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let edited = !(overrides[kind] ?? ConvertOptions()).isEmpty
            let modified = NSTextField(labelWithString: edited ? "(customized)" : "")
            modified.textColor = .secondaryLabelColor
            let row = NSStackView(views: [Self.label(kind.pluralTitle + ":"), formatPopup, NSTextField(labelWithString: "Preset:"), presetPopup, modified])
            row.alignment = .firstBaseline
            row.spacing = 8
            targetsStack.addArrangedSubview(row)
        }
        rebuildOptions()
        fitWindow()
    }

    private func formatChoices(_ kind: MediaKind) -> [(String, String)] {
        var choices: [(String, String)] = []
        if kind == .image { choices.append(("Same as original", ConverterFeature.sameFormat)) }
        for f in OutputFormat.targets(for: kind) {
            var title = f.title
            if kind == .video && f == .gif { title = "Animated GIF" }
            if kind == .video && f.isAudio { title += " (audio only)" }
            choices.append((title, f.rawValue))
        }
        return choices
    }

    private func formatChanged(_ kind: MediaKind, _ value: String) {
        let before = presetKind(kind)
        formats[kind] = value == ConverterFeature.sameFormat ? nil : OutputFormat(rawValue: value)
        if presetKind(kind) != before || !BuiltInPresets.suits(preset(kind), format: formats[kind] ?? nil)
            || feature.converter.presets.find(presets[kind] ?? "")?.id != preset(kind).id {
            presets[kind] = preset(kind).id
            overrides[kind] = nil
        }
        table.reloadData()
        rebuildTargets()
    }

    // MARK: Customize

    @objc private func toggleCustomizeFromLabel() {
        customizeButton.state = customizeButton.state == .on ? .off : .on
        toggleCustomize()
    }

    @objc private func toggleCustomize() {
        optionsStack.isHidden = customizeButton.state != .on
        fitWindow()
    }

    private func rebuildOptions() {
        optionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let kinds = kindsPresent
        guard !kinds.isEmpty else {
            optionsStack.addArrangedSubview(SettingsUI.note("Add files to see their options."))
            return
        }
        for kind in kinds {
            let format = formats[kind] ?? nil
            let header = NSTextField(labelWithString: "\(kind.pluralTitle) → \(format?.title ?? "same format")")
            header.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize + 1)
            optionsStack.addArrangedSubview(header)
            let grid = NSGridView()
            grid.rowSpacing = 6
            grid.columnSpacing = 8
            grid.rowAlignment = .firstBaseline
            switch presetKind(kind) {
            case .video: videoOptions(kind, format: format ?? .mp4, grid: grid)
            case .image: imageOptions(kind, grid: grid)
            case .audio: audioOptions(kind, format: format ?? .m4a, grid: grid)
            }
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 0).width = 90
            optionsStack.addArrangedSubview(grid)
        }
        let save = SettingsUI.button("Save as Preset…") { [weak self] in self?.saveAsPreset() }
        save.controlSize = .small
        optionsStack.addArrangedSubview(save)
    }

    private func addRow(_ grid: NSGridView, _ title: String, _ control: NSView) {
        grid.addRow(with: [NSTextField(labelWithString: title), control])
    }

    private func qualitySlider(_ kind: MediaKind, value: Int, enabled: Bool = true) -> NSView {
        let label = NSTextField(labelWithString: String(value))
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let slider = ClosureSlider(value: Double(value), min: 0, max: 100) { [weak self] v in
            label.stringValue = String(Int(v))
            self?.override(kind) { $0.quality = Int(v) }
        }
        slider.isEnabled = enabled
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let hint = NSTextField(labelWithString: "smaller ← → better")
        hint.textColor = .tertiaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let row = NSStackView(views: [slider, label, hint])
        row.spacing = 8
        return row
    }

    private func stripCheckbox(_ kind: MediaKind, _ o: ConvertOptions) -> NSButton {
        ClosureCheckbox(title: "Remove metadata (EXIF, GPS location; keeps the color profile)", on: o.stripMetadata == true) { [weak self] on in
            self?.override(kind) { $0.stripMetadata = on }
        }
    }

    private func videoOptions(_ kind: MediaKind, format: OutputFormat, grid: NSGridView) {
        let o = effective(kind)
        let isGIF = format == .gif
        let copy = o.copyStreams == true && !isGIF
        if !isGIF {
            addRow(grid, "", ClosureCheckbox(title: "Copy streams without re-encoding (Instant)", on: copy) { [weak self] on in
                self?.override(kind) { $0.copyStreams = on }
                self?.rebuildOptions()
            })
            let codecs = VideoCodec.allCases.filter { $0.containers.contains(format) }
            let codec = o.videoCodec.flatMap { codecs.contains($0) ? $0 : nil } ?? VideoCodec.fallback(for: format)
            let codecPopup = ChoicePopup(codecs.map { ($0.title, $0.rawValue) }, selected: codec.rawValue) { [weak self] v in
                self?.override(kind) { $0.videoCodec = VideoCodec(rawValue: v) }
            }
            codecPopup.isEnabled = !copy
            addRow(grid, "Codec:", codecPopup)
        }
        addRow(grid, "Quality:", qualitySlider(kind, value: o.quality ?? 65, enabled: !copy))
        let sizes: [(String, String)] = [("Original", "original"), ("2160p (4K)", "2160"), ("1440p", "1440"), ("1080p", "1080"), ("720p", "720"), ("480p", "480")]
        let size = ChoicePopup(withCurrent(sizes, (o.maxSize ?? (isGIF ? .box(width: 640, height: 640) : .original)).description), selected: (o.maxSize ?? (isGIF ? .box(width: 640, height: 640) : .original)).description) { [weak self] v in
            self?.override(kind) { $0.maxSize = MaxSize.parse(v) }
        }
        size.isEnabled = !copy
        addRow(grid, "Max size:", size)
        let fpsChoices: [(String, String)] = [("Original", "0"), ("60 fps", "60"), ("30 fps", "30"), ("24 fps", "24"), ("15 fps", "15")]
        let fps = ChoicePopup(withCurrent(fpsChoices, String(o.fps ?? (isGIF ? 15 : 0))), selected: String(o.fps ?? (isGIF ? 15 : 0))) { [weak self] v in
            self?.override(kind) { $0.fps = Int(v) }
        }
        fps.isEnabled = !copy
        addRow(grid, "Frame rate:", fps)
        if !isGIF {
            let audio = ChoicePopup(AudioTrack.allCases.map { ($0.title, $0.rawValue) }, selected: (o.audioTrack ?? .copy).rawValue) { [weak self] v in
                self?.override(kind) { $0.audioTrack = AudioTrack(rawValue: v) }
            }
            audio.isEnabled = !copy
            addRow(grid, "Audio:", audio)
            addRow(grid, "", stripCheckbox(kind, o))
        }
    }

    private func imageOptions(_ kind: MediaKind, grid: NSGridView) {
        let o = effective(kind)
        addRow(grid, "Quality:", qualitySlider(kind, value: o.quality ?? 90))
        let sizes: [(String, String)] = [("Original", "original"), ("75%", "75%"), ("50%", "50%"), ("25%", "25%"),
                                         ("4096 px", "4096"), ("2048 px", "2048"), ("1024 px", "1024")]
        let current = (o.maxSize ?? .original).description
        addRow(grid, "Size:", ChoicePopup(withCurrent(sizes, current), selected: current) { [weak self] v in
            self?.override(kind) { $0.maxSize = MaxSize.parse(v) }
        })
        addRow(grid, "", stripCheckbox(kind, o))
    }

    private func audioOptions(_ kind: MediaKind, format: OutputFormat, grid: NSGridView) {
        let o = effective(kind)
        let alac = format == .m4a && o.audioCodec == .alac
        let lossless = format.isLosslessAudio || alac
        if format == .m4a {
            addRow(grid, "Codec:", ChoicePopup(AudioCodec.allCases.map { ($0.title, $0.rawValue) }, selected: (o.audioCodec ?? .aac).rawValue) { [weak self] v in
                self?.override(kind) { $0.audioCodec = AudioCodec(rawValue: v) }
                self?.rebuildOptions()
            })
        }
        if lossless {
            var depths: [(String, String)] = [("Original", "original"), ("16-bit", "16"), ("24-bit", "24")]
            if format == .wav || format == .aiff { depths.append(("32-bit float", "32f")) }
            addRow(grid, "Bit depth:", ChoicePopup(depths, selected: o.bitDepth?.rawValue ?? "original") { [weak self] v in
                self?.override(kind) { $0.bitDepth = BitDepth(rawValue: v) }
            })
        } else {
            addRow(grid, "Quality:", qualitySlider(kind, value: o.quality ?? 70))
            let rates: [(String, String)] = [("Auto (from quality)", "0")] + [96, 128, 160, 192, 256, 320].map { ("\($0) kbps", String($0)) }
            addRow(grid, "Bitrate:", ChoicePopup(withCurrent(rates, String(o.audioBitrate ?? 0)), selected: String(o.audioBitrate ?? 0)) { [weak self] v in
                self?.override(kind) { $0.audioBitrate = Int(v).flatMap { $0 > 0 ? $0 : nil } }
            })
        }
        if format != .opus {
            var rates: [(String, String)] = [("Original", "0"), ("44.1 kHz", "44100"), ("48 kHz", "48000")]
            if format != .mp3 { rates += [("88.2 kHz", "88200"), ("96 kHz", "96000")] }
            addRow(grid, "Sample rate:", ChoicePopup(withCurrent(rates, String(o.sampleRate ?? 0)), selected: String(o.sampleRate ?? 0)) { [weak self] v in
                self?.override(kind) { $0.sampleRate = Int(v) }
            })
        }
        addRow(grid, "Channels:", ChoicePopup([("Original", "0"), ("Mono", "1"), ("Stereo", "2")], selected: String(o.channels ?? 0)) { [weak self] v in
            self?.override(kind) { $0.channels = Int(v) }
        })
        addRow(grid, "", ClosureCheckbox(title: "Remove tags (title, artist, artwork…)", on: o.stripMetadata == true) { [weak self] on in
            self?.override(kind) { $0.stripMetadata = on }
        })
    }

    /// Adds the current value to a list of choices when a preset uses one that isn't listed.
    private func withCurrent(_ choices: [(String, String)], _ current: String) -> [(String, String)] {
        choices.contains { $0.1 == current } ? choices : choices + [(current, current)]
    }

    private func saveAsPreset() {
        guard let kind = kindsPresent.first(where: { !(overrides[$0] ?? ConvertOptions()).isEmpty }) ?? kindsPresent.first else { return }
        let alert = NSAlert()
        alert.messageText = "Save \(kind.rawValue) settings as a preset"
        alert.informativeText = "Saved presets appear in the preset menu, in Settings and in `lodestone presets list`."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Preset name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .alertFirstButtonReturn else { return }
                do {
                    let preset = try self.feature.converter.presets.save(name: field.stringValue, kind: self.presetKind(kind),
                                                                        format: self.formats[kind] ?? nil, options: self.effective(kind))
                    self.presets[kind] = preset.id
                    self.overrides[kind] = nil
                    self.rebuildTargets()
                } catch {
                    NSAlert(error: error).beginSheetModal(for: window)
                }
            }
        }
    }

    // MARK: Output location

    private func rebuildOutputPopup() {
        outputPopup.removeAllItems()
        outputPopup.addItems(withTitles: ["Next to the originals", "Downloads"])
        if let outputFolder { outputPopup.addItem(withTitle: outputFolder.lastPathComponent) }
        outputPopup.menu?.addItem(.separator())
        outputPopup.addItem(withTitle: "Choose Folder…")
        switch outputChoice {
        case "downloads": outputPopup.selectItem(at: 1)
        case "folder" where outputFolder != nil: outputPopup.selectItem(at: 2)
        default: outputPopup.selectItem(at: 0)
        }
        if let outputFolder { outputPopup.item(at: 2)?.toolTip = outputFolder.path }
    }

    @objc private func outputChanged() {
        let index = outputPopup.indexOfSelectedItem
        if index == outputPopup.numberOfItems - 1 {
            let open = NSOpenPanel()
            open.canChooseDirectories = true
            open.canChooseFiles = false
            open.canCreateDirectories = true
            open.prompt = "Choose"
            if open.runModal() == .OK, let url = open.url {
                outputFolder = url
                outputChoice = "folder"
            }
        } else {
            outputChoice = index == 0 ? "source" : index == 1 ? "downloads" : "folder"
        }
        rebuildOutputPopup()
    }

    private var outputDirectory: URL? {
        switch outputChoice {
        case "downloads": FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case "folder": outputFolder
        default: nil
        }
    }

    // MARK: Actions

    private func chooseFiles() {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = true
        open.allowedContentTypes = [.image, .movie, .audio, .audiovisualContent]
        guard let window else { return }
        open.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .OK { self?.add(open.urls) }
            }
        }
    }

    private func removeSelected() {
        guard job == nil else { return }
        let rows = table.selectedRowIndexes
        if rows.isEmpty {
            // Nothing selected: clear the finished ones.
            items.removeAll { !$0.needsConverting }
        } else {
            items = items.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        }
        table.reloadData()
        rebuildTargets()
        updateButtons()
    }

    private func convert() {
        guard job == nil else { return }
        let pending = items.filter(\.needsConverting)
        guard !pending.isEmpty else { return }
        var targets: [MediaKind: ConvertTarget] = [:]
        for kind in kindsPresent {
            targets[kind] = ConvertTarget(format: formats[kind] ?? nil, preset: preset(kind).id, overrides: overrides[kind] ?? ConvertOptions())
        }
        let request = ConvertRequest(inputs: pending.map(\.url), targets: targets, outputDirectory: outputDirectory)
        runningItems = pending
        pending.forEach { $0.state = .running(0); $0.output = nil }
        lastOutputs = []
        table.reloadData()
        statusLabel.stringValue = "Converting \(pending.count) file\(pending.count == 1 ? "" : "s")…"
        Log.shared.info("converter", "panel.convert", ["count": .number(Double(pending.count))])
        let title = pending.count == 1 ? "Convert \(pending[0].url.lastPathComponent)" : "Convert \(pending.count) files"
        job = feature.run(request, title: title, onEvent: { [weak self] in self?.handle($0) }) { [weak self] results in
            self?.finished(results)
        }
        updateButtons()
    }

    private func handle(_ event: ConvertEvent) {
        func reload(_ i: Int) {
            guard let row = items.firstIndex(where: { $0 === runningItems[i] }) else { return }
            table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
        switch event {
        case .planned(let plans):
            for (i, plan) in plans.enumerated() where i < runningItems.count {
                switch plan {
                case .success(let p): runningItems[i].output = p.output.lastPathComponent
                case .failure(let f): runningItems[i].state = .failed(f.error.message)
                }
            }
            table.reloadData()
        case .started(let i, _):
            runningItems[i].state = .running(0)
            reload(i)
        case .progress(let i, let f):
            runningItems[i].state = .running(f)
            reload(i)
        case .finished(let i, let r):
            runningItems[i].state = .done(r)
            runningItems[i].output = URL(fileURLWithPath: r.output).lastPathComponent
            lastOutputs.append(URL(fileURLWithPath: r.output))
            reload(i)
        case .failed(let i, _, let error):
            runningItems[i].state = error.code == "cancelled" ? .cancelled : .failed(error.message)
            reload(i)
        }
    }

    private func finished(_ results: [Result<ConvertResult, ConvertFailure>]) {
        job = nil
        for item in runningItems {
            if case .running = item.state { item.state = .cancelled }
        }
        runningItems = []
        table.reloadData()
        let done = results.filter { (try? $0.get()) != nil }.count
        let failed = results.count - done
        var text = "\(done) converted"
        if failed > 0 { text += ", \(failed) not converted" }
        let saved = results.compactMap { try? $0.get() }.reduce(Int64(0)) { $0 + $1.bytesIn - $1.bytesOut }
        if saved > 0 { text += " — \(ByteCountFormatter.string(fromByteCount: saved, countStyle: .file)) saved" }
        statusLabel.stringValue = text
        updateButtons()
    }

    private func reveal() {
        guard !lastOutputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(lastOutputs)
    }

    private func updateButtons() {
        let running = job != nil
        convertButton.isEnabled = !running && items.contains(where: \.needsConverting)
        cancelButton.isHidden = !running
        revealButton.isHidden = running || lastOutputs.isEmpty
        removeButton.isEnabled = !running && !items.isEmpty
        addButton.isEnabled = !running
        emptyLabel.isHidden = !items.isEmpty
        if !running && items.isEmpty { statusLabel.stringValue = "" }
        targetsStack.arrangedSubviews.forEach { setEnabled($0, !running) }
        optionsStack.arrangedSubviews.forEach { setEnabled($0, !running) }
    }

    private func setEnabled(_ view: NSView, _ enabled: Bool) {
        if let control = view as? NSControl, !(control is NSTextField) { control.isEnabled = enabled }
        view.subviews.forEach { setEnabled($0, enabled) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        switch tableColumn?.identifier.rawValue {
        case "file":
            let cell = TextCell(icon: true)
            cell.textField?.stringValue = item.url.lastPathComponent
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.toolTip = item.url.path
            return cell
        case "kind":
            let cell = TextCell(icon: false)
            cell.textField?.stringValue = item.kind.title
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        case "output":
            let cell = TextCell(icon: false)
            let format = formats[item.kind] ?? nil
            cell.textField?.stringValue = item.output ?? "→ \(format?.fileExtension ?? "same format")"
            cell.textField?.textColor = item.output == nil ? .tertiaryLabelColor : .labelColor
            return cell
        default:
            let cell = StatusCell()
            cell.show(item.state)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard job == nil, info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        add(urls)
        return true
    }
}

// MARK: - Small controls

private final class TextCell: NSTableCellView {
    init(icon: Bool) {
        super.init(frame: .zero)
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        textField = text
        var constraints = [text.centerYAnchor.constraint(equalTo: centerYAnchor), text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2)]
        if icon {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            addSubview(image)
            imageView = image
            constraints += [image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), image.centerYAnchor.constraint(equalTo: centerYAnchor),
                            image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16),
                            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6)]
        } else {
            constraints.append(text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class StatusCell: NSTableCellView {
    private let bar = NSProgressIndicator()
    private let percent = NSTextField(labelWithString: "")
    private let text = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        for label in [text, percent] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
            label.textColor = .secondaryLabelColor
        }
        for v in [bar, percent, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            bar.widthAnchor.constraint(equalToConstant: 60),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            percent.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 6),
            percent.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ state: ConvertPanelController.Item.State) {
        let running: Bool
        if case .running = state { running = true } else { running = false }
        bar.isHidden = !running
        percent.isHidden = !running
        text.isHidden = running
        text.textColor = .secondaryLabelColor
        toolTip = nil
        switch state {
        case .pending:
            text.stringValue = "Waiting"
        case .running(let p):
            bar.doubleValue = p
            percent.stringValue = "\(Int(p * 100))%"
        case .done(let r):
            text.textColor = .systemGreen
            let ratio = r.bytesIn > 0 ? " · \(Int((Double(r.bytesOut) / Double(r.bytesIn) * 100).rounded()))%" : ""
            text.stringValue = "✓ \(ByteCountFormatter.string(fromByteCount: r.bytesOut, countStyle: .file))\(ratio)"
            toolTip = r.output
        case .failed(let message):
            text.textColor = .systemRed
            text.stringValue = "Failed: \(message)"
            toolTip = message
        case .cancelled:
            text.stringValue = "Cancelled"
        }
    }
}

/// A pop-up of (title, value) choices that calls back with the chosen value.
final class ChoicePopup: NSPopUpButton {
    private var values: [String] = []
    private let onChange: (String) -> Void

    init(_ choices: [(String, String)], selected: String, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero, pullsDown: false)
        values = choices.map(\.1)
        addItems(withTitles: choices.map(\.0))
        if let i = values.firstIndex(of: selected) { selectItem(at: i) }
        target = self
        action = #selector(changed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        guard indexOfSelectedItem >= 0, indexOfSelectedItem < values.count else { return }
        onChange(values[indexOfSelectedItem])
    }
}

private final class ClosureSlider: NSSlider {
    private let onChange: (Double) -> Void

    init(value: Double, min: Double, max: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        minValue = min
        maxValue = max
        doubleValue = value
        isContinuous = true
        target = self
        action = #selector(changed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { onChange(doubleValue.rounded()) }
}

private final class ClosureCheckbox: NSButton {
    private let onChange: (Bool) -> Void

    init(title: String, on: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        state = on ? .on : .off
        target = self
        action = #selector(changed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { onChange(state == .on) }
}

extension SettingsUI {
    /// A horizontal rule of the given width.
    static func separatorView(_ width: CGFloat) -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        return box
    }
}
