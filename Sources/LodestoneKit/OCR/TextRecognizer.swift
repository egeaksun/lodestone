import CoreGraphics
import Foundation
import ImageIO
import LodestoneCore
import Vision

/// Text and code recognition with Vision. Shared by the app (screen captures) and the CLI
/// (`lodestone ocr <files>`). Calls block for tens to hundreds of milliseconds: run them off the
/// main thread.
public enum TextRecognizer {
    public struct Options: Sendable {
        /// Vision language identifiers ("en-US"); empty means automatic detection.
        public var languages: [String]
        /// Accurate (slower, more languages) or fast recognition.
        public var accurate: Bool
        /// Also look for QR codes and barcodes.
        public var detectCodes: Bool

        public init(languages: [String] = [], accurate: Bool = true, detectCodes: Bool = true) {
            self.languages = languages
            self.accurate = accurate
            self.detectCodes = detectCodes
        }
    }

    /// Identifiers Vision can recognize at the given accuracy ("en-US", "zh-Hans", ...).
    public static func supportedLanguages(accurate: Bool = true) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    /// Maps codes like "en" or "zh-Hant" to Vision's identifiers. Unknown ones come back in `unsupported`.
    public static func resolveLanguages(_ requested: [String], accurate: Bool = true) -> (languages: [String], unsupported: [String]) {
        OCRLanguages.resolve(requested, supported: supportedLanguages(accurate: accurate))
    }

    /// Recognizes an image file (anything ImageIO reads: PNG, JPEG, HEIC, TIFF, GIF, BMP, WebP...).
    public static func recognize(fileAt url: URL, options: Options = Options()) throws -> OCRResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            let exists = FileManager.default.fileExists(atPath: url.path)
            throw IPCError(exists ? "unreadable" : "not_found",
                           exists ? "Couldn't read an image from \(url.path). Use PNG, JPEG, HEIC, TIFF, GIF or WebP."
                                  : "No file at \(url.path)")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return try recognize(image, orientation: CGImagePropertyOrientation(rawValue: raw) ?? .up, options: options)
    }

    public static func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation = .up, options: Options = Options()) throws -> OCRResult {
        let start = Date()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = options.accurate ? .accurate : .fast
        text.usesLanguageCorrection = true
        if options.languages.isEmpty {
            text.automaticallyDetectsLanguage = true
        } else {
            text.recognitionLanguages = options.languages
        }
        var requests: [VNRequest] = [text]
        let codes = VNDetectBarcodesRequest()
        if options.detectCodes { requests.append(codes) }

        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do {
            try handler.perform(requests)
        } catch {
            throw IPCError.failed("Text recognition failed: \(error.localizedDescription)")
        }

        // Orientations 5–8 rotate by 90°, so the upright image is the source's height wide.
        let rotated = orientation.rawValue >= 5
        let width = Double(rotated ? image.height : image.width)
        let height = Double(rotated ? image.width : image.height)
        func box(_ r: CGRect) -> OCRBox {
            // Vision: normalized, origin bottom-left. Ours: pixels, origin top-left.
            OCRBox(x: (r.minX * width).rounded(), y: ((1 - r.maxY) * height).rounded(),
                   width: (r.width * width).rounded(), height: (r.height * height).rounded())
        }

        let lines: [OCRLine] = (text.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(text: candidate.string, confidence: Double(candidate.confidence), box: box(observation.boundingBox))
        }
        var found: [OCRCode] = []
        for observation in codes.results ?? [] {
            guard let payload = observation.payloadStringValue, !found.contains(where: { $0.payload == payload }) else { continue }
            found.append(OCRCode(payload: payload, symbology: symbologyName(observation.symbology), box: box(observation.boundingBox)))
        }
        let ms = (Date().timeIntervalSince(start) * 1000).rounded()
        return OCRResult(lines: lines, codes: found, width: Int(width), height: Int(height), languages: options.languages, ms: ms)
    }

    /// "VNBarcodeSymbologyQR" → "qr", "VNBarcodeSymbologyEAN13" → "ean13".
    static func symbologyName(_ symbology: VNBarcodeSymbology) -> String {
        let raw = symbology.rawValue
        let prefix = "VNBarcodeSymbology"
        return (raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw).lowercased()
    }
}
