import ArgumentParser
import Foundation
import LodestoneCore
import LodestoneKit

/// Conversion options shared by `convert` and `presets save`. Each one overrides the preset.
struct ConvertOptionArgs: ParsableArguments {
    @Option(help: "Quality 0–100 (100 = best). Maps to CRF, -q:v, JPEG/WebP quality or the audio bitrate.") var quality: Int?
    @Option(name: .customLong("max-size"), help: "Size limit: 1080 (1080p for video, longest edge for images), 1920x1080, 50%, or original.")
    var maxSize: String?
    @Option(help: "Video: h264, hevc (hardware), x264, x265 (software, smaller), prores, vp9, av1. M4A audio: aac, alac.")
    var codec: String?
    @Option(help: "Maximum frame rate (60, 30, 24), or 0 for the original.") var fps: Int?
    @Option(help: "A video's audio: copy, aac128, aac192, aac256, remove.") var audio: String?
    @Option(help: "Audio bitrate in kbps for M4A (AAC), MP3 and Opus.") var bitrate: Int?
    @Option(name: .customLong("sample-rate"), help: "44100, 48000, 96000 (or 44.1, 48, 96), or original.") var sampleRate: String?
    @Option(name: .customLong("bit-depth"), help: "Lossless audio: 16, 24 or 32f.") var bitDepth: String?
    @Option(help: "Audio channels: 1 (mono), 2 (stereo), 0 for the original.") var channels: Int?
    @Flag(name: .customLong("strip-metadata"), help: "Remove EXIF, GPS location and other tags (the color profile is kept).")
    var stripMetadata = false

    func options() throws -> ConvertOptions {
        var o = ConvertOptions()
        o.quality = quality
        if let maxSize {
            guard let size = MaxSize.parse(maxSize) else { throw ValidationError("--max-size expects 1080, 1920x1080, 50% or original") }
            o.maxSize = size
        }
        if let codec {
            if let audio = AudioCodec(rawValue: codec.lowercased()) {
                o.audioCodec = audio
            } else if let video = VideoCodec.parse(codec) {
                o.videoCodec = video
            } else {
                throw ValidationError("--codec expects h264, hevc, x264, x265, prores, vp9, av1, aac or alac")
            }
        }
        o.fps = fps
        if let audio {
            guard let track = AudioTrack.parse(audio) else { throw ValidationError("--audio expects copy, aac128, aac192, aac256 or remove") }
            o.audioTrack = track
        }
        o.audioBitrate = bitrate
        if let sampleRate {
            guard let rate = Self.parseSampleRate(sampleRate) else { throw ValidationError("--sample-rate expects 44100, 48000, 96000 or original") }
            o.sampleRate = rate
        }
        if let bitDepth {
            guard let depth = BitDepth.parse(bitDepth) else { throw ValidationError("--bit-depth expects 16, 24 or 32f") }
            o.bitDepth = depth
        }
        o.channels = channels
        if stripMetadata { o.stripMetadata = true }
        try o.validate()
        return o
    }

    /// "44.1" → 44100, "48k" → 48000, "96000" → 96000, "original" → 0.
    static func parseSampleRate(_ text: String) -> Int? {
        let t = text.lowercased().replacingOccurrences(of: "khz", with: "").replacingOccurrences(of: "k", with: "")
        if t == "original" || t == "0" { return 0 }
        guard let n = Double(t), n > 0 else { return nil }
        return n < 1000 ? Int((n * 1000).rounded()) : Int(n)
    }
}

struct ConvertGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Convert images, video and audio (runs here; the app isn't needed).",
        discussion: """
        Examples:
          lodestone convert clip.mov                       # MP4, Balanced preset
          lodestone convert clip.mov --preset instant      # remux without re-encoding
          lodestone convert *.heic --to webp --quality 80
          lodestone convert photo.jpg --preset strip-metadata
          lodestone convert mix.wav --to flac --bit-depth 24 --sample-rate 96000
          lodestone convert talk.mp4 --to mp3              # extract the audio
          lodestone convert formats
        Files are written next to the originals and never replace an existing file unless you pass --overwrite.
        """,
        subcommands: [ConvertFiles.self, ConvertFormats.self],
        defaultSubcommand: ConvertFiles.self)
}

struct ConvertFiles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files",
        abstract: "Convert files (the default: `lodestone convert <files...>`).")

    @Argument(help: "Images, videos or audio files.") var files: [String]
    @Option(name: .customLong("to"), help: "Target format: png, jpeg, heic, webp, avif, tiff, gif, mp4, mov, webm, m4a, mp3, wav, aiff, flac, opus.")
    var format: String?
    @Option(help: "Preset id or name (see `lodestone presets list`).") var preset: String?
    @OptionGroup var options: ConvertOptionArgs
    @Option(name: .customLong("output-dir"), help: "Write here instead of next to each file.") var outputDir: String?
    @Flag(help: "Replace existing output files (never the source).") var overwrite = false
    @Flag(name: .customLong("dry-run"), help: "Print the plan and the exact commands without converting.") var dryRun = false
    @Flag(name: .customLong("trash-originals"), help: "Move each converted original to the Trash.") var trashOriginals = false
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        guard !files.isEmpty else { throw ValidationError("Give at least one file.") }
        var target = ConvertTarget(preset: preset, overrides: try options.options())
        if let format {
            guard let f = OutputFormat.parse(format) else {
                throw ValidationError("Unknown format '\(format)'. Run `lodestone convert formats`.")
            }
            target.format = f
        }
        let request = ConvertRequest(inputs: files.map(fileURL), target: target,
                                     outputDirectory: outputDir.map(fileURL), overwrite: overwrite)

        if dryRun {
            try printPlans(await Converter.shared.plan(request))
            return
        }

        let progress = ProgressPrinter(total: files.count)
        let task = Task { await Converter.shared.convert(request) { progress.handle($0) } }
        // Ctrl-C cancels cleanly: ffmpeg is stopped and partial files are removed.
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { task.cancel() }
        sigint.resume()
        let results = await task.value
        sigint.cancel()

        let succeeded = results.compactMap { try? $0.get() }
        let trashed = trashOriginals ? Converter.trashOriginals(succeeded) : []
        try printResults(results, trashed: Set(trashed))
        if succeeded.count < results.count { throw ExitCode(1) }
    }

    private func printPlans(_ plans: [Result<ConvertPlan, ConvertFailure>]) throws {
        if global.json {
            let items: [JSONValue] = try plans.map {
                switch $0 {
                case .success(let plan): try JSONValue(encoding: plan)
                case .failure(let f): ["input": .string(f.input.path), "error": ["code": .string(f.error.code), "message": .string(f.error.message)]]
                }
            }
            print(JSONValue.array(items).prettyJSONString)
            return
        }
        for p in plans {
            switch p {
            case .success(let plan):
                print(displayPath(plan.input.path))
                print("  → \(displayPath(plan.output.path))")
                print("  \(plan.kind.rawValue) → \(plan.format.title), preset \(plan.preset.id) (\(plan.options.summary)), engine \(plan.engine.rawValue)\(plan.remux ? " (no re-encode)" : "")")
                if let intermediate = plan.intermediate { print("  ImageIO renders an upright/resized copy first: \(intermediate.path)") }
                if let command = plan.commandLine { print("  $ \(command)") }
                for w in plan.warnings { print("  note: \(w)") }
            case .failure(let f):
                print(displayPath(f.input.path))
                print("  error: \(f.error.message)")
            }
        }
    }

    private func printResults(_ results: [Result<ConvertResult, ConvertFailure>], trashed: Set<String>) throws {
        if global.json {
            let items: [JSONValue] = try results.map {
                switch $0 {
                case .success(let r):
                    var v = try JSONValue(encoding: r)
                    if case .object(var o) = v { o["trashedOriginal"] = .bool(trashed.contains(r.input)); v = .object(o) }
                    return v
                case .failure(let f):
                    return ["input": .string(f.input.path), "error": ["code": .string(f.error.code), "message": .string(f.error.message)]]
                }
            }
            print(JSONValue.array(items).prettyJSONString)
            return
        }
        let rows: [[String]] = results.map {
            switch $0 {
            case .success(let r):
                let ratio = r.bytesIn > 0 ? String(format: " (%.0f%%)", Double(r.bytesOut) / Double(r.bytesIn) * 100) : ""
                return ["ok", displayPath(r.output), "\(ByteFormat.string(r.bytesIn)) → \(ByteFormat.string(r.bytesOut))\(ratio)",
                        String(format: "%.1fs", r.seconds), r.engine.rawValue + (r.remux ? " (copy)" : "")]
            case .failure(let f):
                return ["FAILED", displayPath(f.input.path), f.error.message, "", ""]
            }
        }
        print(Output.table(["", "OUTPUT", "SIZE", "TIME", "ENGINE"], rows))
    }
}

/// Progress on stderr: one line per file, rewritten in place on a terminal.
private final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int
    private let tty = isatty(STDERR_FILENO) != 0
    private var percent: [Int: Int] = [:]
    private var names: [Int: String] = [:]

    init(total: Int) { self.total = total }

    func handle(_ event: ConvertEvent) {
        lock.withLock {
            switch event {
            case .planned:
                break
            case .started(let i, let plan):
                names[i] = plan.input.lastPathComponent
                var line = "[\(i + 1)/\(total)] \(plan.input.lastPathComponent) → \(plan.output.lastPathComponent) (\(plan.engine.rawValue)\(plan.remux ? ", no re-encode" : ""))"
                for w in plan.warnings { line += "\n  note: \(w)" }
                write(line + "\n")
            case .progress(let i, let fraction):
                let p = Int(fraction * 100)
                guard p != percent[i], p < 100 else { return }
                percent[i] = p
                // Only show live percentages on a terminal; logs get start and end lines.
                if tty { write("\r  \(names[i] ?? "") \(p)%\u{1B}[K") }
            case .finished(let i, let r):
                if tty { write("\r\u{1B}[K") }
                write("  ✓ \(names[i] ?? "") \(String(format: "%.1fs", r.seconds)), \(ByteFormat.string(r.bytesIn)) → \(ByteFormat.string(r.bytesOut))\n")
            case .failed(let i, let input, let error):
                if tty { write("\r\u{1B}[K") }
                write("[\(i + 1)/\(total)] \(input.lastPathComponent): \(error.message)\n")
            }
        }
    }

    private func write(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }
}

/// A path relative to the working directory when it's inside it, for human-readable output.
func displayPath(_ path: String) -> String {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
    let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
    for base in [cwd, "/private" + cwd, cwd.replacingOccurrences(of: "/private/", with: "/", options: .anchored)] where resolved.hasPrefix(base + "/") {
        return String(resolved.dropFirst(base.count + 1))
    }
    return path
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct ConvertFormats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "formats",
        abstract: "What each kind of file converts to, and which tools are installed.")
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let report = await Converter.formatsReport()
        Output.emit(report, json: global.json) { r in
            var rows: [[String]] = []
            for kind in MediaKind.allCases {
                for f in r["kinds"]?[kind.rawValue]?.array ?? [] {
                    rows.append([kind.rawValue, Output.plain(f["format"]), Output.plain(f["engine"]),
                                 f["available"]?.bool == true ? "yes" : "no"])
                }
            }
            var text = Output.table(["FROM", "TO", "ENGINE", "AVAILABLE"], rows) + "\n\n"
            let tools = (r["tools"]?.object ?? [:]).sorted { $0.key < $1.key }.map { name, t in
                [name, t["path"]?.string ?? "not installed (\(Output.plain(t["install"])))"]
            }
            text += Output.table(["TOOL", "PATH"], tools)
            return text
        }
    }
}

struct PresetsGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "presets",
        abstract: "List, show, save and delete conversion presets.",
        discussion: "Custom presets live in ~/Library/Application Support/Lodestone/presets.json and are shared with the app.",
        subcommands: [List.self, Show.self, Save.self, Delete.self])

    static func row(_ p: Preset) -> [String] {
        [p.id, p.kind.rawValue, p.name + (p.builtIn ? "" : " (custom)"), p.format?.rawValue ?? "-", p.options.summary]
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List presets.")
        @Option(help: "Only image, video or audio presets.") var kind: String?
        @OptionGroup var global: GlobalOptions

        func run() throws {
            var presets = PresetStore.shared.all()
            if let kind {
                guard let k = MediaKind(rawValue: kind) else { throw ValidationError("--kind expects image, video or audio") }
                presets = presets.filter { $0.kind == k }
            }
            try Output.emit(presets, json: global.json) { list in
                Output.table(["ID", "KIND", "NAME", "FORMAT", "OPTIONS"], list.map(PresetsGroup.row))
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one preset.")
        @Argument(help: "Preset id or name.") var name: String
        @OptionGroup var global: GlobalOptions

        func run() throws {
            guard let preset = PresetStore.shared.find(name) else {
                throw IPCError.notFound("No preset '\(name)'. Run `lodestone presets list`.")
            }
            try Output.emit(preset, json: global.json) { p in
                """
                \(p.name) (\(p.id))\(p.builtIn ? "" : ", custom")
                kind:    \(p.kind.rawValue)
                format:  \(p.format?.rawValue ?? "default for the kind")
                options: \(p.options.summary)
                \(p.summary)
                """
            }
        }
    }

    struct Save: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save a custom preset.",
            discussion: "Example: lodestone presets save \"Web clips\" --from share --max-size 720 --quality 45")
        @Argument(help: "Name; the id is derived from it.") var name: String
        @Option(help: "Start from this preset's options (default: none).") var from: String?
        @Option(help: "image, video or audio (default: the --from preset's kind).") var kind: String?
        @Option(name: .customLong("to"), help: "Preferred output format.") var format: String?
        @OptionGroup var options: ConvertOptionArgs
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let store = PresetStore.shared
            var base = ConvertOptions()
            var resolvedKind: MediaKind?
            var resolvedFormat: OutputFormat?
            if let from {
                guard let p = store.find(from) else { throw IPCError.notFound("No preset '\(from)'.") }
                base = p.options
                resolvedKind = p.kind
                resolvedFormat = p.format
            }
            if let kind {
                guard let k = MediaKind(rawValue: kind) else { throw ValidationError("--kind expects image, video or audio") }
                resolvedKind = k
            }
            guard let finalKind = resolvedKind else { throw ValidationError("Pass --kind or --from.") }
            if let format {
                guard let f = OutputFormat.parse(format) else { throw ValidationError("Unknown format '\(format)'.") }
                resolvedFormat = f
            }
            let preset = try store.save(name: name, kind: finalKind, format: resolvedFormat, options: base.overlaid(by: try options.options()))
            try Output.emit(preset, json: global.json) { "Saved \($0.name) (\($0.id)): \($0.options.summary)" }
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a custom preset.")
        @Argument(help: "Preset id or name.") var name: String
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let preset = try PresetStore.shared.delete(name)
            try Output.emit(preset, json: global.json) { "Deleted \($0.name) (\($0.id))" }
        }
    }
}
