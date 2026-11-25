@preconcurrency import AVFoundation
import Foundation
import LodestoneCore

/// MP4, MOV and M4A through AVAssetExportSession, for when ffmpeg isn't installed. Only Apple's
/// fixed presets are available, so quality, fps and audio options don't apply.
enum AVFoundationEngine {
    static func supports(route: ConvertRoute, format: OutputFormat) -> Bool {
        switch route {
        case .video: format == .mp4 || format == .mov
        case .audio: format == .m4a
        default: false
        }
    }

    /// The AVAssetExportSession preset for these options, plus warnings about what's ignored.
    static func exportPreset(route: ConvertRoute, format: OutputFormat, options: ConvertOptions) -> (String, [String]) {
        var warnings: [String] = []
        if route == .audio {
            if options.audioCodec == .alac || options.sampleRate != nil || options.bitDepth != nil {
                warnings.append("Without ffmpeg, M4A is always AAC at the original sample rate.")
            }
            return (AVAssetExportPresetAppleM4A, warnings)
        }
        if options.copyStreams == true { return (AVAssetExportPresetPassthrough, warnings) }
        if options.quality != nil || (options.fps ?? 0) > 0 || options.audioTrack == .remove {
            warnings.append("Without ffmpeg, quality, frame rate and audio options don't apply (brew install ffmpeg).")
        }
        let codec = options.videoCodec ?? .h264
        if codec == .prores && format == .mov { return (AVAssetExportPresetAppleProRes422LPCM, warnings) }
        let hevc = codec == .hevc || codec == .x265
        var limit = 0
        if case .dimension(let n) = options.maxSize { limit = n }
        if case .box(_, let h) = options.maxSize { limit = h }
        switch (hevc, limit) {
        case (true, 1...1080): return (AVAssetExportPresetHEVC1920x1080, warnings)
        case (true, 1...): return (AVAssetExportPresetHEVC3840x2160, warnings)
        case (true, _): return (AVAssetExportPresetHEVCHighestQuality, warnings)
        case (false, 1...480): return (AVAssetExportPreset640x480, warnings)
        case (false, 481...720): return (AVAssetExportPreset1280x720, warnings)
        case (false, 721...1080): return (AVAssetExportPreset1920x1080, warnings)
        case (false, 1081...): return (AVAssetExportPreset3840x2160, warnings)
        default: return (AVAssetExportPresetHighestQuality, warnings)
        }
    }

    static func export(input: URL, output: URL, format: OutputFormat, preset: String, stripMetadata: Bool,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        let fileType: AVFileType = switch format {
        case .mov: .mov
        case .m4a: .m4a
        default: .mp4
        }
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: fileType),
              let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw IPCError("unsupported", "AVFoundation can't convert \(input.lastPathComponent) to \(format.title) this way. Install ffmpeg for more options: brew install ffmpeg")
        }
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        if stripMetadata { session.metadataItemFilter = .forSharing() }

        let box = SessionBox(session)
        let poller = Task {
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { poller.cancel() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { c.resume() }
            }
        } onCancel: {
            box.session.cancelExport()
        }
        switch session.status {
        case .completed: return
        case .cancelled: throw IPCError("cancelled", "Conversion cancelled.")
        default: throw IPCError.failed("AVFoundation export failed: \(session.error?.localizedDescription ?? "unknown error")")
        }
    }
}

/// AVAssetExportSession is thread-safe for progress reads and cancelExport, but isn't marked Sendable.
private final class SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

private extension AVAssetExportSession {
    static func compatibility(ofExportPreset preset: String, with asset: AVAsset, outputFileType: AVFileType) async -> Bool {
        await withCheckedContinuation { c in
            determineCompatibility(ofExportPreset: preset, with: asset, outputFileType: outputFileType) { c.resume(returning: $0) }
        }
    }
}
