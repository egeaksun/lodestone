import Foundation

/// What ffprobe (or AVFoundation) reports about a media file. Only the fields the converter needs.
public struct MediaInfo: Codable, Equatable, Sendable {
    public struct Video: Codable, Equatable, Sendable {
        public var codec: String
        /// Stored size, before rotation.
        public var width: Int
        public var height: Int
        public var fps: Double?
        /// Display rotation in degrees (phone videos are often stored landscape with ±90).
        public var rotation: Int
        public var pixelFormat: String?

        public init(codec: String, width: Int, height: Int, fps: Double? = nil, rotation: Int = 0, pixelFormat: String? = nil) {
            self.codec = codec
            self.width = width
            self.height = height
            self.fps = fps
            self.rotation = rotation
            self.pixelFormat = pixelFormat
        }

        /// Size as displayed (what ffmpeg's filters see, since it auto-rotates).
        public var displaySize: (width: Int, height: Int) {
            abs(rotation) % 180 == 90 ? (height, width) : (width, height)
        }
    }

    public struct Audio: Codable, Equatable, Sendable {
        public var codec: String
        public var sampleRate: Int?
        public var channels: Int?
        public var sampleFormat: String?
        /// Bits per sample for PCM and lossless codecs; nil for lossy ones.
        public var bits: Int?

        public init(codec: String, sampleRate: Int? = nil, channels: Int? = nil, sampleFormat: String? = nil, bits: Int? = nil) {
            self.codec = codec
            self.sampleRate = sampleRate
            self.channels = channels
            self.sampleFormat = sampleFormat
            self.bits = bits
        }

        private static let lossy: Set<String> = ["aac", "mp3", "opus", "vorbis", "ac3", "eac3", "wmav2", "mp2"]

        /// The bit depth to keep when converting to a lossless format. Nil for lossy sources.
        public var losslessDepth: BitDepth? {
            if Self.lossy.contains(codec) { return nil }
            if codec.hasPrefix("pcm_f") { return .float32 }
            switch bits {
            case .some(let b) where b > 16: return .int24
            case .some(let b) where b > 0: return .int16
            default: break
            }
            if codec.hasPrefix("pcm_s16") { return .int16 }
            if codec.hasPrefix("pcm_s24") || codec.hasPrefix("pcm_s32") { return .int24 }
            return nil
        }
    }

    public var formatName: String?
    public var duration: Double?
    /// The main video stream (cover art excluded), if any.
    public var video: Video?
    public var audio: [Audio]

    public init(formatName: String? = nil, duration: Double? = nil, video: Video? = nil, audio: [Audio] = []) {
        self.formatName = formatName
        self.duration = duration
        self.video = video
        self.audio = audio
    }

    /// Video if there's a real video stream, audio if there's only audio. Still images and image
    /// sequences report a video stream too; callers check for images first.
    public var kind: MediaKind? {
        if video != nil { return .video }
        return audio.isEmpty ? nil : .audio
    }

    /// Parses `ffprobe -print_format json -show_format -show_streams`.
    public static func parseFFprobe(_ data: Data) throws -> MediaInfo {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IPCError.failed("ffprobe returned unexpected output")
        }
        func int(_ v: Any?) -> Int? {
            if let n = v as? Int { return n }
            if let n = v as? Double { return Int(n) }
            if let s = v as? String { return Int(s) }
            return nil
        }
        func double(_ v: Any?) -> Double? {
            if let n = v as? Double { return n }
            if let s = v as? String { return Double(s) }
            return nil
        }
        func rate(_ v: Any?) -> Double? {
            guard let s = v as? String else { return nil }
            let parts = s.split(separator: "/")
            guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b > 0, a > 0 else { return nil }
            return a / b
        }

        let format = root["format"] as? [String: Any]
        var info = MediaInfo(formatName: format?["format_name"] as? String, duration: double(format?["duration"]))
        for stream in root["streams"] as? [[String: Any]] ?? [] {
            let codec = stream["codec_name"] as? String ?? "unknown"
            switch stream["codec_type"] as? String {
            case "video":
                let disposition = stream["disposition"] as? [String: Any]
                if int(disposition?["attached_pic"]) == 1 || info.video != nil { continue }
                var rotation = 0
                for side in stream["side_data_list"] as? [[String: Any]] ?? [] {
                    if let r = int(side["rotation"]) { rotation = r }
                }
                if rotation == 0, let tags = stream["tags"] as? [String: Any], let r = int(tags["rotate"]) { rotation = r }
                info.video = Video(codec: codec, width: int(stream["width"]) ?? 0, height: int(stream["height"]) ?? 0,
                                   fps: rate(stream["avg_frame_rate"]) ?? rate(stream["r_frame_rate"]),
                                   rotation: rotation, pixelFormat: stream["pix_fmt"] as? String)
                if info.duration == nil { info.duration = double(stream["duration"]) }
            case "audio":
                let bits = int(stream["bits_per_raw_sample"]).flatMap { $0 > 0 ? $0 : nil }
                    ?? int(stream["bits_per_sample"]).flatMap { $0 > 0 ? $0 : nil }
                info.audio.append(Audio(codec: codec, sampleRate: int(stream["sample_rate"]), channels: int(stream["channels"]),
                                        sampleFormat: stream["sample_fmt"] as? String, bits: bits))
                if info.duration == nil { info.duration = double(stream["duration"]) }
            default:
                continue
            }
        }
        return info
    }
}

/// The ffmpeg encoders available, from `ffmpeg -encoders`.
public struct FFmpegCapabilities: Sendable, Equatable {
    public var encoders: Set<String>

    public init(encoders: Set<String>) { self.encoders = encoders }

    /// Everything the converter can use (for tests and dry runs without ffmpeg).
    public static let full = FFmpegCapabilities(encoders: [
        "h264_videotoolbox", "hevc_videotoolbox", "prores_videotoolbox", "libx264", "libx265", "libvpx-vp9", "libsvtav1",
        "aac", "aac_at", "alac", "libmp3lame", "flac", "libopus", "gif", "libwebp",
        "pcm_s16le", "pcm_s24le", "pcm_f32le", "pcm_s16be", "pcm_s24be", "pcm_f32be",
    ])

    public func has(_ encoder: String) -> Bool { encoders.contains(encoder) }

    /// Parses the encoder table printed by `ffmpeg -hide_banner -encoders`.
    public static func parseEncoderList(_ text: String) -> FFmpegCapabilities {
        var names: Set<String> = []
        var inTable = false
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("------") { inTable = true; continue }
            guard inTable else { continue }
            let fields = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if fields.count >= 2, fields[0].count == 6 { names.insert(String(fields[1])) }
        }
        return FFmpegCapabilities(encoders: names)
    }
}
