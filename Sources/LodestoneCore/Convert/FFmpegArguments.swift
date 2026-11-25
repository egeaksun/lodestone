import Foundation

/// Everything needed to build one ffmpeg command line.
public struct FFmpegJob: Sendable {
    public var input: String
    public var output: String
    public var format: OutputFormat
    public var route: ConvertRoute
    /// The preset's options with the user's overrides applied.
    public var options: ConvertOptions
    public var source: MediaInfo?
    public var capabilities: FFmpegCapabilities
    public var overwrite: Bool

    public init(input: String, output: String, format: OutputFormat, route: ConvertRoute, options: ConvertOptions,
                source: MediaInfo?, capabilities: FFmpegCapabilities = .full, overwrite: Bool = false) {
        self.input = input
        self.output = output
        self.format = format
        self.route = route
        self.options = options
        self.source = source
        self.capabilities = capabilities
        self.overwrite = overwrite
    }
}

public struct FFmpegCommand: Sendable, Equatable {
    public var arguments: [String]
    /// True when every stream is copied (no re-encoding).
    public var remux: Bool
    /// Things the user should know: a codec swapped for one the container accepts, an ignored option.
    public var warnings: [String]
}

/// Builds ffmpeg arguments for the converter. Pure, so every preset is unit tested.
public enum FFmpegArguments {
    public static func build(_ job: FFmpegJob) throws -> FFmpegCommand {
        var builder = Builder(job: job)
        try builder.build()
        let args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-progress", "pipe:2", "-nostats",
                    job.overwrite ? "-y" : "-n", "-i", job.input] + builder.args + [job.output]
        return FFmpegCommand(arguments: args, remux: builder.remux, warnings: builder.warnings)
    }

    // MARK: Stream compatibility (for copying without re-encoding)

    static func videoFits(_ codec: String, in format: OutputFormat) -> Bool {
        switch format {
        case .mp4: ["h264", "hevc", "av1", "mpeg4"].contains(codec)
        case .mov: ["h264", "hevc", "prores", "mpeg4", "mjpeg"].contains(codec)
        case .webm: ["vp8", "vp9", "av1"].contains(codec)
        default: false
        }
    }

    static func audioFits(_ codec: String, in format: OutputFormat) -> Bool {
        switch format {
        case .mp4: ["aac", "mp3", "alac", "ac3", "eac3"].contains(codec)
        case .mov: ["aac", "mp3", "alac", "ac3", "eac3"].contains(codec) || codec.hasPrefix("pcm_")
        case .webm: ["opus", "vorbis"].contains(codec)
        default: false
        }
    }

    /// Whether the Instant preset can turn `source` into `format` (video copied as is).
    public static func canRemux(_ source: MediaInfo, to format: OutputFormat) -> Bool {
        guard let video = source.video else { return false }
        return videoFits(video.codec, in: format)
    }

    // MARK: Progress

    /// The output position in seconds from a `-progress` line ("out_time_us=1500000"), else nil.
    public static func progressSeconds(_ line: String) -> Double? {
        for key in ["out_time_us=", "out_time_ms="] where line.hasPrefix(key) {
            guard let us = Double(line.dropFirst(key.count)), us >= 0 else { return nil }
            return us / 1_000_000
        }
        return nil
    }

    /// True for `-progress` key=value lines, so error output can be told apart.
    public static func isProgressLine(_ line: String) -> Bool {
        guard let eq = line.firstIndex(of: "="), eq > line.startIndex else { return false }
        return line[..<eq].allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }
    }

    // MARK: Builder

    private struct Builder {
        let job: FFmpegJob
        var args: [String] = []
        var remux = false
        var warnings: [String] = []

        var o: ConvertOptions { job.options }
        var quality: Int { o.quality ?? 65 }

        init(job: FFmpegJob) { self.job = job }

        mutating func build() throws {
            switch job.route {
            case .video: try video()
            case .gif: gif()
            case .audio: try audio()
            case .image: try image()
            }
        }

        // MARK: Video

        mutating func video() throws {
            let format = job.format
            args += ["-map", "0:v:0", "-map", "0:a?"]

            if o.copyStreams == true {
                guard let source = job.source, let v = source.video else {
                    throw IPCError("unsupported", "Instant needs to read the video's streams first; install ffprobe (brew install ffmpeg) or pick another preset.")
                }
                guard videoFits(v.codec, in: format) else {
                    throw IPCError("unsupported", "Instant can't put \(v.codec) video in \(format.title) without re-encoding. Pick Balanced or another preset.")
                }
                args += ["-c:v", "copy"]
                if v.codec == "hevc" && format != .webm { args += ["-tag:v", "hvc1"] }
                remux = audioArgs(trackChoice: .copy)
            } else {
                videoEncoder()
                let filters = videoFilters()
                if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
                _ = audioArgs(trackChoice: o.audioTrack ?? .copy)
            }
            metadataArgs()
            if format == .mp4 || format == .mov { args += ["-movflags", "+faststart"] }
        }

        mutating func videoEncoder() {
            var codec = o.videoCodec ?? VideoCodec.fallback(for: job.format)
            if !codec.containers.contains(job.format) {
                let replacement = VideoCodec.fallback(for: job.format)
                warnings.append("\(job.format.title) can't hold \(codec.rawValue); using \(replacement.rawValue).")
                codec = replacement
            }
            let caps = job.capabilities
            if codec == .h264 && !caps.has("h264_videotoolbox") {
                warnings.append("Hardware H.264 encoder unavailable; using x264.")
                codec = .x264
            }
            if codec == .hevc && !caps.has("hevc_videotoolbox") {
                warnings.append("Hardware HEVC encoder unavailable; using x265.")
                codec = .x265
            }
            switch codec {
            case .h264:
                args += ["-c:v", "h264_videotoolbox", "-q:v", String(QualityMapping.videoToolbox(quality)), "-profile:v", "high", "-pix_fmt", "yuv420p"]
            case .hevc:
                args += ["-c:v", "hevc_videotoolbox", "-q:v", String(QualityMapping.videoToolbox(quality)), "-tag:v", "hvc1"]
            case .x264:
                args += ["-c:v", "libx264", "-crf", String(QualityMapping.x264CRF(quality)), "-preset", "medium", "-pix_fmt", "yuv420p"]
            case .x265:
                args += ["-c:v", "libx265", "-crf", String(QualityMapping.x265CRF(quality)), "-preset", "medium", "-pix_fmt", "yuv420p",
                         "-tag:v", "hvc1", "-x265-params", "log-level=error"]
            case .prores:
                args += ["-c:v", "prores_videotoolbox", "-profile:v", String(QualityMapping.proResProfile(quality))]
            case .vp9:
                args += ["-c:v", "libvpx-vp9", "-crf", String(QualityMapping.vp9CRF(quality)), "-b:v", "0",
                         "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
            case .av1:
                args += ["-c:v", "libsvtav1", "-crf", String(QualityMapping.av1CRF(quality)), "-preset", "8"]
            }
        }

        func scaleFilter(_ limit: MaxSize?) -> String? {
            guard let limit, limit != .original else { return nil }
            if let v = job.source?.video, v.width > 0, v.height > 0 {
                let (w, h) = v.displaySize
                let fitted = SizeFitting.video(width: w, height: h, limit: limit)
                guard fitted.width != w || fitted.height != h else { return nil }
                return "scale=\(fitted.width):\(fitted.height):flags=lanczos"
            }
            // Size unknown (no ffprobe): let ffmpeg work it out.
            switch limit {
            case .original: return nil
            case .dimension(let n):
                return "scale=w='if(gte(iw,ih),-2,min(iw,\(n)))':h='if(gte(iw,ih),min(ih,\(n)),-2)':flags=lanczos"
            case .percent(let p):
                let f = p / 100
                return "scale=trunc(iw*\(f)/2)*2:trunc(ih*\(f)/2)*2:flags=lanczos"
            case .box(let w, let h):
                return "scale=w='min(iw,\(w))':h='min(ih,\(h))':force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos"
            }
        }

        func fpsFilter(_ fps: Int?) -> String? {
            guard let fps, fps > 0 else { return nil }
            if let source = job.source?.video?.fps, source <= Double(fps) + 0.01 { return nil }
            return "fps=\(fps)"
        }

        func videoFilters() -> [String] {
            [scaleFilter(o.maxSize), fpsFilter(o.fps)].compactMap { $0 }
        }

        /// Audio for MP4/MOV/WebM. Returns true when the audio is copied (or absent).
        mutating func audioArgs(trackChoice: AudioTrack) -> Bool {
            let format = job.format
            if trackChoice == .remove {
                args += ["-an"]
                return true
            }
            if let audio = job.source?.audio, audio.isEmpty { return true }
            if trackChoice == .copy {
                if let codecs = job.source?.audio.map(\.codec), codecs.allSatisfy({ audioFits($0, in: format) }) {
                    args += ["-c:a", "copy"]
                    return true
                }
            }
            let bitrate = trackChoice.bitrate ?? 256
            if format == .webm {
                args += ["-c:a", "libopus", "-b:a", "\(min(bitrate, 192))k"]
            } else {
                args += ["-c:a", aacEncoder, "-b:a", "\(bitrate)k"]
            }
            return false
        }

        var aacEncoder: String { job.capabilities.has("aac_at") ? "aac_at" : "aac" }

        mutating func metadataArgs() {
            if o.stripMetadata == true {
                args += ["-map_metadata", "-1", "-map_chapters", "-1"]
            } else {
                args += ["-map_metadata", "0"]
            }
        }

        // MARK: GIF

        mutating func gif() {
            let fps = (o.fps ?? 0) > 0 ? o.fps! : 15
            let scale = scaleFilter(o.maxSize ?? .box(width: 640, height: 640)) ?? "scale=iw:ih"
            let chain = [fpsFilter(fps), scale].compactMap { $0 }.joined(separator: ",")
            args += ["-map", "0:v:0", "-an",
                     "-vf", "\(chain),split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a",
                     "-loop", "0"]
        }

        // MARK: Audio

        mutating func audio() throws {
            let format = job.format
            let source = job.source?.audio.first
            if let info = job.source, info.audio.isEmpty {
                throw IPCError("unsupported", "This file has no audio track to convert.")
            }
            args += ["-map", "0:a:0", "-vn", "-sn", "-dn"]

            let lossless = format.isLosslessAudio || (format == .m4a && o.audioCodec == .alac)
            var resample: [String] = []
            if let rate = o.sampleRate, rate > 0, rate != source?.sampleRate {
                if format == .opus {
                    if rate != 48000 { warnings.append("Opus always plays at 48 kHz; sample rate ignored.") }
                } else if format == .mp3 && rate > 48000 {
                    throw IPCError.invalidParams("MP3 supports sample rates up to 48 kHz. Pick 44.1 or 48 kHz, or a lossless format.")
                } else {
                    resample += ["osr=\(rate)", "filter_size=64", "phase_shift=12"]
                    args += ["-ar", String(rate)]
                }
            }

            if lossless {
                var depth = o.bitDepth ?? source?.losslessDepth ?? .int16
                if depth == .float32 && (format == .flac || format == .m4a) {
                    if o.bitDepth == .float32 {
                        throw IPCError.invalidParams("\(format == .flac ? "FLAC" : "ALAC") can't store 32-bit float. Use WAV or AIFF, or pick 24-bit.")
                    }
                    warnings.append("\(format == .flac ? "FLAC" : "ALAC") can't store 32-bit float; writing 24-bit.")
                    depth = .int24
                }
                let (encoder, sampleFormat) = losslessEncoder(depth)
                args += ["-c:a", encoder]
                resample.append("osf=\(sampleFormat)")
                let sourceDepth = source?.losslessDepth
                if depth == .int16 && sourceDepth != .int16 { resample.append("dither_method=triangular") }
                if format == .flac { args += ["-compression_level", "8"] }
                if depth == .int24 && (format == .flac || format == .m4a) { args += ["-bits_per_raw_sample", "24"] }
                args += ["-sample_fmt", sampleFormat]
            } else {
                if o.bitDepth != nil { warnings.append("Bit depth applies to WAV, AIFF, FLAC and ALAC only; ignored for \(format.title).") }
                switch format {
                case .m4a:
                    args += ["-c:a", aacEncoder, "-b:a", "\(o.audioBitrate ?? QualityMapping.aacBitrate(quality))k"]
                case .mp3:
                    args += ["-c:a", "libmp3lame"]
                    if let b = o.audioBitrate { args += ["-b:a", "\(b)k"] } else { args += ["-q:a", String(QualityMapping.mp3VBR(quality))] }
                case .opus:
                    args += ["-c:a", "libopus", "-b:a", "\(o.audioBitrate ?? QualityMapping.opusBitrate(quality))k", "-vbr", "on"]
                default:
                    break
                }
            }
            if !resample.isEmpty { args += ["-af", "aresample=" + resample.joined(separator: ":")] }
            if let ch = o.channels, ch > 0, ch != source?.channels { args += ["-ac", String(ch)] }

            if o.stripMetadata == true { args += ["-map_metadata", "-1"] } else { args += ["-map_metadata", "0"] }
            switch format {
            case .m4a: args += ["-movflags", "+faststart"]
            case .mp3: args += ["-id3v2_version", "3", "-write_id3v1", "0"]
            case .wav: args += ["-rf64", "auto"]
            default: break
            }
        }

        func losslessEncoder(_ depth: BitDepth) -> (encoder: String, sampleFormat: String) {
            switch (job.format, depth) {
            case (.wav, .int16): ("pcm_s16le", "s16")
            case (.wav, .int24): ("pcm_s24le", "s32")
            case (.wav, .float32): ("pcm_f32le", "flt")
            case (.aiff, .int16): ("pcm_s16be", "s16")
            case (.aiff, .int24): ("pcm_s24be", "s32")
            case (.aiff, .float32): ("pcm_f32be", "flt")
            case (.flac, .int16): ("flac", "s16")
            case (.flac, _): ("flac", "s32")
            case (_, .int16): ("alac", "s16p")
            default: ("alac", "s32p")
            }
        }

        // MARK: Images (fallback when cwebp or avifenc is missing)

        mutating func image() throws {
            var filters: [String] = []
            if let v = job.source?.video, let limit = o.maxSize {
                let fitted = SizeFitting.image(width: v.width, height: v.height, limit: limit)
                if fitted.width != v.width || fitted.height != v.height { filters.append("scale=\(fitted.width):\(fitted.height):flags=lanczos") }
            }
            args += ["-frames:v", "1"]
            switch job.format {
            case .webp:
                guard job.capabilities.has("libwebp") else {
                    throw IPCError("missing_tool", "cwebp is required for WebP (this ffmpeg has no WebP encoder). Install it with: brew install webp")
                }
                args += ["-c:v", "libwebp", "-quality", String(o.quality ?? 85)]
            case .avif:
                guard job.capabilities.has("libsvtav1") else {
                    throw IPCError("missing_tool", "avifenc is required for AVIF (this ffmpeg has no AV1 encoder). Install it with: brew install libavif")
                }
                // SVT-AV1 needs even dimensions and 4:2:0.
                filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
                args += ["-c:v", "libsvtav1", "-crf", String(QualityMapping.av1CRF(o.quality ?? 85)), "-preset", "6",
                         "-pix_fmt", "yuv420p", "-f", "avif"]
            default:
                throw IPCError("unsupported", "ffmpeg isn't used for \(job.format.title) images.")
            }
            if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
            if o.stripMetadata == true { args += ["-map_metadata", "-1"] }
        }
    }
}

/// Arguments for the standalone image encoders.
public enum ImageToolArguments {
    /// `cwebp`. The color profile is always kept; other metadata only when not stripping.
    public static func cwebp(input: String, output: String, quality: Int, stripMetadata: Bool) -> [String] {
        ["-quiet", "-mt", "-q", String(min(max(quality, 0), 100)), "-metadata", stripMetadata ? "icc" : "all", input, "-o", output]
    }

    /// `avifenc` (libavif 1.x). The color profile is always kept.
    public static func avifenc(input: String, output: String, quality: Int, stripMetadata: Bool) -> [String] {
        var args = ["-q", String(min(max(quality, 0), 100)), "--speed", "6", "-j", "all"]
        if stripMetadata { args += ["--ignore-exif", "--ignore-xmp"] }
        return args + [input, output]
    }
}

/// Shell-quotes a command for display (`--dry-run`).
public func shellQuoted(_ words: [String]) -> String {
    words.map { w in
        if !w.isEmpty, w.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=+,%@".contains($0) }) { return w }
        return "'" + w.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
}
