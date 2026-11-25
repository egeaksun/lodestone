import CoreGraphics
import Foundation

/// How hard `pdf compress` works. Each level keeps text and vector art as they are and only
/// re-samples and re-compresses images.
public enum PDFCompressionLevel: String, CaseIterable, Codable, Sendable {
    case light, balanced, strong

    public var title: String {
        switch self {
        case .light: "Light"
        case .balanced: "Balanced"
        case .strong: "Strong"
        }
    }

    public var summary: String {
        switch self {
        case .light: "Print quality, images kept at 225 dpi"
        case .balanced: "Screen and email, images at 150 dpi"
        case .strong: "Smallest file, images at 96 dpi"
        }
    }

    /// Target image resolution in dots per inch.
    public var imageDPI: Int {
        switch self {
        case .light: 225
        case .balanced: 150
        case .strong: 96
        }
    }

    /// Ghostscript's preset this level builds on.
    public var ghostscriptPreset: String {
        switch self {
        case .light: "/printer"
        case .balanced: "/ebook"
        case .strong: "/screen"
        }
    }
}

/// Arguments for compressing a PDF with Ghostscript's pdfwrite device.
public enum GhostscriptArguments {
    public static func compress(input: String, output: String, level: PDFCompressionLevel) -> [String] {
        let dpi = String(level.imageDPI)
        let monoDPI = String(level.imageDPI * 2)
        // Only re-sample images noticeably above the target, so already-small images aren't degraded.
        let threshold = level == .strong ? "1.0" : "1.5"
        var args = [
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.6",
            "-dPDFSETTINGS=\(level.ghostscriptPreset)",
            "-dNOPAUSE", "-dBATCH", "-dSAFER",
            // Progress ("Page 3") goes to stderr, where ProcessRunner streams it line by line.
            "-sstdout=%stderr",
            // Keep page orientation as authored; pdfwrite would otherwise guess from the text direction.
            "-dAutoRotatePages=/None",
            "-dDetectDuplicateImages=true",
            "-dCompressFonts=true",
            "-dSubsetFonts=true",
        ]
        for kind in ["Color", "Gray"] {
            args += [
                "-dDownsample\(kind)Images=true",
                "-d\(kind)ImageDownsampleType=/Bicubic",
                "-d\(kind)ImageResolution=\(dpi)",
                "-d\(kind)ImageDownsampleThreshold=\(threshold)",
            ]
        }
        args += [
            "-dDownsampleMonoImages=true",
            "-dMonoImageDownsampleType=/Subsample",
            "-dMonoImageResolution=\(monoDPI)",
            "-dMonoImageDownsampleThreshold=\(threshold)",
            "-sOutputFile=\(output)",
            input,
        ]
        return args
    }

    /// The page number in a progress line Ghostscript prints ("Page 3"), or nil for other lines.
    public static func page(fromOutputLine line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Page ") else { return nil }
        return Int(trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces))
    }
}

/// Page size for `pdf from-images`.
public enum PDFPageSize: String, CaseIterable, Codable, Sendable {
    /// Each page is the size of its image (plus the margin).
    case fit
    case a4
    case letter

    public var title: String {
        switch self {
        case .fit: "Fit to Image"
        case .a4: "A4"
        case .letter: "US Letter"
        }
    }

    /// Portrait size in points, or nil for `fit`.
    public var portraitSize: CGSize? {
        switch self {
        case .fit: nil
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .letter: CGSize(width: 612, height: 792)
        }
    }
}

public enum PageLayout {
    /// The page size and where the image goes on it, for an image `image` points large.
    ///
    /// Fixed page sizes turn landscape for landscape images. Images larger than the space inside the
    /// margins are scaled down to fit; smaller ones keep their size. The image is centered.
    public static func place(image: CGSize, on pageSize: PDFPageSize, margin: CGFloat) -> (page: CGSize, imageRect: CGRect) {
        let margin = max(0, margin)
        guard var page = pageSize.portraitSize else {
            let page = CGSize(width: image.width + 2 * margin, height: image.height + 2 * margin)
            return (page, CGRect(x: margin, y: margin, width: image.width, height: image.height))
        }
        if image.width > image.height { page = CGSize(width: page.height, height: page.width) }
        // Never let margins eat the whole page.
        let m = min(margin, min(page.width, page.height) / 2 - 1)
        let available = CGSize(width: page.width - 2 * m, height: page.height - 2 * m)
        guard image.width > 0, image.height > 0 else { return (page, .zero) }
        let scale = min(1, available.width / image.width, available.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        let origin = CGPoint(x: (page.width - size.width) / 2, y: (page.height - size.height) / 2)
        return (page, CGRect(origin: origin, size: size))
    }
}
