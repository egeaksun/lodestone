import Foundation

/// Conversion settings. Every field is optional: a preset sets some, the user overrides some, and
/// whatever is still nil means "keep the original" (or the format's sensible default).
public struct ConvertOptions: Codable, Equatable, Sendable {
    /// 0 (smallest) ... 100 (best). Mapped per encoder by `QualityMapping`.
    public var quality: Int?
    public var maxSize: MaxSize?
    /// Removes EXIF, GPS and other tags. The color profile is always kept.
    public var stripMetadata: Bool?

    // Video
    public var videoCodec: VideoCodec?
    /// Maximum frame rate; 0 = original.
    public var fps: Int?
    public var audioTrack: AudioTrack?
    /// Copy the streams without re-encoding (the Instant preset).
    public var copyStreams: Bool?

    // Audio
    public var audioCodec: AudioCodec?
    /// kbps for lossy formats. Nil = derived from `quality`.
    public var audioBitrate: Int?
    /// Hz; 0 = original.
    public var sampleRate: Int?
    public var bitDepth: BitDepth?
    /// 1 or 2; 0 = original.
    public var channels: Int?

    public init(quality: Int? = nil, maxSize: MaxSize? = nil, stripMetadata: Bool? = nil, videoCodec: VideoCodec? = nil,
                fps: Int? = nil, audioTrack: AudioTrack? = nil, copyStreams: Bool? = nil, audioCodec: AudioCodec? = nil,
                audioBitrate: Int? = nil, sampleRate: Int? = nil, bitDepth: BitDepth? = nil, channels: Int? = nil) {
        self.quality = quality
        self.maxSize = maxSize
        self.stripMetadata = stripMetadata
        self.videoCodec = videoCodec
        self.fps = fps
        self.audioTrack = audioTrack
        self.copyStreams = copyStreams
        self.audioCodec = audioCodec
        self.audioBitrate = audioBitrate
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
    }

    /// These options with every non-nil field of `other` taking precedence.
    public func overlaid(by other: ConvertOptions) -> ConvertOptions {
        ConvertOptions(
            quality: other.quality ?? quality, maxSize: other.maxSize ?? maxSize,
            stripMetadata: other.stripMetadata ?? stripMetadata, videoCodec: other.videoCodec ?? videoCodec,
            fps: other.fps ?? fps, audioTrack: other.audioTrack ?? audioTrack, copyStreams: other.copyStreams ?? copyStreams,
            audioCodec: other.audioCodec ?? audioCodec, audioBitrate: other.audioBitrate ?? audioBitrate,
            sampleRate: other.sampleRate ?? sampleRate, bitDepth: other.bitDepth ?? bitDepth, channels: other.channels ?? channels)
    }

    public var isEmpty: Bool { self == ConvertOptions() }

    /// Checks ranges. Throws `IPCError("invalid_params", ...)`.
    public func validate() throws {
        if let q = quality, !(0...100).contains(q) { throw IPCError.invalidParams("Quality must be 0–100.") }
        if let f = fps, f < 0 || f > 240 { throw IPCError.invalidParams("FPS must be 1–240, or 0 for the original.") }
        if let r = sampleRate, r != 0 && !(8000...384_000).contains(r) { throw IPCError.invalidParams("Sample rate must be in Hz, for example 44100 or 48000.") }
        if let c = channels, !(0...8).contains(c) { throw IPCError.invalidParams("Channels must be 1 (mono), 2 (stereo) or 0 for the original.") }
        if let b = audioBitrate, !(32...512).contains(b) { throw IPCError.invalidParams("Bitrate must be 32–512 kbps.") }
    }

    /// 44100 → "44.1 kHz", 48000 → "48 kHz".
    public static func kHz(_ rate: Int) -> String {
        rate % 1000 == 0 ? "\(rate / 1000) kHz" : String(format: "%.1f kHz", Double(rate) / 1000)
    }

    /// Human-readable summary of the set fields, for `presets show` and the panel.
    public var summary: String {
        var parts: [String] = []
        if copyStreams == true { parts.append("copy streams (no re-encode)") }
        if let videoCodec { parts.append(videoCodec.rawValue) }
        if let quality { parts.append("quality \(quality)") }
        if let maxSize, maxSize != .original { parts.append("max \(maxSize)") }
        if let fps, fps > 0 { parts.append("≤\(fps) fps") }
        if let audioTrack { parts.append("audio \(audioTrack.rawValue)") }
        if let audioCodec { parts.append(audioCodec.rawValue) }
        if let audioBitrate { parts.append("\(audioBitrate) kbps") }
        if let sampleRate, sampleRate > 0 { parts.append(Self.kHz(sampleRate)) }
        if let bitDepth { parts.append(bitDepth.title) }
        if let channels, channels > 0 { parts.append(channels == 1 ? "mono" : "\(channels) ch") }
        if stripMetadata == true { parts.append("strip metadata") }
        return parts.isEmpty ? "original settings" : parts.joined(separator: ", ")
    }
}

/// A named set of options for one kind of media. Built-in presets ship with the app; custom ones are
/// saved as JSON in Application Support and shared by the app and the CLI.
public struct Preset: Codable, Equatable, Sendable {
    /// Stable identifier used by the CLI and settings ("balanced", "compress", "my-youtube").
    public var id: String
    public var name: String
    public var kind: MediaKind
    public var summary: String
    /// Preferred target format, used when none is chosen.
    public var format: OutputFormat?
    public var options: ConvertOptions
    public var builtIn: Bool

    public init(id: String, name: String, kind: MediaKind, summary: String = "", format: OutputFormat? = nil,
                options: ConvertOptions, builtIn: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.summary = summary
        self.format = format
        self.options = options
        self.builtIn = builtIn
    }

    enum CodingKeys: String, CodingKey { case id, name, kind, summary, format, options, builtIn }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(MediaKind.self, forKey: .kind)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        format = try c.decodeIfPresent(OutputFormat.self, forKey: .format)
        options = try c.decodeIfPresent(ConvertOptions.self, forKey: .options) ?? ConvertOptions()
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? false
    }

    /// "My YouTube Preset" → "my-youtube-preset".
    public static func slug(_ name: String) -> String {
        let lowered = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(lowered).split(separator: "-").joined(separator: "-")
    }
}

public enum BuiltInPresets {
    public static let video: [Preset] = [
        Preset(id: "instant", name: "Instant (same quality)", kind: .video,
               summary: "Changes the container without re-encoding. Seconds, no quality loss; needs compatible streams.",
               options: ConvertOptions(audioTrack: .copy, copyStreams: true), builtIn: true),
        Preset(id: "high-quality", name: "High quality", kind: .video,
               summary: "HEVC on the hardware encoder at high quality, original size and audio.",
               options: ConvertOptions(quality: 80, videoCodec: .hevc, audioTrack: .copy), builtIn: true),
        Preset(id: "balanced", name: "Balanced", kind: .video,
               summary: "H.264 on the hardware encoder. Plays everywhere; fast.",
               options: ConvertOptions(quality: 65, videoCodec: .h264, audioTrack: .aac192), builtIn: true),
        Preset(id: "small-file", name: "Small file", kind: .video,
               summary: "HEVC with x265 (slow), up to 1080p. Smallest files for archiving.",
               options: ConvertOptions(quality: 50, maxSize: .dimension(1080), videoCodec: .x265, audioTrack: .aac128), builtIn: true),
        Preset(id: "share", name: "Share", kind: .video,
               summary: "H.264 up to 1080p, small, without metadata. For chat and email.",
               format: .mp4,
               options: ConvertOptions(quality: 50, maxSize: .dimension(1080), stripMetadata: true, videoCodec: .h264, audioTrack: .aac128),
               builtIn: true),
    ]

    public static let image: [Preset] = [
        Preset(id: "standard", name: "Standard", kind: .image, summary: "Quality 85, original size and metadata.",
               options: ConvertOptions(quality: 85), builtIn: true),
        Preset(id: "compress", name: "Compress", kind: .image, summary: "Quality 65: much smaller, still looks good.",
               options: ConvertOptions(quality: 65), builtIn: true),
        Preset(id: "resize-50", name: "Resize 50%", kind: .image, summary: "Half the width and height.",
               options: ConvertOptions(quality: 85, maxSize: .percent(50)), builtIn: true),
        Preset(id: "resize-2048", name: "Resize to 2048 px", kind: .image, summary: "Longest edge at most 2048 pixels.",
               options: ConvertOptions(quality: 85, maxSize: .dimension(2048)), builtIn: true),
        Preset(id: "strip-metadata", name: "Strip metadata", kind: .image,
               summary: "Removes EXIF, GPS location and camera data; keeps the color profile. Lossless when the format stays the same.",
               options: ConvertOptions(stripMetadata: true), builtIn: true),
    ]

    public static let audio: [Preset] = [
        Preset(id: "audio-high", name: "High (256 kbps)", kind: .audio, summary: "AAC 256 kbps, MP3 V0, Opus 192 kbps: transparent.",
               options: ConvertOptions(quality: 90), builtIn: true),
        Preset(id: "audio-standard", name: "Standard (192 kbps)", kind: .audio, summary: "AAC 192 kbps, MP3 V2, Opus 128 kbps: good quality, moderate size.",
               options: ConvertOptions(quality: 70), builtIn: true),
        Preset(id: "audio-small", name: "Small (128 kbps)", kind: .audio, summary: "AAC 128 kbps, MP3 V5, Opus 96 kbps: speech and previews.",
               options: ConvertOptions(quality: 45), builtIn: true),
        Preset(id: "lossless", name: "Lossless (original)", kind: .audio,
               summary: "Keeps the original sample rate and bit depth in WAV, AIFF, FLAC or ALAC. AAC 192 kbps for lossy formats.",
               options: ConvertOptions(), builtIn: true),
        Preset(id: "cd-quality", name: "CD quality (16-bit/44.1)", kind: .audio,
               summary: "Lossless formats at 16-bit / 44.1 kHz, dithered when reducing bit depth.",
               options: ConvertOptions(quality: 90, sampleRate: 44100, bitDepth: .int16), builtIn: true),
        Preset(id: "studio-24-48", name: "Studio (24-bit/48)", kind: .audio, summary: "Lossless formats at 24-bit / 48 kHz.",
               options: ConvertOptions(quality: 90, sampleRate: 48000, bitDepth: .int24), builtIn: true),
        Preset(id: "hires-24-96", name: "Hi-res (24-bit/96)", kind: .audio, summary: "Lossless formats at 24-bit / 96 kHz.",
               options: ConvertOptions(quality: 90, sampleRate: 96000, bitDepth: .int24), builtIn: true),
    ]

    public static var all: [Preset] { video + image + audio }

    public static func defaultID(for kind: MediaKind) -> String {
        switch kind {
        case .image: "standard"
        case .video: "balanced"
        case .audio: "audio-standard"
        }
    }

    /// The default preset for converting to `format`: lossless audio formats default to "lossless".
    public static func defaultID(for kind: MediaKind, format: OutputFormat?) -> String {
        kind == .audio && format?.isLosslessAudio == true ? "lossless" : defaultID(for: kind)
    }

    /// Whether a preset makes sense for a format. The bitrate-only audio presets don't for lossless formats.
    public static func suits(_ preset: Preset, format: OutputFormat?) -> Bool {
        guard preset.builtIn, format?.isLosslessAudio == true else { return true }
        return !["audio-high", "audio-standard", "audio-small"].contains(preset.id)
    }

    public static func defaultPreset(for kind: MediaKind) -> Preset {
        all.first { $0.id == defaultID(for: kind) }!
    }

    public static func forKind(_ kind: MediaKind) -> [Preset] {
        switch kind {
        case .image: image
        case .video: video
        case .audio: audio
        }
    }

    /// Finds a preset by id or name (case-insensitive) in `presets`.
    public static func find(_ query: String, in presets: [Preset]) -> Preset? {
        let q = query.lowercased()
        return presets.first { $0.id == q } ?? presets.first { $0.name.lowercased() == q }
            ?? presets.first { Preset.slug($0.name) == Preset.slug(query) }
    }
}
