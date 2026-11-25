import AppKit
import LodestoneCore
import LodestoneKit

/// Image, video and audio conversion: the Convert panel, quick drop actions, the Finder service and
/// the Settings tab. The engine lives in LodestoneKit (`Converter`), shared with `lodestone convert`.
@MainActor
final class ConverterFeature: Feature {
    let id = "converter"
    let title = "Converter"
    let symbol = "arrow.triangle.2.circlepath"

    enum Key {
        static let imageFormat = "converter.imageFormat"
        static let imagePreset = "converter.imagePreset"
        static let videoFormat = "converter.videoFormat"
        static let videoPreset = "converter.videoPreset"
        static let audioFormat = "converter.audioFormat"
        static let audioPreset = "converter.audioPreset"
        static let outputLocation = "converter.outputLocation"
        static let outputFolder = "converter.outputFolder"
        static let afterConvert = "converter.afterConvert"
        static let originals = "converter.originals"

        static func format(_ kind: MediaKind) -> String {
            switch kind {
            case .image: imageFormat
            case .video: videoFormat
            case .audio: audioFormat
            }
        }

        static func preset(_ kind: MediaKind) -> String {
            switch kind {
            case .image: imagePreset
            case .video: videoPreset
            case .audio: audioPreset
            }
        }
    }

    /// The image format setting's "keep the original format" value.
    static let sameFormat = "same"

    private(set) var context: AppContext!
    private var panel: ConvertPanelController?
    let converter = Converter.shared

    var settings: [SettingDefinition] {
        [
            SettingDefinition(Key.imageFormat, title: "Images convert to", kind: .choice([Self.sameFormat] + OutputFormat.targets(for: .image).map(\.rawValue)),
                              default: .string(Self.sameFormat), help: "\"same\" keeps each image's format (useful with Compress and Resize)."),
            SettingDefinition(Key.imagePreset, title: "Image preset", kind: .string, default: .string(BuiltInPresets.defaultID(for: .image)),
                              help: "Preset id; see `lodestone presets list --kind image`."),
            SettingDefinition(Key.videoFormat, title: "Video converts to", kind: .choice(OutputFormat.targets(for: .video).map(\.rawValue)),
                              default: "mp4"),
            SettingDefinition(Key.videoPreset, title: "Video preset", kind: .string, default: .string(BuiltInPresets.defaultID(for: .video)),
                              help: "Preset id; see `lodestone presets list --kind video`."),
            SettingDefinition(Key.audioFormat, title: "Audio converts to", kind: .choice(OutputFormat.targets(for: .audio).map(\.rawValue)),
                              default: "m4a"),
            SettingDefinition(Key.audioPreset, title: "Audio preset", kind: .string, default: .string(BuiltInPresets.defaultID(for: .audio)),
                              help: "Preset id; see `lodestone presets list --kind audio`."),
            SettingDefinition(Key.outputLocation, title: "Save converted files", kind: .choice(["source", "downloads", "folder"]),
                              default: "source", help: "Next to the original, in Downloads, or in converter.outputFolder."),
            SettingDefinition(Key.outputFolder, title: "Output folder", kind: .string, default: "",
                              help: "Used when converter.outputLocation is \"folder\"."),
            SettingDefinition(Key.afterConvert, title: "After converting", kind: .choice(["reveal", "notify", "nothing"]),
                              default: "notify", help: "Reveal the files in Finder, show a notification, or do nothing. Failures always notify."),
            SettingDefinition(Key.originals, title: "Originals", kind: .choice(["keep", "trash"]), default: "keep",
                              help: "Keep the originals, or move them to the Trash after a successful conversion."),
        ]
    }

    var commands: [AppCommand] {
        [AppCommand("converter.open", "Convert Files…") { [weak self] in self?.openPanel([]) }]
    }

    var fileActions: [FileAction] {
        [
            FileAction(id: "converter.convert", title: "Convert…", accepts: { urls in urls.contains { MediaProbe.quickKind($0) != nil } },
                       perform: { [weak self] in self?.openPanel($0) }),
            FileAction(id: "converter.toMP4", title: "Convert to MP4", accepts: Self.all(.video),
                       perform: { [weak self] in self?.quickConvert($0, kind: .video, format: .mp4, preset: nil, title: "Convert to MP4") }),
            FileAction(id: "converter.toWebP", title: "Convert to WebP", accepts: Self.all(.image),
                       perform: { [weak self] in self?.quickConvert($0, kind: .image, format: .webp, preset: nil, title: "Convert to WebP") }),
            FileAction(id: "converter.compress", title: "Compress Images", accepts: Self.all(.image),
                       perform: { [weak self] in self?.quickConvert($0, kind: .image, format: nil, preset: "compress", title: "Compress Images") }),
        ]
    }

    private static func all(_ kind: MediaKind) -> ([URL]) -> Bool {
        { urls in !urls.isEmpty && urls.allSatisfy { MediaProbe.quickKind($0) == kind } }
    }

    func start(_ context: AppContext) {
        self.context = context
    }

    func menuItems() -> [NSMenuItem] {
        [context.menuItem("converter.open")]
    }

    func makeSettingsView() -> NSView? {
        ConverterSettingsView.make(feature: self)
    }

    // MARK: IPC

    private struct OpenParams: Decodable { var paths: [String]? }

    func registerIPC(_ router: IPCRouter) {
        router.register("converter.open", summary: "Open the Convert panel, optionally with files added",
                        params: #"{"paths"?: [string]}"#, OpenParams.self) { [weak self] p in
            let urls = (p.paths ?? []).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
            if let missing = urls.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
                throw IPCError.notFound("\(missing.path) doesn't exist.")
            }
            self?.openPanel(urls)
            return OK()
        }
    }

    // MARK: Defaults from Settings

    /// The format and preset Settings choose for a kind. A preset that doesn't suit the format (say a
    /// video preset when video is set to become MP3) gives way to the format's default preset.
    func defaultTarget(for kind: MediaKind) -> ConvertTarget {
        let formatValue = context.settings.string(Key.format(kind))
        let format = formatValue == Self.sameFormat ? nil : OutputFormat(rawValue: formatValue)
        let presetKind = format.flatMap { ConvertRoute(source: kind, format: $0)?.presetKind } ?? kind
        let presetID = context.settings.string(Key.preset(kind))
        let preset = converter.presets.find(presetID).flatMap { $0.kind == presetKind && BuiltInPresets.suits($0, format: format) ? $0.id : nil }
            ?? BuiltInPresets.defaultID(for: presetKind, format: format)
        return ConvertTarget(format: format, preset: preset)
    }

    /// Where Settings says converted files go. Nil: next to the original.
    var outputDirectory: URL? {
        switch context.settings.string(Key.outputLocation) {
        case "downloads": FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case "folder":
            context.settings.string(Key.outputFolder).isEmpty ? nil
                : URL(fileURLWithPath: (context.settings.string(Key.outputFolder) as NSString).expandingTildeInPath)
        default: nil
        }
    }

    // MARK: Entry points

    func openPanel(_ urls: [URL]) {
        if panel == nil { panel = ConvertPanelController(feature: self) }
        panel?.add(urls)
        panel?.show()
        Log.shared.info("converter", "panel.open", ["count": .number(Double(urls.count))])
    }

    /// Converts immediately with the Settings defaults, overriding the format or preset.
    private func quickConvert(_ urls: [URL], kind: MediaKind, format: OutputFormat?, preset: String?, title: String) {
        var target = defaultTarget(for: kind)
        if let format {
            target.format = format
            // Keep the default preset only if it suits the new format.
            let presetKind = ConvertRoute(source: kind, format: format)?.presetKind ?? kind
            let current = converter.presets.find(target.preset ?? "")
            if current?.kind != presetKind || !(current.map { BuiltInPresets.suits($0, format: format) } ?? false) {
                target.preset = BuiltInPresets.defaultID(for: presetKind, format: format)
            }
        }
        if let preset {
            target.preset = preset
            target.format = nil
        }
        let request = ConvertRequest(inputs: urls, target: target, outputDirectory: outputDirectory)
        Log.shared.info("converter", "quick", ["action": .string(title), "count": .number(Double(urls.count))])
        run(request, title: title)
    }

    // MARK: Running jobs

    /// Runs a request with menu bar progress and Cancel, then does what Settings says (reveal,
    /// notify, trash originals). `onEvent` sees every event on the main thread.
    @discardableResult
    func run(_ request: ConvertRequest, title: String, onEvent: ((ConvertEvent) -> Void)? = nil,
             completion: (([Result<ConvertResult, ConvertFailure>]) -> Void)? = nil) -> Task<Void, Never> {
        let job = Job(count: request.inputs.count, activities: context.activities, onEvent: onEvent)
        job.activity = context.activities.begin(title) { [job] in job.task?.cancel() }
        let task = Task { @MainActor [weak self] in
            let results = await Converter.shared.convert(request) { event in
                Task { @MainActor in job.apply(event) }
            }
            await Task.yield() // Let queued progress events land first.
            job.end()
            self?.finish(results, title: title)
            completion?(results)
        }
        job.task = task
        return task
    }

    private func finish(_ results: [Result<ConvertResult, ConvertFailure>], title: String) {
        let done = results.compactMap { try? $0.get() }
        let failures = results.compactMap { r -> ConvertFailure? in if case .failure(let f) = r { f } else { nil } }
        let cancelled = failures.contains { $0.error.code == "cancelled" }
        if context.settings.string(Key.originals) == "trash" && !done.isEmpty {
            Converter.trashOriginals(done)
        }
        let outputs = done.map { URL(fileURLWithPath: $0.output) }
        let realFailures = failures.filter { $0.error.code != "cancelled" }
        if !realFailures.isEmpty {
            let first = realFailures[0]
            let summary = done.isEmpty ? "Nothing converted." : "\(done.count) converted."
            context.notify(title: "\(title): \(realFailures.count) failed",
                           body: "\(summary) \(first.input.lastPathComponent): \(first.error.message)")
        } else if !cancelled && !done.isEmpty {
            switch context.settings.string(Key.afterConvert) {
            case "reveal": NSWorkspace.shared.activateFileViewerSelecting(outputs)
            case "notify":
                let saved = done.reduce(Int64(0)) { $0 + $1.bytesIn - $1.bytesOut }
                let body = done.count == 1 ? URL(fileURLWithPath: done[0].output).lastPathComponent
                    : "\(done.count) files" + (saved > 0 ? ", \(ByteCountFormatter.string(fromByteCount: saved, countStyle: .file)) smaller" : "")
                context.notify(title: "\(title): done", body: body)
            default: break
            }
        }
    }
}

/// One running request: its menu bar activity and aggregate progress.
@MainActor
private final class Job {
    var activity: ActivityCenter.Activity?
    var task: Task<Void, Never>?
    private let activities: ActivityCenter
    private let onEvent: ((ConvertEvent) -> Void)?
    private var fractions: [Int: Double] = [:]
    private var running: [Int: String] = [:]
    private var finished = 0
    private let count: Int

    init(count: Int, activities: ActivityCenter, onEvent: ((ConvertEvent) -> Void)?) {
        self.count = count
        self.activities = activities
        self.onEvent = onEvent
    }

    func apply(_ event: ConvertEvent) {
        switch event {
        case .planned: break
        case .started(let i, let plan):
            running[i] = plan.input.lastPathComponent
            fractions[i] = 0
        case .progress(let i, let f): fractions[i] = f
        case .finished(let i, _), .failed(let i, _, _):
            fractions[i] = 1
            running[i] = nil
            finished += 1
        }
        if let activity { activities.update(activity, progress: overall, detail: detail) }
        onEvent?(event)
    }

    func end() {
        if let activity { activities.end(activity) }
        activity = nil
    }

    private var overall: Double { count == 0 ? 0 : fractions.values.reduce(0, +) / Double(count) }

    private var detail: String {
        let names = running.sorted { $0.key < $1.key }.map(\.value)
        let head = count > 1 ? "\(finished) of \(count) done" : ""
        return ([head] + names.prefix(2)).filter { !$0.isEmpty }.joined(separator: " — ")
    }
}
