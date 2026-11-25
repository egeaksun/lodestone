import Foundation
import LodestoneCore

/// Results of the PDF tools, as the CLI prints them with --json and IPC returns them.
/// Sizes are in bytes, page numbers 1-based, dimensions in points.

public struct PDFMergeResult: Codable, Sendable {
    public var inputs: [String]
    public var output: String
    public var pages: Int
    public var bytes: Int64
}

public struct PDFCompressResult: Codable, Sendable {
    public var input: String
    /// Nil when the result wasn't smaller and the original was kept.
    public var output: String?
    /// "gs" or "pdfkit".
    public var engine: String
    public var level: String
    public var originalBytes: Int64
    public var compressedBytes: Int64
    /// Fraction of the original saved, 0...1 (0 when the original was kept).
    public var saved: Double
    public var keptOriginal: Bool
    public var message: String
}

public struct PDFFromImagesResult: Codable, Sendable {
    public var inputs: [String]
    public var output: String
    public var pages: Int
    public var pageSize: String
    public var margin: Double
    public var bytes: Int64
}

public struct PDFPagesFile: Codable, Sendable {
    public var path: String
    public var pages: [Int]
    public var bytes: Int64
}

public struct PDFExtractResult: Codable, Sendable {
    public var input: String
    public var outputs: [PDFPagesFile]
}

public struct PDFRotateResult: Codable, Sendable {
    public var input: String
    public var output: String
    public var angle: Int
    public var pages: [Int]
    public var bytes: Int64
}

public struct PDFToImagesResult: Codable, Sendable {
    public var input: String
    public var folder: String
    public var files: [String]
    public var format: String
    public var dpi: Int
}

public struct PDFInfo: Codable, Sendable {
    public struct Size: Codable, Sendable, Equatable {
        public var width: Double
        public var height: Double
    }

    public var path: String
    public var bytes: Int64
    public var pages: Int
    /// Size of the first page (after its rotation), or nil for a locked document.
    public var pageSize: Size?
    /// True when every page has the same size.
    public var uniformPageSize: Bool
    public var version: String
    public var encrypted: Bool
    /// Encrypted with an open password: nothing else can be read without it.
    public var locked: Bool
    /// Pages with selectable text.
    public var textPages: Int
    public var hasTextLayer: Bool
    public var title: String?
    public var author: String?
    public var creator: String?
    public var producer: String?
}

public struct PDFOCRResult: Codable, Sendable {
    public var input: String
    public var output: String
    public var pages: Int
    public var textPagesBefore: Int
    public var textPagesAfter: Int
    public var bytes: Int64
}

public struct BackgroundRemovalResult: Codable, Sendable {
    public var input: String
    public var output: String
    public var width: Int
    public var height: Int
    public var cropped: Bool
    /// Separate subjects found (all are kept).
    public var subjects: Int
    public var bytes: Int64
}

/// How `pdf extract` / `pdf split` group the selected pages into files.
public enum PDFExtractMode: String, CaseIterable, Codable, Sendable {
    /// All selected pages in one PDF.
    case combined
    /// One PDF per comma-separated item of the selection.
    case perRange
    /// One PDF per selected page.
    case perPage
}

public enum PDFCompressionEngine: String, CaseIterable, Codable, Sendable {
    /// Ghostscript when installed, PDFKit otherwise.
    case auto
    case gs
    case pdfkit
}

public enum PDFImageFormat: String, CaseIterable, Codable, Sendable {
    case png, jpeg

    public var fileExtension: String { self == .png ? "png" : "jpg" }
    var typeIdentifier: CFString { (self == .png ? "public.png" : "public.jpeg") as CFString }
}
