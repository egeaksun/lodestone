import Foundation
import LodestoneCore

/// What to make of one kind of media: a format and a preset, with overrides on top.
public struct ConvertTarget: Codable, Equatable, Sendable {
    /// Nil: the preset's format, else the default for the kind (images keep their format, video
    /// becomes MP4, audio M4A).
    public var format: OutputFormat?
    /// Preset id or name. Nil: the default preset for the kind.
    public var preset: String?
    public var overrides: ConvertOptions

    public init(format: OutputFormat? = nil, preset: String? = nil, overrides: ConvertOptions = ConvertOptions()) {
        self.format = format
        self.preset = preset
        self.overrides = overrides
    }
}

/// A batch of files to convert. Built by the Convert panel, the quick actions, the CLI, and (later)
/// folder rules; nothing here needs a UI.
public struct ConvertRequest: Sendable {
    public var inputs: [URL]
    /// Per-kind targets (the panel sets one per kind). Kinds without an entry use `target`.
    public var targets: [MediaKind: ConvertTarget]
    public var target: ConvertTarget
    /// Nil: next to each source file.
    public var outputDirectory: URL?
    /// Replace existing files instead of picking a free name. Never replaces the source.
    public var overwrite: Bool

    public init(inputs: [URL], target: ConvertTarget = ConvertTarget(), targets: [MediaKind: ConvertTarget] = [:],
                outputDirectory: URL? = nil, overwrite: Bool = false) {
        self.inputs = inputs
        self.target = target
        self.targets = targets
        self.outputDirectory = outputDirectory
        self.overwrite = overwrite
    }

    public func target(for kind: MediaKind) -> ConvertTarget { targets[kind] ?? target }
}

public enum ConvertEngine: String, Codable, Sendable {
    case imageio, cwebp, avifenc, ffmpeg, avfoundation
}

/// One file's conversion, fully decided: what runs, with which arguments, writing where.
public struct ConvertPlan: Sendable {
    public var input: URL
    public var output: URL
    public var kind: MediaKind
    public var route: ConvertRoute
    public var format: OutputFormat
    public var preset: Preset
    /// The preset's options with the overrides applied.
    public var options: ConvertOptions
    public var engine: ConvertEngine
    /// Streams copied without re-encoding.
    public var remux: Bool
    /// The external tool and its arguments (ffmpeg, cwebp, avifenc).
    public var tool: URL?
    public var arguments: [String]
    /// ImageIO renders the source to this upright, resized PNG before the tool runs.
    public var intermediate: URL?
    /// AVAssetExportSession preset name, for the AVFoundation engine.
    public var exportPreset: String?
    public var warnings: [String]
    public var media: MediaInfo?
    public var image: ImageInfo?

    /// The command a shell would run, for `--dry-run`.
    public var commandLine: String? {
        if let tool { return shellQuoted([tool.path] + arguments) }
        if let exportPreset { return "AVAssetExportSession(\(exportPreset))" }
        return nil
    }

    /// Heavy work (video encodes) runs one at a time; everything else in parallel.
    public var isHeavy: Bool { route == .video || route == .gif }
}

extension ConvertPlan: Encodable {
    enum CodingKeys: String, CodingKey {
        case input, output, kind, format, preset, options, engine, remux, command, intermediate, warnings
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(input.path, forKey: .input)
        try c.encode(output.path, forKey: .output)
        try c.encode(kind, forKey: .kind)
        try c.encode(format, forKey: .format)
        try c.encode(preset.id, forKey: .preset)
        try c.encode(options, forKey: .options)
        try c.encode(engine, forKey: .engine)
        try c.encode(remux, forKey: .remux)
        try c.encodeIfPresent(commandLine, forKey: .command)
        try c.encodeIfPresent(intermediate?.path, forKey: .intermediate)
        try c.encode(warnings, forKey: .warnings)
    }
}

public struct ConvertResult: Codable, Sendable {
    public var input: String
    public var output: String
    public var kind: MediaKind
    public var format: OutputFormat
    public var preset: String
    public var engine: ConvertEngine
    public var remux: Bool
    public var bytesIn: Int64
    public var bytesOut: Int64
    public var seconds: Double
    public var warnings: [String]
}

/// A file that couldn't be planned or converted.
public struct ConvertFailure: Error, Sendable {
    public var input: URL
    public var error: IPCError

    public init(input: URL, error: IPCError) {
        self.input = input
        self.error = error
    }
}

public enum ConvertEvent: Sendable {
    case planned([Result<ConvertPlan, ConvertFailure>])
    case started(index: Int, plan: ConvertPlan)
    case progress(index: Int, fraction: Double)
    case finished(index: Int, result: ConvertResult)
    case failed(index: Int, input: URL, error: IPCError)
}

/// The conversion engine shared by the app and the CLI.
///
/// `plan` decides everything up front (and is what `--dry-run` prints); `run` executes one plan with
/// progress and cancellation (cancel the Task); `convert` does a whole request: video one file at a
/// time, images and audio in parallel.
public final class Converter: Sendable {
    public static let shared = Converter()

    public let presets: PresetStore

    public init(presets: PresetStore = .shared) {
        self.presets = presets
    }

    // MARK: Planning

    public func plan(_ request: ConvertRequest) async -> [Result<ConvertPlan, ConvertFailure>] {
        var reserved: Set<String> = []
        var plans: [Result<ConvertPlan, ConvertFailure>] = []
        let caps = await FFmpegInfo.capabilities()
        for input in request.inputs {
            do {
                let plan = try await plan(input: input.standardizedFileURL, request: request, reserved: reserved, caps: caps)
                reserved.insert(plan.output.standardizedFileURL.path)
                plans.append(.success(plan))
            } catch {
                plans.append(.failure(ConvertFailure(input: input, error: Self.ipcError(error))))
            }
        }
        return plans
    }

    private func plan(input: URL, request: ConvertRequest, reserved: Set<String>, caps: FFmpegCapabilities) async throws -> ConvertPlan {
        let probed = try await MediaProbe.probe(input)
        let target = request.target(for: probed.kind)
        try target.overrides.validate()

        var preset: Preset?
        if let query = target.preset {
            guard let found = presets.find(query) else {
                throw IPCError.notFound("No preset '\(query)'. Run `lodestone presets list`.")
            }
            // A video's audio can take an audio preset (extraction); otherwise kinds must match.
            if target.format == nil, found.kind != probed.kind, !(probed.kind == .video && found.kind == .audio) {
                throw IPCError.invalidParams("Preset '\(found.name)' is for \(found.kind.rawValue); \(input.lastPathComponent) is \(probed.kind == .image ? "an image" : probed.kind.rawValue).")
            }
            preset = found
        }
        let format = target.format ?? preset?.format ?? defaultFormat(kind: preset?.kind ?? probed.kind, probed: probed)
        guard let route = ConvertRoute(source: probed.kind, format: format) else {
            let options = OutputFormat.targets(for: probed.kind).map(\.rawValue).joined(separator: ", ")
            throw IPCError("unsupported", "Can't convert \(probed.kind.rawValue) to \(format.title). \(probed.kind.title) converts to: \(options).")
        }
        let chosen = preset ?? BuiltInPresets.defaultPreset(for: route.presetKind)
        guard chosen.kind == route.presetKind else {
            throw IPCError.invalidParams("Preset '\(chosen.name)' is for \(chosen.kind.rawValue); \(input.lastPathComponent) → \(format.title) needs a \(route.presetKind.rawValue) preset.")
        }
        let options = chosen.options.overlaid(by: target.overrides)

        if let dir = request.outputDirectory {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let output = OutputNaming.output(for: input, format: format, directory: request.outputDirectory,
                                         overwrite: request.overwrite, reserved: reserved) {
            FileManager.default.fileExists(atPath: $0.path)
        }

        var plan = ConvertPlan(input: input, output: output, kind: probed.kind, route: route, format: format, preset: chosen,
                               options: options, engine: .ffmpeg, remux: false, tool: nil, arguments: [], intermediate: nil,
                               exportPreset: nil, warnings: [], media: probed.media, image: probed.image)
        if route == .image {
            try planImage(&plan, caps: caps, overwrite: request.overwrite)
        } else {
            try planMedia(&plan, caps: caps, overwrite: request.overwrite)
        }
        return plan
    }

    private func defaultFormat(kind: MediaKind, probed: ProbedMedia) -> OutputFormat {
        switch kind {
        case .image: probed.image?.sameFormat ?? .png
        case .video: probed.kind == .video ? .mp4 : .m4a
        case .audio: .m4a
        }
    }

    private func planImage(_ plan: inout ConvertPlan, caps: FFmpegCapabilities, overwrite: Bool) throws {
        guard let info = plan.image else { throw IPCError.failed("Couldn't read \(plan.input.lastPathComponent) as an image.") }
        if info.frameCount > 1 { plan.warnings.append("Only the first frame of an animated image is converted.") }
        let o = plan.options
        let quality = o.quality ?? 90
        let strip = o.stripMetadata == true
        let intermediate = Paths.caches.appendingPathComponent("convert", isDirectory: true)
            .appendingPathComponent(UUID().uuidString + ".png")
        let render = ImageEngine.needsRender(info, options: o)

        switch plan.format {
        case .webp, .avif:
            let isWebP = plan.format == .webp
            let tool: ExternalTool = isWebP ? .cwebp : .avifenc
            let readable: Set<String> = isWebP ? ["public.png", "public.jpeg", "public.tiff", "org.webmproject.webp"] : ["public.png", "public.jpeg"]
            let direct = !render && readable.contains(info.typeIdentifier)
            let source = direct ? plan.input : intermediate
            if !direct {
                plan.intermediate = intermediate
                if !strip { plan.warnings.append("Only the color profile is kept: the image is rotated or resized by ImageIO first.") }
            }
            if let url = tool.url {
                plan.engine = isWebP ? .cwebp : .avifenc
                plan.tool = url
                plan.arguments = isWebP
                    ? ImageToolArguments.cwebp(input: source.path, output: plan.output.path, quality: quality, stripMetadata: strip)
                    : ImageToolArguments.avifenc(input: source.path, output: plan.output.path, quality: quality, stripMetadata: strip)
            } else if let ffmpeg = ExternalTool.ffmpeg.url, caps.has(isWebP ? "libwebp" : "libsvtav1") {
                // The intermediate is already resized, so ffmpeg only encodes.
                var options = o
                options.maxSize = nil
                options.quality = quality
                let job = FFmpegJob(input: source.path, output: plan.output.path, format: plan.format, route: .image,
                                    options: options, source: nil, capabilities: caps, overwrite: overwrite)
                let command = try FFmpegArguments.build(job)
                plan.engine = .ffmpeg
                plan.tool = ffmpeg
                plan.arguments = command.arguments
                plan.warnings += command.warnings
                plan.warnings.append("\(tool.rawValue) isn't installed; using ffmpeg (\(tool.installHint) for better results).")
            } else {
                _ = try tool.require()
            }
        default:
            guard ImageEngine.canWrite(plan.format) else {
                throw IPCError("unsupported", "This Mac can't write \(plan.format.title) images.")
            }
            plan.engine = .imageio
            if ImageEngine.canStripLosslessly(info, format: plan.format, options: o) {
                plan.remux = true
            }
        }
    }

    private func planMedia(_ plan: inout ConvertPlan, caps: FFmpegCapabilities, overwrite: Bool) throws {
        if let ffmpeg = ExternalTool.ffmpeg.url {
            let job = FFmpegJob(input: plan.input.path, output: plan.output.path, format: plan.format, route: plan.route,
                                options: plan.options, source: plan.media, capabilities: caps, overwrite: overwrite)
            let command = try FFmpegArguments.build(job)
            plan.engine = .ffmpeg
            plan.tool = ffmpeg
            plan.arguments = command.arguments
            plan.remux = command.remux
            plan.warnings += command.warnings
            return
        }
        guard AVFoundationEngine.supports(route: plan.route, format: plan.format) else {
            _ = try ExternalTool.ffmpeg.require()
            return
        }
        let (preset, warnings) = AVFoundationEngine.exportPreset(route: plan.route, format: plan.format, options: plan.options)
        plan.engine = .avfoundation
        plan.exportPreset = preset
        plan.remux = plan.options.copyStreams == true
        plan.warnings += warnings + ["ffmpeg isn't installed; using AVFoundation (brew install ffmpeg for every format and option)."]
    }

    // MARK: Running

    /// Runs one plan. Cancel the calling Task to stop it; a partial output is removed.
    public func run(_ plan: ConvertPlan, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ConvertResult {
        let start = Date()
        let bytesIn = Self.size(plan.input)
        // On failure, remove what this run wrote, never a file that was there before.
        let existedBefore = FileManager.default.fileExists(atPath: plan.output.path)
        let logBase: [String: JSONValue] = [
            "input": .string(plan.input.path), "output": .string(plan.output.path), "format": .string(plan.format.rawValue),
            "preset": .string(plan.preset.id), "engine": .string(plan.engine.rawValue),
        ]
        Log.shared.info("converter", "convert.start", logBase)
        progress(0)

        var tail: [String] = []
        var exitCode: Int32?
        do {
            try Task.checkCancellation()
            switch plan.engine {
            case .imageio:
                guard let info = plan.image else { throw IPCError.failed("Missing image information.") }
                try ImageEngine.convert(input: plan.input, output: plan.output, format: plan.format, options: plan.options, info: info)
            case .avfoundation:
                try await AVFoundationEngine.export(input: plan.input, output: plan.output, format: plan.format,
                                                   preset: plan.exportPreset ?? "", stripMetadata: plan.options.stripMetadata == true,
                                                   progress: progress)
            case .cwebp, .avifenc, .ffmpeg:
                guard let tool = plan.tool else { throw IPCError.failed("No tool for \(plan.engine.rawValue).") }
                if let intermediate = plan.intermediate, let info = plan.image {
                    Paths.ensure(intermediate.deletingLastPathComponent())
                    try ImageEngine.renderIntermediate(input: plan.input, to: intermediate, options: plan.options, info: info)
                }
                defer { if let i = plan.intermediate { try? FileManager.default.removeItem(at: i) } }
                let duration = plan.media?.duration ?? 0
                let result = try await ProcessRunner.run(tool, plan.arguments) { line in
                    if duration > 0, let t = FFmpegArguments.progressSeconds(line) {
                        progress(min(max(t / duration, 0), 1))
                    }
                }
                try Task.checkCancellation()
                if result.status != 0 {
                    exitCode = result.status
                    tail = Self.errorTail(result.stderr)
                    let detail = tail.isEmpty ? "" : ": " + tail.joined(separator: " / ")
                    throw IPCError.failed("\(plan.engine.rawValue) failed (exit \(result.status))\(detail)")
                }
            }
            try Task.checkCancellation()
        } catch {
            let ipc = Self.ipcError(error)
            if !existedBefore { try? FileManager.default.removeItem(at: plan.output) }
            var data = logBase
            data["error"] = .string(ipc.message)
            data["seconds"] = .number(Self.seconds(since: start))
            if let exitCode { data["exitCode"] = .number(Double(exitCode)) }
            if !tail.isEmpty { data["stderr"] = .array(tail.map { .string($0) }) }
            if ipc.code == "cancelled" {
                Log.shared.info("converter", "convert.cancelled", data)
            } else {
                Log.shared.warn("converter", "convert.failed", data)
            }
            throw ipc
        }

        progress(1)
        let result = ConvertResult(input: plan.input.path, output: plan.output.path, kind: plan.kind, format: plan.format,
                                   preset: plan.preset.id, engine: plan.engine, remux: plan.remux, bytesIn: bytesIn,
                                   bytesOut: Self.size(plan.output), seconds: Self.seconds(since: start), warnings: plan.warnings)
        var data = logBase
        data["seconds"] = .number(result.seconds)
        data["bytesIn"] = .number(Double(result.bytesIn))
        data["bytesOut"] = .number(Double(result.bytesOut))
        data["remux"] = .bool(result.remux)
        Log.shared.info("converter", "convert.done", data)
        return result
    }

    /// Plans and runs a whole request. Video encodes run one at a time; images and audio run in
    /// parallel alongside them. Results are in input order.
    public func convert(_ request: ConvertRequest, events: @escaping @Sendable (ConvertEvent) -> Void = { _ in }) async -> [Result<ConvertResult, ConvertFailure>] {
        let plans = await plan(request)
        events(.planned(plans))
        return await run(plans, events: events)
    }

    /// Runs already-made plans (from `plan`). Failed plans are reported as failures.
    public func run(_ plans: [Result<ConvertPlan, ConvertFailure>], events: @escaping @Sendable (ConvertEvent) -> Void = { _ in }) async -> [Result<ConvertResult, ConvertFailure>] {
        var results = [Result<ConvertResult, ConvertFailure>?](repeating: nil, count: plans.count)
        var heavy: [(Int, ConvertPlan)] = []
        var light: [(Int, ConvertPlan)] = []
        for (i, p) in plans.enumerated() {
            switch p {
            case .success(let plan): plan.isHeavy ? heavy.append((i, plan)) : light.append((i, plan))
            case .failure(let failure):
                results[i] = .failure(failure)
                events(.failed(index: i, input: failure.input, error: failure.error))
            }
        }

        let one: @Sendable (Int, ConvertPlan) async -> (Int, Result<ConvertResult, ConvertFailure>) = { [self] i, plan in
            events(.started(index: i, plan: plan))
            do {
                let result = try await run(plan) { events(.progress(index: i, fraction: $0)) }
                events(.finished(index: i, result: result))
                return (i, .success(result))
            } catch {
                let e = Self.ipcError(error)
                events(.failed(index: i, input: plan.input, error: e))
                return (i, .failure(ConvertFailure(input: plan.input, error: e)))
            }
        }

        let parallelism = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        let done = await withTaskGroup(of: [(Int, Result<ConvertResult, ConvertFailure>)].self) { group in
            group.addTask {
                var out: [(Int, Result<ConvertResult, ConvertFailure>)] = []
                for (i, plan) in heavy { out.append(await one(i, plan)) }
                return out
            }
            group.addTask {
                await withTaskGroup(of: (Int, Result<ConvertResult, ConvertFailure>).self) { inner in
                    var out: [(Int, Result<ConvertResult, ConvertFailure>)] = []
                    var queue = light[...]
                    for _ in 0..<parallelism {
                        guard let (i, plan) = queue.popFirst() else { break }
                        inner.addTask { await one(i, plan) }
                    }
                    while let r = await inner.next() {
                        out.append(r)
                        if let (i, plan) = queue.popFirst() { inner.addTask { await one(i, plan) } }
                    }
                    return out
                }
            }
            var all: [(Int, Result<ConvertResult, ConvertFailure>)] = []
            for await chunk in group { all += chunk }
            return all
        }
        for (i, r) in done { results[i] = r }
        return results.enumerated().map { i, r in
            r ?? .failure(ConvertFailure(input: (try? plans[i].get().input) ?? URL(fileURLWithPath: "/"), error: IPCError("cancelled", "Conversion cancelled.")))
        }
    }

    // MARK: Helpers

    /// Moves converted originals to the Trash (the "trash originals" setting and `--trash-originals`).
    public static func trashOriginals(_ results: [ConvertResult]) -> [String] {
        var trashed: [String] = []
        for r in results where r.input != r.output {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: r.input), resultingItemURL: nil)
                trashed.append(r.input)
            } catch {
                Log.shared.warn("converter", "trash.failed", ["path": .string(r.input), "error": .string(error.localizedDescription)])
            }
        }
        if !trashed.isEmpty { Log.shared.info("converter", "originals.trashed", ["count": .number(Double(trashed.count))]) }
        return trashed
    }

    /// The formats each kind converts to, and which tools are installed.
    public static func formatsReport() async -> JSONValue {
        let caps = await FFmpegInfo.capabilities()
        var kinds: [String: JSONValue] = [:]
        for kind in MediaKind.allCases {
            kinds[kind.rawValue] = .array(OutputFormat.targets(for: kind).map { f in
                let route = ConvertRoute(source: kind, format: f)!
                return ["format": .string(f.rawValue), "extension": .string(f.fileExtension), "title": .string(f.title),
                        "engine": .string(engineName(route: route, format: f, caps: caps)), "available": .bool(available(route: route, format: f, caps: caps))]
            })
        }
        var tools: [String: JSONValue] = [:]
        for tool in [ExternalTool.ffmpeg, .ffprobe, .cwebp, .avifenc] {
            tools[tool.rawValue] = ["path": tool.url.map { .string($0.path) } ?? .null, "install": .string(tool.installHint)]
        }
        return ["kinds": .object(kinds), "tools": .object(tools)]
    }

    private static func engineName(route: ConvertRoute, format: OutputFormat, caps: FFmpegCapabilities) -> String {
        switch (route, format) {
        case (.image, .webp): ExternalTool.cwebp.url != nil ? "cwebp" : (ExternalTool.ffmpeg.url != nil && caps.has("libwebp") ? "ffmpeg" : "cwebp (missing)")
        case (.image, .avif): ExternalTool.avifenc.url != nil ? "avifenc" : (ExternalTool.ffmpeg.url != nil && caps.has("libsvtav1") ? "ffmpeg" : "avifenc (missing)")
        case (.image, _): "imageio"
        default:
            ExternalTool.ffmpeg.url != nil ? "ffmpeg" : (AVFoundationEngine.supports(route: route, format: format) ? "avfoundation" : "ffmpeg (missing)")
        }
    }

    private static func available(route: ConvertRoute, format: OutputFormat, caps: FFmpegCapabilities) -> Bool {
        !engineName(route: route, format: format, caps: caps).hasSuffix("(missing)")
    }

    static func ipcError(_ error: Error) -> IPCError {
        if let e = error as? IPCError { return e }
        if error is CancellationError { return IPCError("cancelled", "Conversion cancelled.") }
        return IPCError.failed(error.localizedDescription)
    }

    /// The last few lines ffmpeg (or another tool) wrote that aren't progress reports.
    static func errorTail(_ stderr: String, lines: Int = 6) -> [String] {
        stderr.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.isEmpty && !FFmpegArguments.isProgressLine($0) }
            .map { line in
                // "[in#0 @ 0x145f047a0] moov atom not found" → "moov atom not found"
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]"), line[..<close].contains(" @ 0x") else { return line }
                return line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            }
            .suffix(lines)
            .map { $0 }
    }

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func seconds(since start: Date) -> Double {
        (Date().timeIntervalSince(start) * 100).rounded() / 100
    }
}
