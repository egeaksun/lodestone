import AppKit
import LodestoneCore
import LodestoneKit
import UniformTypeIdentifiers

/// PDF tools: merge, compress, images → PDF, extract/split, rotate, export pages as images and OCR.
/// The work happens in `LodestoneKit.PDFTools`, which the CLI (`lodestone pdf ...`) runs directly.
/// Nothing runs while idle: every tool starts from a drop, a Finder service, the menu or IPC.
@MainActor
final class PDFToolsFeature: Feature {
    let id = "pdf"
    let title = "PDF"
    let symbol = "doc.richtext"

    static let levelKey = "pdf.compressionLevel"
    static let askLevelKey = "pdf.askCompressionLevel"
    static let pageSizeKey = "pdf.pageSize"
    static let marginKey = "pdf.margin"
    static let askPageSizeKey = "pdf.askPageSize"
    static let imageFormatKey = "pdf.imageFormat"
    static let imageDPIKey = "pdf.imageDPI"
    static let askImageExportKey = "pdf.askImageExport"
    static let afterKey = "pdf.afterward"

    private var context: AppContext!

    var settings: [SettingDefinition] {
        [
            SettingDefinition(Self.levelKey, title: "Compression level", kind: .choice(PDFCompressionLevel.allCases.map(\.rawValue)), default: "balanced",
                              help: "light keeps print quality, balanced suits screen and email, strong makes the smallest files."),
            SettingDefinition(Self.askLevelKey, title: "Ask for the level each time", kind: .bool, default: true),
            SettingDefinition(Self.pageSizeKey, title: "Page size for Images to PDF", kind: .choice(PDFPageSize.allCases.map(\.rawValue)), default: "fit",
                              help: "fit makes each page the size of its image."),
            SettingDefinition(Self.marginKey, title: "Margin around images, in points", kind: .int(range: 0...144), default: 0,
                              help: "72 points = 1 inch."),
            SettingDefinition(Self.askPageSizeKey, title: "Ask for page size and margin each time", kind: .bool, default: true),
            SettingDefinition(Self.imageFormatKey, title: "Format for exported pages", kind: .choice(PDFImageFormat.allCases.map(\.rawValue)), default: "png"),
            SettingDefinition(Self.imageDPIKey, title: "Resolution for exported pages (dpi)", kind: .int(range: 36...600), default: 150),
            SettingDefinition(Self.askImageExportKey, title: "Ask for format and resolution each time", kind: .bool, default: true),
            SettingDefinition(Self.afterKey, title: "When a PDF is ready", kind: .choice(AfterJob.allCases.map(\.rawValue)), default: "reveal"),
        ]
    }

    private static let commandTitles: [(id: String, title: String)] = [
        ("pdf.merge", "Merge PDFs"),
        ("pdf.compress", "Compress PDF"),
        ("pdf.fromImages", "Images to PDF"),
        ("pdf.extract", "Extract or Split Pages"),
        ("pdf.rotate", "Rotate Pages"),
        ("pdf.toImages", "Export Pages as Images"),
        ("pdf.ocr", "Make Searchable (OCR)"),
    ]

    var commands: [AppCommand] {
        Self.commandTitles.map { item in
            AppCommand(item.id, item.title) { [weak self] in self?.pickAndRun(item.id) }
        }
    }

    var fileActions: [FileAction] {
        [
            FileAction(id: "pdf.merge", title: "Merge PDFs", accepts: { $0.count >= 2 && FileKind.allPDFs($0) }) { [weak self] in self?.merge($0) },
            FileAction(id: "pdf.compress", title: "Compress PDF", accepts: FileKind.allPDFs) { [weak self] in self?.compress($0) },
            FileAction(id: "pdf.fromImages", title: "Images to PDF", accepts: FileKind.allImages) { [weak self] in self?.fromImages($0) },
            FileAction(id: "pdf.extract", title: "Extract or Split Pages…", accepts: { $0.count == 1 && FileKind.allPDFs($0) }) { [weak self] in self?.extract($0) },
            FileAction(id: "pdf.rotate", title: "Rotate PDF Pages…", accepts: FileKind.allPDFs) { [weak self] in self?.rotate($0) },
            FileAction(id: "pdf.toImages", title: "Export PDF Pages as Images", accepts: FileKind.allPDFs) { [weak self] in self?.toImages($0) },
            FileAction(id: "pdf.ocr", title: "Make PDF Searchable (OCR)", accepts: FileKind.allPDFs) { [weak self] in self?.ocr($0) },
        ]
    }

    func start(_ context: AppContext) {
        self.context = context
    }

    // MARK: Menu

    func menuItems() -> [NSMenuItem] {
        // Each item asks for files first, hence the ellipsis.
        [NSMenuItem(title: "PDF Tools", submenu: Self.commandTitles.map { context.menuItem($0.id, title: $0.title + "…") })]
    }

    private func pickAndRun(_ id: String) {
        let pdf = [UTType.pdf]
        let images = [UTType.image]
        let urls: [URL]?
        switch id {
        case "pdf.merge": urls = FileKind.pick(pdf, multiple: true, prompt: "Merge", message: "Choose two or more PDFs. They're merged in name order.")
        case "pdf.compress": urls = FileKind.pick(pdf, multiple: true, prompt: "Compress", message: "Choose PDFs to compress.")
        case "pdf.fromImages": urls = FileKind.pick(images, multiple: true, prompt: "Make PDF", message: "Choose images. Each becomes a page, in name order.")
        case "pdf.extract": urls = FileKind.pick(pdf, multiple: false, prompt: "Choose", message: "Choose a PDF to take pages from.")
        case "pdf.rotate": urls = FileKind.pick(pdf, multiple: true, prompt: "Choose", message: "Choose PDFs to rotate.")
        case "pdf.toImages": urls = FileKind.pick(pdf, multiple: true, prompt: "Export", message: "Choose PDFs to export as images.")
        case "pdf.ocr": urls = FileKind.pick(pdf, multiple: true, prompt: "Make Searchable", message: "Choose scanned PDFs to make searchable.")
        default: urls = nil
        }
        guard let urls, let action = fileActions.first(where: { $0.id == id }) else { return }
        guard action.accepts(urls) else {
            NSSound.beep()
            if id == "pdf.merge" { OptionsPanel.error("Choose at least two PDFs", "Merging needs two or more PDFs.") }
            return
        }
        Log.shared.info("files", "action", ["action": .string(id), "count": .number(Double(urls.count)), "source": "menu"])
        action.perform(urls)
    }

    // MARK: Actions

    private func merge(_ urls: [URL]) {
        let inputs = FileKind.byName(urls)
        ToolJob.run(context, title: "Merging \(inputs.count) PDFs", afterKey: Self.afterKey) { progress in
            let r = try await PDFTools.merge(inputs, progress: progress)
            let output = URL(fileURLWithPath: r.output)
            return .init(files: [output], summary: "\(output.lastPathComponent): \(r.pages) pages")
        }
    }

    private func compress(_ urls: [URL]) {
        var level = PDFCompressionLevel(rawValue: context.settings.string(Self.levelKey)) ?? .balanced
        if context.settings.bool(Self.askLevelKey) {
            let panel = PDFOptionsPanels.compression(selected: level)
            let answer = OptionsPanel.run(context, title: urls.count == 1 ? "Compress \(urls[0].lastPathComponent)" : "Compress \(urls.count) PDFs",
                                          message: "Images are re-compressed; text stays sharp and selectable.",
                                          accessory: panel.view, confirm: "Compress", askKey: Self.askLevelKey)
            guard answer.confirmed else { return }
            level = panel.level()
            if answer.dontAskAgain { try? context.settings.set(Self.levelKey, .string(level.rawValue)) }
        }
        let inputs = urls
        let chosen = level
        let title = inputs.count == 1 ? "Compressing \(inputs[0].lastPathComponent)" : "Compressing \(inputs.count) PDFs"
        ToolJob.run(context, title: title, afterKey: Self.afterKey) { progress in
            var files: [URL] = []
            var lines: [String] = []
            for (i, url) in inputs.enumerated() {
                let r = try await PDFTools.compress(url, level: chosen) { p in progress((Double(i) + p) / Double(inputs.count)) }
                if let output = r.output {
                    files.append(URL(fileURLWithPath: output))
                    lines.append("\(url.lastPathComponent): \(r.message)")
                } else {
                    lines.append(r.message)
                }
            }
            return .init(files: files, summary: lines.joined(separator: "\n"))
        }
    }

    private func fromImages(_ urls: [URL]) {
        var pageSize = PDFPageSize(rawValue: context.settings.string(Self.pageSizeKey)) ?? .fit
        var margin = context.settings.int(Self.marginKey)
        if context.settings.bool(Self.askPageSizeKey) {
            let panel = PDFOptionsPanels.pageSize(selected: pageSize, margin: margin)
            let answer = OptionsPanel.run(context, title: urls.count == 1 ? "Make a PDF from \(urls[0].lastPathComponent)" : "Make a PDF from \(urls.count) images",
                                          message: "One page per image, in name order.",
                                          accessory: panel.view, confirm: "Make PDF", askKey: Self.askPageSizeKey)
            guard answer.confirmed else { return }
            (pageSize, margin) = panel.values()
            if answer.dontAskAgain {
                try? context.settings.set(Self.pageSizeKey, .string(pageSize.rawValue))
                try? context.settings.set(Self.marginKey, .number(Double(margin)))
            }
        }
        let inputs = FileKind.byName(urls)
        let (size, m) = (pageSize, Double(margin))
        ToolJob.run(context, title: "Making a PDF from \(inputs.count) image\(inputs.count == 1 ? "" : "s")", afterKey: Self.afterKey) { progress in
            let r = try await PDFTools.fromImages(inputs, pageSize: size, margin: m, progress: progress)
            let output = URL(fileURLWithPath: r.output)
            return .init(files: [output], summary: "\(output.lastPathComponent): \(r.pages) page\(r.pages == 1 ? "" : "s")")
        }
    }

    private func extract(_ urls: [URL]) {
        guard let url = urls.first else { return }
        let pageCount: Int
        do { pageCount = try PDFTools.info(url).pages } catch { return OptionsPanel.error("Can't open \(url.lastPathComponent)", (error as? IPCError)?.message ?? "\(error)") }
        let panel = PDFOptionsPanels.extract(pageCount: pageCount)
        var selection: PageRanges?
        while selection == nil {
            let answer = OptionsPanel.run(context, title: "Extract pages from \(url.lastPathComponent)",
                                          message: "\(url.lastPathComponent) has \(pageCount) page\(pageCount == 1 ? "" : "s"). The original isn't changed.",
                                          accessory: panel.view, confirm: "Extract", askKey: nil)
            guard answer.confirmed else { return }
            do {
                let ranges = try PageRanges.parse(panel.pagesText())
                _ = try ranges.groups(pageCount: pageCount)
                selection = ranges
            } catch {
                OptionsPanel.error("Check the pages", (error as? IPCError)?.message ?? "\(error)")
            }
        }
        guard let selection else { return }
        let mode = panel.mode()
        ToolJob.run(context, title: "Extracting pages from \(url.lastPathComponent)", afterKey: Self.afterKey) { progress in
            let r = try await PDFTools.extract(url, pages: selection, mode: mode, progress: progress)
            return .init(files: r.outputs.map { URL(fileURLWithPath: $0.path) },
                         summary: r.outputs.count == 1 ? URL(fileURLWithPath: r.outputs[0].path).lastPathComponent : "\(r.outputs.count) PDFs")
        }
    }

    private func rotate(_ urls: [URL]) {
        let panel = PDFOptionsPanels.rotate()
        var pages: PageRanges?
        while true {
            let answer = OptionsPanel.run(context, title: urls.count == 1 ? "Rotate pages of \(urls[0].lastPathComponent)" : "Rotate pages of \(urls.count) PDFs",
                                          message: "Saved as a copy; the original isn't changed.",
                                          accessory: panel.view, confirm: "Rotate", askKey: nil)
            guard answer.confirmed else { return }
            let text = panel.pagesText().trimmingCharacters(in: .whitespaces)
            do {
                pages = text.isEmpty ? nil : try PageRanges.parse(text)
                break
            } catch {
                OptionsPanel.error("Check the pages", (error as? IPCError)?.message ?? "\(error)")
            }
        }
        let angle = panel.angle()
        let inputs = urls
        let selection = pages
        ToolJob.run(context, title: "Rotating \(inputs.count == 1 ? inputs[0].lastPathComponent : "\(inputs.count) PDFs")", afterKey: Self.afterKey) { progress in
            var files: [URL] = []
            for (i, url) in inputs.enumerated() {
                files.append(URL(fileURLWithPath: try await PDFTools.rotate(url, angle: angle, pages: selection).output))
                progress(Double(i + 1) / Double(inputs.count))
            }
            return .init(files: files, summary: files.map(\.lastPathComponent).joined(separator: "\n"))
        }
    }

    private func toImages(_ urls: [URL]) {
        var format = PDFImageFormat(rawValue: context.settings.string(Self.imageFormatKey)) ?? .png
        var dpi = context.settings.int(Self.imageDPIKey)
        if context.settings.bool(Self.askImageExportKey) {
            let panel = PDFOptionsPanels.imageExport(format: format, dpi: dpi)
            let answer = OptionsPanel.run(context, title: urls.count == 1 ? "Export the pages of \(urls[0].lastPathComponent)" : "Export the pages of \(urls.count) PDFs",
                                          message: "Each page becomes an image in a new folder next to the PDF.",
                                          accessory: panel.view, confirm: "Export", askKey: Self.askImageExportKey)
            guard answer.confirmed else { return }
            (format, dpi) = panel.values()
            if answer.dontAskAgain {
                try? context.settings.set(Self.imageFormatKey, .string(format.rawValue))
                try? context.settings.set(Self.imageDPIKey, .number(Double(dpi)))
            }
        }
        let inputs = urls
        let (f, d) = (format, dpi)
        ToolJob.run(context, title: "Exporting pages of \(inputs.count == 1 ? inputs[0].lastPathComponent : "\(inputs.count) PDFs")", afterKey: Self.afterKey) { progress in
            var folders: [URL] = []
            var count = 0
            for (i, url) in inputs.enumerated() {
                let r = try await PDFTools.toImages(url, format: f, dpi: d) { p in progress((Double(i) + p) / Double(inputs.count)) }
                folders.append(URL(fileURLWithPath: r.folder))
                count += r.files.count
            }
            return .init(files: folders, summary: "\(count) image\(count == 1 ? "" : "s") at \(d) dpi")
        }
    }

    private func ocr(_ urls: [URL]) {
        let inputs = urls
        ToolJob.run(context, title: "Recognizing text in \(inputs.count == 1 ? inputs[0].lastPathComponent : "\(inputs.count) PDFs")", afterKey: Self.afterKey) { progress in
            var files: [URL] = []
            var lines: [String] = []
            for (i, url) in inputs.enumerated() {
                let r = try await PDFTools.makeSearchable(url) { p in progress((Double(i) + p) / Double(inputs.count)) }
                files.append(URL(fileURLWithPath: r.output))
                lines.append("\(url.lastPathComponent): text on \(r.textPagesAfter) of \(r.pages) pages")
            }
            return .init(files: files, summary: lines.joined(separator: "\n"))
        }
    }

    // MARK: Settings

    func makeSettingsView() -> NSView? {
        let gs = ExternalTool.gs.url != nil
        let levelLabels = Dictionary(uniqueKeysWithValues: PDFCompressionLevel.allCases.map { ($0.rawValue, "\($0.title) (\($0.imageDPI) dpi images)") })
        let sizeLabels = Dictionary(uniqueKeysWithValues: PDFPageSize.allCases.map { ($0.rawValue, $0.title) })
        // Laid out inside a sub-tab, so rows, notes and separators are narrower than SettingsUI's.
        let options = SettingsUI.stack([
            SettingsUI.header("Compress"),
            Self.row("Level:", SettingsUI.popup(context, Self.levelKey, labels: levelLabels)),
            SettingsUI.checkbox(context, Self.askLevelKey),
            Self.note(gs ? "Light keeps print quality, Balanced suits screen and email, Strong makes the smallest files. Uses Ghostscript."
                         : "Ghostscript isn't installed, so macOS's built-in compression is used. For smaller files: brew install ghostscript"),
            Self.separator(),
            SettingsUI.header("Images to PDF"),
            Self.row("Page size:", SettingsUI.popup(context, Self.pageSizeKey, labels: sizeLabels)),
            Self.row("Margin:", SettingsUI.slider(context, Self.marginKey) { "\(Int($0)) pt" }),
            SettingsUI.checkbox(context, Self.askPageSizeKey),
            Self.separator(),
            SettingsUI.header("Export Pages as Images"),
            Self.row("Format:", SettingsUI.popup(context, Self.imageFormatKey, labels: ["png": "PNG", "jpeg": "JPEG"])),
            Self.row("Resolution:", SettingsUI.slider(context, Self.imageDPIKey) { "\(Int($0)) dpi" }),
            SettingsUI.checkbox(context, Self.askImageExportKey),
            Self.separator(),
            Self.row("When done:", SettingsUI.popup(context, Self.afterKey, labels: AfterJob.labels)),
            Self.note("Results are saved next to the original, as \"Name (compressed).pdf\" and so on. Nothing is overwritten. From the command line: lodestone pdf --help"),
        ], spacing: 10)
        let shortcuts = SettingsUI.stack([
            SettingsUI.shortcutGrid(context, groups: [Self.commandTitles.map(\.id)]),
            Self.note("Each shortcut asks for files to work on. Dropping files on the menu bar icon or using Finder's Services menu skips that step."),
        ])
        return Self.tabs([("Options", options), ("Shortcuts", shortcuts)])
    }

    private static let innerWidth: CGFloat = 350

    private static func row(_ label: String, _ control: NSView) -> NSView {
        let text = NSTextField(labelWithString: label)
        text.alignment = .right
        text.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let stack = NSStackView(views: [text, control])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        return stack
    }

    private static func note(_ text: String) -> NSTextField {
        let label = SettingsUI.note(text)
        label.preferredMaxLayoutWidth = innerWidth
        return label
    }

    private static func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        return box
    }

    /// Sub-tabs sized to the tallest page.
    private static func tabs(_ pages: [(String, NSView)]) -> NSView {
        let tabs = NSTabView()
        var height: CGFloat = 0
        for (title, content) in pages {
            let item = NSTabViewItem()
            item.label = title
            let container = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
                content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
                content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
                content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -14),
            ])
            item.view = container
            tabs.addTabViewItem(item)
            height = max(height, content.fittingSize.height)
        }
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.heightAnchor.constraint(equalToConstant: height + 70).isActive = true
        tabs.widthAnchor.constraint(equalToConstant: SettingsUI.width - 56).isActive = true
        return tabs
    }

    // MARK: IPC

    private struct MergeParams: Decodable { var paths: [String]; var output: String? }
    private struct CompressParams: Decodable { var path: String; var level: PDFCompressionLevel?; var engine: PDFCompressionEngine?; var output: String? }
    private struct FromImagesParams: Decodable { var paths: [String]; var pageSize: PDFPageSize?; var margin: Double?; var output: String? }
    private struct ExtractParams: Decodable { var path: String; var pages: String?; var mode: PDFExtractMode?; var output: String? }
    private struct RotateParams: Decodable { var path: String; var angle: Int?; var pages: String?; var output: String? }
    private struct ToImagesParams: Decodable { var path: String; var format: PDFImageFormat?; var dpi: Int?; var pages: String?; var output: String? }
    private struct PathParams: Decodable { var path: String; var output: String? }

    nonisolated static func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

    func registerIPC(_ router: IPCRouter) {
        let out = #""output"?: path (default: next to the input)"#
        router.register("pdf.merge", summary: "Merge PDFs in order", params: #"{"paths": [path], "# + out + "}", MergeParams.self) { p in
            try await Task.detached { try await PDFTools.merge(p.paths.map(Self.url), output: p.output.map(Self.url)) }.value
        }
        router.register("pdf.compress", summary: "Compress a PDF (level defaults to the pdf.compressionLevel setting)",
                        params: #"{"path": path, "level"?: "light"|"balanced"|"strong", "engine"?: "auto"|"gs"|"pdfkit", "# + out + "}",
                        CompressParams.self) { [weak self] p in
            let level = p.level ?? PDFCompressionLevel(rawValue: self?.context.settings.string(Self.levelKey) ?? "") ?? .balanced
            return try await Task.detached {
                try await PDFTools.compress(Self.url(p.path), output: p.output.map(Self.url), level: level, engine: p.engine ?? .auto)
            }.value
        }
        router.register("pdf.fromImages", summary: "Make a PDF with one page per image (defaults from settings)",
                        params: #"{"paths": [path], "pageSize"?: "fit"|"a4"|"letter", "margin"?: points, "# + out + "}",
                        FromImagesParams.self) { [weak self] p in
            let size = p.pageSize ?? PDFPageSize(rawValue: self?.context.settings.string(Self.pageSizeKey) ?? "") ?? .fit
            let margin = p.margin ?? Double(self?.context.settings.int(Self.marginKey) ?? 0)
            return try await Task.detached {
                try await PDFTools.fromImages(p.paths.map(Self.url), output: p.output.map(Self.url), pageSize: size, margin: margin)
            }.value
        }
        router.register("pdf.extract", summary: "Copy pages into new PDFs (mode: combined, perRange or perPage)",
                        params: #"{"path": path, "pages"?: "1-3,5,8-" (default all), "mode"?: string, "output"?: path or folder}"#,
                        ExtractParams.self) { p in
            let pages = try p.pages.map(PageRanges.parse) ?? .all
            return try await Task.detached {
                try await PDFTools.extract(Self.url(p.path), pages: pages, mode: p.mode ?? .combined, output: p.output.map(Self.url))
            }.value
        }
        router.register("pdf.rotate", summary: "Rotate pages clockwise by a multiple of 90°",
                        params: #"{"path": path, "angle"?: 90, "pages"?: "1-3" (default all), "# + out + "}", RotateParams.self) { p in
            let pages = try p.pages.map(PageRanges.parse)
            return try await Task.detached {
                try await PDFTools.rotate(Self.url(p.path), angle: p.angle ?? 90, pages: pages, output: p.output.map(Self.url))
            }.value
        }
        router.register("pdf.toImages", summary: "Render pages as images into a folder (defaults from settings)",
                        params: #"{"path": path, "format"?: "png"|"jpeg", "dpi"?: int, "pages"?: string, "output"?: folder}"#,
                        ToImagesParams.self) { [weak self] p in
            let format = p.format ?? PDFImageFormat(rawValue: self?.context.settings.string(Self.imageFormatKey) ?? "") ?? .png
            let dpi = p.dpi ?? self?.context.settings.int(Self.imageDPIKey) ?? 150
            let pages = try p.pages.map(PageRanges.parse)
            return try await Task.detached {
                try await PDFTools.toImages(Self.url(p.path), format: format, dpi: dpi, pages: pages, output: p.output.map(Self.url))
            }.value
        }
        router.register("pdf.info", summary: "Page count, page size, encryption and text layer", params: #"{"path": path}"#, PathParams.self) { p in
            try await Task.detached { try PDFTools.info(Self.url(p.path)) }.value
        }
        router.register("pdf.ocr", summary: "Add a selectable text layer to scanned pages", params: #"{"path": path, "# + out + "}", PathParams.self) { p in
            try await Task.detached { try await PDFTools.makeSearchable(Self.url(p.path), output: p.output.map(Self.url)) }.value
        }
    }
}
