import Foundation

/// What a file is, for the converter.
public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case image, video, audio

    public var title: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        }
    }

    public var pluralTitle: String {
        switch self {
        case .image: "Images"
        case .video: "Video"
        case .audio: "Audio"
        }
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "heic", "heif", "webp", "avif", "tif", "tiff", "gif", "bmp", "jp2", "psd",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "ico", "icns", "tga", "exr",
    ]
    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "m2ts", "mts", "ts", "3gp", "ogv", "mxf",
    ]
    private static let audioExtensions: Set<String> = [
        "m4a", "aac", "mp3", "wav", "wave", "aif", "aiff", "aifc", "flac", "opus", "ogg", "oga", "caf", "wma", "alac", "m4b", "mka",
    ]

    /// A guess from the file extension alone. Cheap enough for deciding which drop actions to offer;
    /// the engine confirms by probing the file.
    public static func guess(pathExtension ext: String) -> MediaKind? {
        let e = ext.lowercased()
        if imageExtensions.contains(e) { return .image }
        if videoExtensions.contains(e) { return .video }
        if audioExtensions.contains(e) { return .audio }
        return nil
    }
}

/// A target format. The file extension is `fileExtension`.
public enum OutputFormat: String, Codable, CaseIterable, Sendable {
    case png, jpeg, heic, webp, avif, tiff, gif
    case mp4, mov, webm
    case m4a, mp3, wav, aiff, flac, opus

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        default: rawValue
        }
    }

    public var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .webp: "WebP"
        case .avif: "AVIF"
        case .tiff: "TIFF"
        case .gif: "GIF"
        case .mp4: "MP4"
        case .mov: "MOV"
        case .webm: "WebM"
        case .m4a: "M4A"
        case .mp3: "MP3"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .flac: "FLAC"
        case .opus: "Opus"
        }
    }

    public var isImage: Bool { [.png, .jpeg, .heic, .webp, .avif, .tiff, .gif].contains(self) }
    public var isVideoContainer: Bool { [.mp4, .mov, .webm].contains(self) }
    public var isAudio: Bool { [.m4a, .mp3, .wav, .aiff, .flac, .opus].contains(self) }
    /// Formats that keep every sample: bit depth applies to these.
    public var isLosslessAudio: Bool { [.wav, .aiff, .flac].contains(self) }

    /// Accepts the raw value, the extension and common aliases ("jpg", "tif", "aif", "ogg").
    public static func parse(_ text: String) -> OutputFormat? {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if let f = OutputFormat(rawValue: t) { return f }
        switch t {
        case "jpg", "jpe": return .jpeg
        case "tif": return .tiff
        case "heif": return .heic
        case "aif", "aifc": return .aiff
        case "ogg", "oga": return .opus
        case "m4v": return .mp4
        case "qt": return .mov
        case "wave": return .wav
        default: return nil
        }
    }

    /// What a source of `kind` can become.
    public static func targets(for kind: MediaKind) -> [OutputFormat] {
        switch kind {
        case .image: [.png, .jpeg, .heic, .webp, .avif, .tiff, .gif]
        case .video: [.mp4, .mov, .webm, .gif, .m4a, .mp3, .wav, .aiff, .flac, .opus]
        case .audio: [.m4a, .mp3, .wav, .aiff, .flac, .opus]
        }
    }
}

/// How a conversion is carried out, decided by the source kind and the target format.
public enum ConvertRoute: String, Codable, Sendable {
    /// Image to image.
    case image
    /// Video to MP4, MOV or WebM.
    case video
    /// Video to animated GIF.
    case gif
    /// Audio to audio, or the audio track of a video.
    case audio

    public init?(source: MediaKind, format: OutputFormat) {
        guard OutputFormat.targets(for: source).contains(format) else { return nil }
        switch (source, format) {
        case (.image, _): self = .image
        case (.video, .gif): self = .gif
        case (.video, let f) where f.isVideoContainer: self = .video
        default: self = .audio
        }
    }

    /// Which presets apply.
    public var presetKind: MediaKind {
        switch self {
        case .image: .image
        case .video, .gif: .video
        case .audio: .audio
        }
    }
}

/// Video encoders. The hardware ones (VideoToolbox) are fast; x264/x265 are slower and make smaller files.
public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264, hevc, x264, x265, prores, vp9, av1

    public var title: String {
        switch self {
        case .h264: "H.264 (hardware, fast)"
        case .hevc: "HEVC (hardware, fast)"
        case .x264: "H.264 (x264, slower, smaller)"
        case .x265: "HEVC (x265, slowest, smallest)"
        case .prores: "ProRes (editing)"
        case .vp9: "VP9"
        case .av1: "AV1 (slow, smallest)"
        }
    }

    public var containers: [OutputFormat] {
        switch self {
        case .h264, .hevc, .x264, .x265: [.mp4, .mov]
        case .prores: [.mov]
        case .vp9, .av1: [.webm]
        }
    }

    /// The codec a container gets when the preset's codec doesn't fit it.
    public static func fallback(for format: OutputFormat) -> VideoCodec {
        format == .webm ? .vp9 : .h264
    }

    public static func parse(_ text: String) -> VideoCodec? {
        switch text.lowercased() {
        case "h264", "h.264", "avc": .h264
        case "hevc", "h265", "h.265": .hevc
        case "x264", "libx264": .x264
        case "x265", "libx265": .x265
        case "prores": .prores
        case "vp9": .vp9
        case "av1", "svtav1": .av1
        default: nil
        }
    }
}

/// What happens to a video's audio.
public enum AudioTrack: String, Codable, CaseIterable, Sendable {
    /// Keep the audio as is when the container accepts it, otherwise AAC 256 kbps (Opus in WebM).
    case copy
    case aac128, aac192, aac256
    case remove

    public var title: String {
        switch self {
        case .copy: "Keep original"
        case .aac128: "AAC 128 kbps"
        case .aac192: "AAC 192 kbps"
        case .aac256: "AAC 256 kbps"
        case .remove: "Remove"
        }
    }

    public var bitrate: Int? {
        switch self {
        case .aac128: 128
        case .aac192: 192
        case .aac256: 256
        default: nil
        }
    }

    public static func parse(_ text: String) -> AudioTrack? {
        switch text.lowercased() {
        case "copy", "keep": .copy
        case "aac128", "128": .aac128
        case "aac192", "192", "aac": .aac192
        case "aac256", "256": .aac256
        case "remove", "none", "off": .remove
        default: nil
        }
    }
}

/// Codec inside an M4A file.
public enum AudioCodec: String, Codable, CaseIterable, Sendable {
    case aac, alac

    public var title: String { self == .aac ? "AAC" : "Apple Lossless (ALAC)" }
}

/// Sample format for lossless audio.
public enum BitDepth: String, Codable, CaseIterable, Sendable {
    case int16 = "16"
    case int24 = "24"
    case float32 = "32f"

    public var title: String {
        switch self {
        case .int16: "16-bit"
        case .int24: "24-bit"
        case .float32: "32-bit float"
        }
    }

    public static func parse(_ text: String) -> BitDepth? {
        switch text.lowercased() {
        case "16": .int16
        case "24": .int24
        case "32", "32f", "float", "f32": .float32
        default: nil
        }
    }
}

/// A size limit. Never enlarges.
///
/// `dimension(n)` means the longest edge for images and the shorter edge for video, so "1080" is
/// 1080p whether the video is landscape or portrait.
public enum MaxSize: Equatable, Sendable, Codable, CustomStringConvertible {
    case original
    case dimension(Int)
    case box(width: Int, height: Int)
    case percent(Double)

    /// "original", "1080", "1920x1080", "50%".
    public static func parse(_ text: String) -> MaxSize? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if t == "original" || t == "0" { return .original }
        if t.hasSuffix("%") {
            guard let p = Double(t.dropLast()), p > 0, p <= 100 else { return nil }
            return .percent(p)
        }
        if t.hasSuffix("p"), let n = Int(t.dropLast()), n > 0 { return .dimension(n) }
        if t.hasSuffix("px"), let n = Int(t.dropLast(2)), n > 0 { return .dimension(n) }
        let parts = t.split(separator: "x")
        if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 { return .box(width: w, height: h) }
        if let n = Int(t), n > 0 { return .dimension(n) }
        return nil
    }

    public var description: String {
        switch self {
        case .original: "original"
        case .dimension(let n): String(n)
        case .box(let w, let h): "\(w)x\(h)"
        case .percent(let p): (p == p.rounded() ? String(Int(p)) : String(p)) + "%"
        }
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = MaxSize.parse(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad size '\(s)'"))
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}
