import AVFoundation
import Foundation
import ImageIO
import LodestoneCore
import UniformTypeIdentifiers

/// What ImageIO reports about an image, without decoding it.
public struct ImageInfo: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// EXIF orientation, 1–8 (1 = upright).
    public var orientation: Int
    public var typeIdentifier: String
    public var frameCount: Int

    /// Size as displayed, after applying the orientation.
    public var orientedSize: (width: Int, height: Int) { orientation >= 5 ? (height, width) : (width, height) }

    /// The output format "same as the original" maps to.
    public var sameFormat: OutputFormat {
        guard let type = UTType(typeIdentifier) else { return .png }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .png) { return .png }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heic }
        if type.conforms(to: .tiff) && !type.conforms(to: .rawImage) { return .tiff }
        if type.conforms(to: .gif) { return .gif }
        if type.conforms(to: .webP) { return .webp }
        if typeIdentifier == "public.avif" { return .avif }
        if type.conforms(to: .rawImage) { return .jpeg }
        return .png
    }
}

/// A file the converter has looked at.
public struct ProbedMedia: Sendable {
    public var url: URL
    public var kind: MediaKind
    /// From ffprobe or AVFoundation, for video and audio.
    public var media: MediaInfo?
    public var image: ImageInfo?
}

/// Works out what a file is: UTType from the extension, then ImageIO for images and ffprobe (or
/// AVFoundation without ffmpeg) for audio and video.
public enum MediaProbe {
    /// Cheap check from the file name only. Used to decide which drop actions to offer.
    public static func quickKind(_ url: URL) -> MediaKind? {
        let ext = url.pathExtension
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if type.conforms(to: .audio) { return .audio }
        }
        return MediaKind.guess(pathExtension: ext)
    }

    public static func probe(_ url: URL) async throws -> ProbedMedia {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw IPCError.notFound("\(url.path) doesn't exist or is a folder.")
        }
        let guess = quickKind(url)
        if guess == .image || guess == nil, let image = imageInfo(url) {
            return ProbedMedia(url: url, kind: .image, image: image)
        }
        if let ffprobe = ExternalTool.ffprobe.url {
            let result = try await ProcessRunner.run(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path])
            if result.status == 0, let info = try? MediaInfo.parseFFprobe(result.stdout), let kind = info.kind {
                return ProbedMedia(url: url, kind: kind, media: info)
            }
        } else if let info = await avInfo(url), let kind = info.kind {
            return ProbedMedia(url: url, kind: kind, media: info)
        }
        if let guess, guess != .image { return ProbedMedia(url: url, kind: guess) }
        throw IPCError("unsupported", "\(url.lastPathComponent) isn't an image, video or audio file Lodestone can read.")
    }

    public static func imageInfo(_ url: URL) -> ImageInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        // ImageIO also opens some movie containers; only accept real images.
        guard UTType(type)?.conforms(to: .image) == true else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0 else { return nil }
        return ImageInfo(width: w, height: h, orientation: props[kCGImagePropertyOrientation] as? Int ?? 1,
                         typeIdentifier: type, frameCount: CGImageSourceGetCount(source))
    }

    /// Stream facts from AVFoundation, when ffprobe isn't installed.
    static func avInfo(_ url: URL) async -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        var info = MediaInfo(duration: duration.seconds.isFinite ? duration.seconds : nil)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let fps = try? await track.load(.nominalFrameRate)
            let angle = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            info.video = MediaInfo.Video(codec: formats.first.map { codecName(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown",
                                         width: Int(size.width), height: Int(size.height), fps: fps.map(Double.init), rotation: angle)
        }
        for track in (try? await asset.loadTracks(withMediaType: .audio)) ?? [] {
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            let asbd = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            info.audio.append(MediaInfo.Audio(codec: formats.first.map { codecName(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown",
                                              sampleRate: asbd.map { Int($0.mSampleRate) }, channels: asbd.map { Int($0.mChannelsPerFrame) },
                                              bits: asbd.flatMap { $0.mBitsPerChannel > 0 ? Int($0.mBitsPerChannel) : nil }))
        }
        return info
    }

    /// FourCC → ffmpeg-style codec name, for the codecs the converter cares about.
    private static func codecName(_ code: FourCharCode) -> String {
        switch code {
        case kCMVideoCodecType_H264: "h264"
        case kCMVideoCodecType_HEVC: "hevc"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes422HQ,
             kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy: "prores"
        case kAudioFormatMPEG4AAC: "aac"
        case kAudioFormatAppleLossless: "alac"
        case kAudioFormatLinearPCM: "pcm_s16le"
        case kAudioFormatMPEGLayer3: "mp3"
        default: "unknown"
        }
    }
}

/// The encoders the installed ffmpeg has. Looked up once per process.
public enum FFmpegInfo {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: FFmpegCapabilities?

    public static func capabilities() async -> FFmpegCapabilities {
        if let cached = lock.withLock({ cached }) { return cached }
        var caps = FFmpegCapabilities(encoders: [])
        if let ffmpeg = ExternalTool.ffmpeg.url,
           let result = try? await ProcessRunner.run(ffmpeg, ["-hide_banner", "-encoders"]), result.status == 0 {
            caps = FFmpegCapabilities.parseEncoderList(String(decoding: result.stdout, as: UTF8.self))
        }
        lock.withLock { cached = caps }
        return caps
    }
}
