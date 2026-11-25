import Foundation

/// Maps the 0–100 quality slider onto each encoder's own scale. 100 is best, 0 is smallest.
public enum QualityMapping {
    private static func clamp(_ q: Int) -> Double { Double(min(max(q, 0), 100)) }
    private static func round(_ v: Double) -> Int { Int(v.rounded(.toNearestOrAwayFromZero)) }

    /// VideoToolbox `-q:v` (1–100, higher is better).
    public static func videoToolbox(_ q: Int) -> Int { max(1, Int(clamp(q))) }

    /// x264 CRF: 100 → 11, 65 → 23 (x264's default), 0 → 44.
    public static func x264CRF(_ q: Int) -> Int { round(44 - 0.33 * clamp(q)) }

    /// x265 CRF: 100 → 15, 65 → 27, 0 → 48. x265 needs about 5 more CRF than x264 for similar quality.
    public static func x265CRF(_ q: Int) -> Int { round(48 - 0.33 * clamp(q)) }

    /// libvpx-vp9 CRF (0–63): 100 → 12, 65 → 26, 0 → 52.
    public static func vp9CRF(_ q: Int) -> Int { round(52 - 0.4 * clamp(q)) }

    /// SVT-AV1 CRF (0–63): 100 → 18, 65 → 32, 0 → 58.
    public static func av1CRF(_ q: Int) -> Int { round(58 - 0.4 * clamp(q)) }

    /// ProRes profile: 0 proxy, 1 LT, 2 standard, 3 HQ.
    public static func proResProfile(_ q: Int) -> Int {
        switch q {
        case ..<35: 0
        case ..<55: 1
        case ..<80: 2
        default: 3
        }
    }

    /// ImageIO lossy compression quality (0–1).
    public static func imageIO(_ q: Int) -> Double { clamp(q) / 100 }

    /// LAME VBR level `-q:a` (0 best … 9 smallest): 90+ → V0, 70 → V2, 45 → V5.
    public static func mp3VBR(_ q: Int) -> Int { min(9, max(0, (99 - Int(clamp(q))) / 10)) }

    /// AAC bitrate in kbps.
    public static func aacBitrate(_ q: Int) -> Int {
        switch q {
        case 85...: 256
        case 60...: 192
        case 35...: 128
        default: 96
        }
    }

    /// Opus bitrate in kbps (Opus needs less than AAC for the same quality).
    public static func opusBitrate(_ q: Int) -> Int {
        switch q {
        case 85...: 192
        case 60...: 128
        case 35...: 96
        default: 64
        }
    }
}

/// Pixel arithmetic for resizing. Never enlarges.
public enum SizeFitting {
    /// The output size for an image of `width`×`height` under `limit`.
    /// `dimension(n)` limits the longest edge.
    public static func image(width: Int, height: Int, limit: MaxSize?) -> (width: Int, height: Int) {
        guard width > 0, height > 0, let limit else { return (width, height) }
        let scale: Double
        switch limit {
        case .original: scale = 1
        case .percent(let p): scale = p / 100
        case .dimension(let n): scale = Double(n) / Double(max(width, height))
        case .box(let w, let h): scale = min(Double(w) / Double(width), Double(h) / Double(height))
        }
        guard scale < 1 else { return (width, height) }
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// The output size for a video frame under `limit`, with even dimensions (required by most codecs).
    /// `dimension(n)` limits the shorter edge, so 1080 means 1080p in landscape or portrait.
    public static func video(width: Int, height: Int, limit: MaxSize?) -> (width: Int, height: Int) {
        guard width > 0, height > 0, let limit else { return (width, height) }
        let scale: Double
        switch limit {
        case .original: scale = 1
        case .percent(let p): scale = p / 100
        case .dimension(let n): scale = Double(n) / Double(min(width, height))
        case .box(let w, let h): scale = min(Double(w) / Double(width), Double(h) / Double(height))
        }
        guard scale < 1 else { return (width, height) }
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }
}

/// Chooses output file names. Never replaces an existing file unless told to.
public enum OutputNaming {
    /// `<directory>/<source name>.<ext>`, or, if that's taken (exists, is the source itself, or was
    /// already chosen for another file in this batch), "<name> (converted).<ext>", then
    /// "<name> (converted 2).<ext>", "(converted 3)", ...
    ///
    /// With `overwrite`, an existing file may be replaced, but never the source and never a name
    /// already chosen in this batch. `reserved` holds standardized paths.
    public static func output(for source: URL, format: OutputFormat, directory: URL? = nil, overwrite: Bool = false,
                              reserved: Set<String> = [], exists: (URL) -> Bool) -> URL {
        let dir = directory ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let ext = format.fileExtension
        // Compared case-insensitively: "Clip.MOV" and "Clip.mov" are the same file on APFS.
        let sourcePath = source.standardizedFileURL.path.lowercased()
        let reserved = Set(reserved.map { $0.lowercased() })

        // Same scheme as the PDF and image tools (`SiblingFile`): "clip (converted).mp4", "clip (converted 2).mp4".
        func candidate(_ n: Int) -> URL {
            dir.appendingPathComponent(n == 0 ? SiblingFile.name(base: base, tag: nil, ext: ext)
                                              : SiblingFile.name(base: base, tag: "converted", ext: ext, attempt: n))
        }
        func free(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path.lowercased()
            if path == sourcePath || reserved.contains(path) { return false }
            return overwrite || !exists(url)
        }

        var n = 0
        while true {
            let url = candidate(n)
            if free(url) { return url }
            n += 1
        }
    }
}
