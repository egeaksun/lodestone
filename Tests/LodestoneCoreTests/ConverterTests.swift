import Foundation
@testable import LodestoneCore
import XCTest

final class ConverterModelTests: XCTestCase {
    func testKindGuessFromExtension() {
        XCTAssertEqual(MediaKind.guess(pathExtension: "HEIC"), .image)
        XCTAssertEqual(MediaKind.guess(pathExtension: "dng"), .image)
        XCTAssertEqual(MediaKind.guess(pathExtension: "MOV"), .video)
        XCTAssertEqual(MediaKind.guess(pathExtension: "webm"), .video)
        XCTAssertEqual(MediaKind.guess(pathExtension: "aif"), .audio)
        XCTAssertEqual(MediaKind.guess(pathExtension: "flac"), .audio)
        XCTAssertNil(MediaKind.guess(pathExtension: "pdf"))
    }

    func testFormatParsingAndRoutes() {
        XCTAssertEqual(OutputFormat.parse("jpg"), .jpeg)
        XCTAssertEqual(OutputFormat.parse(".TIF"), .tiff)
        XCTAssertEqual(OutputFormat.parse("aif"), .aiff)
        XCTAssertNil(OutputFormat.parse("docx"))
        XCTAssertEqual(OutputFormat.jpeg.fileExtension, "jpg")

        XCTAssertEqual(ConvertRoute(source: .image, format: .webp), .image)
        XCTAssertEqual(ConvertRoute(source: .video, format: .mp4), .video)
        XCTAssertEqual(ConvertRoute(source: .video, format: .gif), .gif)
        XCTAssertEqual(ConvertRoute(source: .video, format: .flac), .audio)
        XCTAssertEqual(ConvertRoute(source: .audio, format: .mp3), .audio)
        XCTAssertNil(ConvertRoute(source: .audio, format: .mp4))
        XCTAssertNil(ConvertRoute(source: .image, format: .mp3))
        XCTAssertEqual(ConvertRoute.gif.presetKind, .video)
    }

    func testMaxSizeParsing() {
        XCTAssertEqual(MaxSize.parse("1080"), .dimension(1080))
        XCTAssertEqual(MaxSize.parse("720p"), .dimension(720))
        XCTAssertEqual(MaxSize.parse("1920x1080"), .box(width: 1920, height: 1080))
        XCTAssertEqual(MaxSize.parse("50%"), .percent(50))
        XCTAssertEqual(MaxSize.parse("original"), .original)
        XCTAssertNil(MaxSize.parse("150%"))
        XCTAssertNil(MaxSize.parse("big"))
        XCTAssertEqual(MaxSize.percent(50).description, "50%")
    }

    func testQualityMapping() {
        XCTAssertEqual(QualityMapping.x264CRF(65), 23) // x264's own default at the Balanced setting
        XCTAssertEqual(QualityMapping.x264CRF(100), 11)
        XCTAssertEqual(QualityMapping.x264CRF(0), 44)
        XCTAssertEqual(QualityMapping.x265CRF(65), 27)
        XCTAssertEqual(QualityMapping.vp9CRF(65), 26)
        XCTAssertEqual(QualityMapping.av1CRF(65), 32)
        XCTAssertEqual(QualityMapping.videoToolbox(0), 1)
        XCTAssertEqual(QualityMapping.videoToolbox(80), 80)
        XCTAssertEqual(QualityMapping.proResProfile(90), 3)
        XCTAssertEqual(QualityMapping.proResProfile(10), 0)
        XCTAssertEqual(QualityMapping.mp3VBR(90), 0)
        XCTAssertEqual(QualityMapping.mp3VBR(70), 2)
        XCTAssertEqual(QualityMapping.mp3VBR(45), 5)
        XCTAssertEqual(QualityMapping.mp3VBR(0), 9)
        XCTAssertEqual(QualityMapping.aacBitrate(90), 256)
        XCTAssertEqual(QualityMapping.aacBitrate(70), 192)
        XCTAssertEqual(QualityMapping.aacBitrate(45), 128)
        XCTAssertEqual(QualityMapping.imageIO(85), 0.85, accuracy: 0.0001)
        // Higher quality never means a higher CRF.
        for q in 0..<100 {
            XCTAssertGreaterThanOrEqual(QualityMapping.x264CRF(q), QualityMapping.x264CRF(q + 1))
            XCTAssertGreaterThanOrEqual(QualityMapping.vp9CRF(q), QualityMapping.vp9CRF(q + 1))
        }
    }

    func testSizeFitting() {
        XCTAssertTrue(SizeFitting.image(width: 4000, height: 3000, limit: .dimension(2048)) == (2048, 1536))
        XCTAssertTrue(SizeFitting.image(width: 3000, height: 4000, limit: .dimension(2048)) == (1536, 2048))
        XCTAssertTrue(SizeFitting.image(width: 4000, height: 3000, limit: .percent(50)) == (2000, 1500))
        XCTAssertTrue(SizeFitting.image(width: 800, height: 600, limit: .dimension(2048)) == (800, 600), "never enlarges")
        // Video: the short edge, even numbers.
        XCTAssertTrue(SizeFitting.video(width: 3840, height: 2160, limit: .dimension(1080)) == (1920, 1080))
        XCTAssertTrue(SizeFitting.video(width: 1080, height: 1920, limit: .dimension(720)) == (720, 1280))
        XCTAssertTrue(SizeFitting.video(width: 1918, height: 1080, limit: .dimension(721)) == (1280, 722))
        XCTAssertTrue(SizeFitting.video(width: 1280, height: 720, limit: .dimension(1080)) == (1280, 720))
        XCTAssertTrue(SizeFitting.video(width: 1920, height: 1080, limit: .box(width: 640, height: 640)) == (640, 360))
    }

    func testOutputNaming() {
        let src = URL(fileURLWithPath: "/tmp/x/clip.mov")
        var existing: Set<String> = []
        func name(_ format: OutputFormat, overwrite: Bool = false, reserved: Set<String> = [], dir: URL? = nil) -> String {
            OutputNaming.output(for: src, format: format, directory: dir, overwrite: overwrite, reserved: reserved) {
                existing.contains($0.path)
            }.path
        }
        XCTAssertEqual(name(.mp4), "/tmp/x/clip.mp4")
        // Same format as the source: never the source itself, even with overwrite.
        XCTAssertEqual(name(.mov), "/tmp/x/clip (converted).mov")
        XCTAssertEqual(name(.mov, overwrite: true), "/tmp/x/clip (converted).mov")
        existing = ["/tmp/x/clip.mp4"]
        XCTAssertEqual(name(.mp4), "/tmp/x/clip (converted).mp4")
        XCTAssertEqual(name(.mp4, overwrite: true), "/tmp/x/clip.mp4")
        existing = ["/tmp/x/clip.mp4", "/tmp/x/clip (converted).mp4"]
        XCTAssertEqual(name(.mp4), "/tmp/x/clip (converted)-2.mp4")
        // Names already chosen in the batch are skipped.
        XCTAssertEqual(name(.mp4, reserved: ["/tmp/x/clip (converted)-2.mp4"]), "/tmp/x/clip (converted)-3.mp4")
        // Case-insensitive file system: "clip.MOV" → "clip.mov" is the source.
        let upper = URL(fileURLWithPath: "/tmp/x/Clip.MOV")
        XCTAssertEqual(OutputNaming.output(for: upper, format: .mov) { _ in false }.lastPathComponent, "Clip (converted).mov")
        XCTAssertEqual(name(.mp4, dir: URL(fileURLWithPath: "/tmp/out")), "/tmp/out/clip.mp4")
    }

    func testOptionsOverlayAndPresets() {
        let base = BuiltInPresets.defaultPreset(for: .video).options
        let merged = base.overlaid(by: ConvertOptions(quality: 40, maxSize: .dimension(720)))
        XCTAssertEqual(merged.quality, 40)
        XCTAssertEqual(merged.maxSize, .dimension(720))
        XCTAssertEqual(merged.videoCodec, .h264)

        XCTAssertEqual(BuiltInPresets.find("Balanced", in: BuiltInPresets.all)?.id, "balanced")
        XCTAssertEqual(BuiltInPresets.find("small file", in: BuiltInPresets.all)?.id, "small-file")
        XCTAssertEqual(Set(BuiltInPresets.all.map(\.id)).count, BuiltInPresets.all.count, "ids are unique")
        for kind in MediaKind.allCases { XCTAssertEqual(BuiltInPresets.defaultPreset(for: kind).kind, kind) }
        XCTAssertEqual(Preset.slug("My YouTube  Preset!"), "my-youtube-preset")
        XCTAssertEqual(BuiltInPresets.defaultID(for: .audio, format: .flac), "lossless")
        XCTAssertEqual(BuiltInPresets.defaultID(for: .audio, format: .mp3), "audio-standard")
        let standard = BuiltInPresets.find("audio-standard", in: BuiltInPresets.all)!
        XCTAssertFalse(BuiltInPresets.suits(standard, format: .wav), "a bitrate preset means nothing for WAV")
        XCTAssertTrue(BuiltInPresets.suits(standard, format: .m4a))

        let data = try! JSONEncoder().encode(BuiltInPresets.all)
        XCTAssertEqual(try JSONDecoder().decode([Preset].self, from: data), BuiltInPresets.all)
        XCTAssertThrowsError(try ConvertOptions(quality: 101).validate())
        XCTAssertEqual(ConvertOptions.kHz(44100), "44.1 kHz")
        XCTAssertEqual(ConvertOptions.kHz(96000), "96 kHz")
    }

    // MARK: Probing

    private let ffprobeVideo = """
    {"streams": [
      {"codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080, "avg_frame_rate": "30000/1001", "pix_fmt": "yuv420p",
       "side_data_list": [{"side_data_type": "Display Matrix", "rotation": -90}]},
      {"codec_type": "audio", "codec_name": "aac", "sample_rate": "48000", "channels": 2, "sample_fmt": "fltp"},
      {"codec_type": "video", "codec_name": "mjpeg", "width": 600, "height": 600, "disposition": {"attached_pic": 1}}
     ], "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2", "duration": "12.5"}}
    """

    func testParseFFprobe() throws {
        let info = try MediaInfo.parseFFprobe(Data(ffprobeVideo.utf8))
        XCTAssertEqual(info.kind, .video)
        XCTAssertEqual(info.duration, 12.5)
        XCTAssertEqual(info.video?.codec, "h264")
        XCTAssertEqual(info.video?.fps ?? 0, 29.97, accuracy: 0.01)
        XCTAssertEqual(info.video?.rotation, -90)
        XCTAssertTrue(info.video!.displaySize == (1080, 1920))
        XCTAssertEqual(info.audio.first?.sampleRate, 48000)
        XCTAssertNil(info.audio.first?.losslessDepth)

        // Audio with cover art is audio, not video.
        let song = """
        {"streams": [
          {"codec_type": "audio", "codec_name": "flac", "sample_rate": "96000", "channels": 2, "sample_fmt": "s32", "bits_per_raw_sample": "24"},
          {"codec_type": "video", "codec_name": "png", "width": 500, "height": 500, "disposition": {"attached_pic": 1}}
        ], "format": {"duration": "200.0"}}
        """
        let audio = try MediaInfo.parseFFprobe(Data(song.utf8))
        XCTAssertEqual(audio.kind, .audio)
        XCTAssertEqual(audio.audio.first?.losslessDepth, .int24)

        let wav = MediaInfo.Audio(codec: "pcm_f32le", sampleRate: 96000, channels: 2, sampleFormat: "flt", bits: 32)
        XCTAssertEqual(wav.losslessDepth, .float32)
        XCTAssertEqual(MediaInfo.Audio(codec: "pcm_s16le", bits: 16).losslessDepth, .int16)
    }

    func testParseEncoderList() {
        let text = """
        Encoders:
         V..... = Video
         ------
         V....D libx264              libx264 H.264 / AVC
         V....D h264_videotoolbox    VideoToolbox H.264 Encoder (codec h264)
         A..... aac_at               aac (AudioToolbox) (codec aac)
        """
        let caps = FFmpegCapabilities.parseEncoderList(text)
        XCTAssertEqual(caps.encoders, ["libx264", "h264_videotoolbox", "aac_at"])
    }
}

final class FFmpegArgumentsTests: XCTestCase {
    private let movH264AAC = MediaInfo(duration: 10, video: .init(codec: "h264", width: 3840, height: 2160, fps: 59.94),
                                       audio: [.init(codec: "aac", sampleRate: 48000, channels: 2)])

    private func args(_ route: ConvertRoute, _ format: OutputFormat, preset id: String, _ overrides: ConvertOptions = ConvertOptions(),
                      source: MediaInfo? = nil, caps: FFmpegCapabilities = .full) throws -> FFmpegCommand {
        let preset = BuiltInPresets.find(id, in: BuiltInPresets.all)!
        return try FFmpegArguments.build(FFmpegJob(input: "in", output: "out.\(format.fileExtension)", format: format, route: route,
                                                   options: preset.options.overlaid(by: overrides), source: source ?? movH264AAC,
                                                   capabilities: caps))
    }

    private func value(_ args: [String], after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func testCommonPrefixNeverOverwritesByDefault() throws {
        let cmd = try args(.video, .mp4, preset: "balanced")
        XCTAssertEqual(Array(cmd.arguments.prefix(10)), ["-hide_banner", "-nostdin", "-loglevel", "error", "-progress", "pipe:2", "-nostats", "-n", "-i", "in"])
        XCTAssertEqual(cmd.arguments.last, "out.mp4")
    }

    func testInstantRemuxesCompatibleStreams() throws {
        let cmd = try args(.video, .mp4, preset: "instant")
        XCTAssertTrue(cmd.remux)
        XCTAssertEqual(value(cmd.arguments, after: "-c:v"), "copy")
        XCTAssertEqual(value(cmd.arguments, after: "-c:a"), "copy")
        XCTAssertEqual(value(cmd.arguments, after: "-movflags"), "+faststart")
    }

    func testInstantReencodesOnlyIncompatibleAudio() throws {
        var source = movH264AAC
        source.audio = [.init(codec: "pcm_s16le", sampleRate: 48000, channels: 2)]
        let cmd = try args(.video, .mp4, preset: "instant", source: source)
        XCTAssertFalse(cmd.remux)
        XCTAssertEqual(value(cmd.arguments, after: "-c:v"), "copy")
        XCTAssertEqual(value(cmd.arguments, after: "-c:a"), "aac_at")
        // MOV accepts PCM, so it's copied there.
        XCTAssertTrue(try args(.video, .mov, preset: "instant", source: source).remux)
    }

    func testInstantRefusesIncompatibleVideo() {
        let vp9 = MediaInfo(duration: 5, video: .init(codec: "vp9", width: 1280, height: 720), audio: [.init(codec: "opus")])
        XCTAssertThrowsError(try args(.video, .mp4, preset: "instant", source: vp9)) { error in
            XCTAssertEqual((error as? IPCError)?.code, "unsupported")
        }
        XCTAssertTrue(FFmpegArguments.canRemux(vp9, to: .webm))
    }

    func testBalancedUsesHardwareH264() throws {
        let a = try args(.video, .mp4, preset: "balanced").arguments
        XCTAssertEqual(value(a, after: "-c:v"), "h264_videotoolbox")
        XCTAssertEqual(value(a, after: "-q:v"), "65")
        XCTAssertEqual(value(a, after: "-c:a"), "aac_at")
        XCTAssertEqual(value(a, after: "-b:a"), "192k")
        XCTAssertNil(value(a, after: "-vf"), "no scaling at the original size")
        XCTAssertEqual(value(a, after: "-map_metadata"), "0")
    }

    func testSmallFileUsesX265AndScales() throws {
        let a = try args(.video, .mp4, preset: "small-file").arguments
        XCTAssertEqual(value(a, after: "-c:v"), "libx265")
        XCTAssertEqual(value(a, after: "-crf"), String(QualityMapping.x265CRF(50)))
        XCTAssertEqual(value(a, after: "-tag:v"), "hvc1")
        XCTAssertEqual(value(a, after: "-vf"), "scale=1920:1080:flags=lanczos")
    }

    func testShareStripsMetadataAndCapsFPS() throws {
        let a = try args(.video, .mp4, preset: "share", ConvertOptions(fps: 30)).arguments
        XCTAssertEqual(value(a, after: "-vf"), "scale=1920:1080:flags=lanczos,fps=30")
        XCTAssertEqual(value(a, after: "-map_metadata"), "-1")
        XCTAssertEqual(value(a, after: "-b:a"), "128k")
        // A cap above the source frame rate does nothing.
        XCTAssertNil(value(try args(.video, .mp4, preset: "balanced", ConvertOptions(fps: 60), source: MediaInfo(video: .init(codec: "h264", width: 1280, height: 720, fps: 30))).arguments, after: "-vf"))
    }

    func testCodecSwappedForContainer() throws {
        let cmd = try args(.video, .webm, preset: "balanced")
        XCTAssertEqual(value(cmd.arguments, after: "-c:v"), "libvpx-vp9")
        XCTAssertEqual(value(cmd.arguments, after: "-c:a"), "libopus")
        XCTAssertFalse(cmd.warnings.isEmpty)
        XCTAssertEqual(value(try args(.video, .mov, preset: "balanced", ConvertOptions(quality: 90, videoCodec: .prores)).arguments, after: "-profile:v"), "3")
    }

    func testSoftwareFallbackWithoutVideoToolbox() throws {
        let caps = FFmpegCapabilities(encoders: ["libx264", "aac"])
        let cmd = try args(.video, .mp4, preset: "balanced", caps: caps)
        XCTAssertEqual(value(cmd.arguments, after: "-c:v"), "libx264")
        XCTAssertEqual(value(cmd.arguments, after: "-crf"), "23")
        XCTAssertEqual(value(cmd.arguments, after: "-c:a"), "aac")
    }

    func testRemoveAudio() throws {
        let a = try args(.video, .mp4, preset: "balanced", ConvertOptions(audioTrack: .remove)).arguments
        XCTAssertTrue(a.contains("-an"))
        XCTAssertNil(value(a, after: "-c:a"))
    }

    func testScaleUsesDisplaySizeForRotatedVideo() throws {
        let portrait = MediaInfo(video: .init(codec: "hevc", width: 3840, height: 2160, rotation: 90), audio: [])
        XCTAssertEqual(value(try args(.video, .mp4, preset: "balanced", ConvertOptions(maxSize: .dimension(1080)), source: portrait).arguments, after: "-vf"),
                       "scale=1080:1920:flags=lanczos")
    }

    func testGIF() throws {
        let a = try args(.gif, .gif, preset: "balanced").arguments
        let vf = value(a, after: "-vf")!
        XCTAssertTrue(vf.hasPrefix("fps=15,scale=640:360:flags=lanczos,split"), vf)
        XCTAssertTrue(vf.contains("palettegen"))
        XCTAssertTrue(a.contains("-an"))
    }

    // MARK: Audio

    private let wav24 = MediaInfo(duration: 5, audio: [.init(codec: "pcm_s24le", sampleRate: 48000, channels: 2, sampleFormat: "s32", bits: 24)])

    func testFLAC24at96() throws {
        let a = try args(.audio, .flac, preset: "hires-24-96", source: wav24).arguments
        XCTAssertEqual(value(a, after: "-c:a"), "flac")
        XCTAssertEqual(value(a, after: "-ar"), "96000")
        XCTAssertEqual(value(a, after: "-sample_fmt"), "s32")
        XCTAssertEqual(value(a, after: "-bits_per_raw_sample"), "24")
        let af = value(a, after: "-af")!
        XCTAssertTrue(af.contains("osr=96000") && af.contains("osf=s32"), af)
        XCTAssertFalse(af.contains("dither"))
    }

    func testCDQualityDithers() throws {
        let a = try args(.audio, .wav, preset: "cd-quality", source: wav24).arguments
        XCTAssertEqual(value(a, after: "-c:a"), "pcm_s16le")
        XCTAssertEqual(value(a, after: "-ar"), "44100")
        XCTAssertTrue(value(a, after: "-af")!.contains("dither_method=triangular"))
        let aiff = try args(.audio, .aiff, preset: "audio-standard", ConvertOptions(bitDepth: .float32), source: wav24).arguments
        XCTAssertEqual(value(aiff, after: "-c:a"), "pcm_f32be")
    }

    func testLosslessKeepsSourceDepthByDefault() throws {
        XCTAssertEqual(value(try args(.audio, .wav, preset: "audio-standard", source: wav24).arguments, after: "-c:a"), "pcm_s24le")
        let alac = try args(.audio, .m4a, preset: "audio-standard", ConvertOptions(audioCodec: .alac), source: wav24).arguments
        XCTAssertEqual(value(alac, after: "-c:a"), "alac")
        XCTAssertEqual(value(alac, after: "-sample_fmt"), "s32p")
    }

    func testFloatToFLAC() throws {
        let f32 = MediaInfo(duration: 5, audio: [.init(codec: "pcm_f32le", sampleRate: 96000, channels: 2, bits: 32)])
        let cmd = try args(.audio, .flac, preset: "audio-standard", source: f32)
        XCTAssertEqual(value(cmd.arguments, after: "-bits_per_raw_sample"), "24")
        XCTAssertFalse(cmd.warnings.isEmpty)
        XCTAssertThrowsError(try args(.audio, .flac, preset: "audio-standard", ConvertOptions(bitDepth: .float32), source: f32))
    }

    func testLossyAudio() throws {
        let mp3 = try args(.audio, .mp3, preset: "audio-high", source: wav24).arguments
        XCTAssertEqual(value(mp3, after: "-c:a"), "libmp3lame")
        XCTAssertEqual(value(mp3, after: "-q:a"), "0")
        XCTAssertEqual(value(try args(.audio, .mp3, preset: "audio-high", ConvertOptions(audioBitrate: 320), source: wav24).arguments, after: "-b:a"), "320k")
        XCTAssertThrowsError(try args(.audio, .mp3, preset: "hires-24-96", source: wav24), "MP3 tops out at 48 kHz")
        XCTAssertEqual(value(try args(.audio, .m4a, preset: "audio-standard", source: wav24).arguments, after: "-b:a"), "192k")
        let opus = try args(.audio, .opus, preset: "audio-small", source: wav24)
        XCTAssertEqual(value(opus.arguments, after: "-b:a"), "96k")
        XCTAssertEqual(value(try args(.audio, .wav, preset: "audio-standard", ConvertOptions(channels: 1), source: wav24).arguments, after: "-ac"), "1")
    }

    func testExtractAudioFromVideo() throws {
        let a = try args(.audio, .m4a, preset: "audio-standard").arguments
        XCTAssertTrue(a.contains("-vn"))
        XCTAssertEqual(value(a, after: "-map"), "0:a:0")
        let silent = MediaInfo(video: .init(codec: "h264", width: 640, height: 480), audio: [])
        XCTAssertThrowsError(try args(.audio, .mp3, preset: "audio-standard", source: silent))
    }

    func testImageFallback() throws {
        let png = MediaInfo(video: .init(codec: "png", width: 4000, height: 3000))
        let avif = try args(.image, .avif, preset: "resize-50", source: png).arguments
        XCTAssertEqual(value(avif, after: "-c:v"), "libsvtav1")
        XCTAssertTrue(value(avif, after: "-vf")!.hasPrefix("scale=2000:1500"))
        XCTAssertThrowsError(try args(.image, .webp, preset: "standard", source: png, caps: FFmpegCapabilities(encoders: []))) { error in
            XCTAssertEqual((error as? IPCError)?.code, "missing_tool")
        }
    }

    func testImageToolArguments() {
        XCTAssertEqual(ImageToolArguments.cwebp(input: "a.png", output: "a.webp", quality: 80, stripMetadata: true),
                       ["-quiet", "-mt", "-q", "80", "-metadata", "icc", "a.png", "-o", "a.webp"])
        XCTAssertTrue(ImageToolArguments.avifenc(input: "a.jpg", output: "a.avif", quality: 60, stripMetadata: true).contains("--ignore-exif"))
        XCTAssertFalse(ImageToolArguments.avifenc(input: "a.jpg", output: "a.avif", quality: 60, stripMetadata: false).contains("--ignore-exif"))
    }

    func testProgressParsing() {
        XCTAssertEqual(FFmpegArguments.progressSeconds("out_time_us=1500000"), 1.5)
        XCTAssertNil(FFmpegArguments.progressSeconds("out_time_us=N/A"))
        XCTAssertNil(FFmpegArguments.progressSeconds("frame=10"))
        XCTAssertTrue(FFmpegArguments.isProgressLine("progress=continue"))
        XCTAssertFalse(FFmpegArguments.isProgressLine("[in#0 @ 0x1] moov atom not found"))
        XCTAssertEqual(shellQuoted(["ffmpeg", "-i", "my clip.mov", "-map", "0:a?"]), "ffmpeg -i 'my clip.mov' -map '0:a?'")
    }
}
