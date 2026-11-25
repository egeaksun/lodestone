import AppKit
import CryptoKit
import LodestoneCore

/// What was on the pasteboard at one change, read on the main thread. `prepare` turns it into a
/// history item (hashing, PNG encoding), which can run on a background queue.
public struct ClipboardCapture: Sendable {
    public var types: [String]
    public var string: String?
    public var rtf: Data?
    public var html: Data?
    /// PNG or TIFF data as found on the pasteboard.
    public var image: Data?
    public var fileURLs: [URL]

    public init(types: [String], string: String? = nil, rtf: Data? = nil, html: Data? = nil, image: Data? = nil, fileURLs: [URL] = []) {
        self.types = types
        self.string = string
        self.rtf = rtf
        self.html = html
        self.image = image
        self.fileURLs = fileURLs
    }

    public enum Rejection: String, Error, Sendable {
        case empty, tooLarge
    }

    /// The item and its blobs, or why it isn't stored.
    public func prepare(sourceApp: String?, sourceBundleID: String?, date: Date = Date()) -> Result<(ClipboardItem, [String: Data]), Rejection> {
        func make(_ kind: ClipboardItem.Kind, text: String, truncated: Bool = false, blobs: [String: Data], hash: String,
                  files: [String] = [], size: (Int, Int)? = nil) -> Result<(ClipboardItem, [String: Data]), Rejection> {
            let bytes = blobs.values.reduce(0) { $0 + $1.count } + text.utf8.count
            guard bytes <= ClipboardLimits.maxCaptureBytes else { return .failure(.tooLarge) }
            let item = ClipboardItem(kind: kind, text: text, textTruncated: truncated, blobs: blobs.keys.sorted(), filePaths: files,
                                     imageWidth: size?.0, imageHeight: size?.1, byteSize: bytes, contentHash: hash,
                                     sourceApp: sourceApp, sourceBundleID: sourceBundleID, date: date)
            return .success((item, blobs))
        }

        if !fileURLs.isEmpty {
            let paths = fileURLs.map(\.path)
            return make(.files, text: paths.joined(separator: "\n"), blobs: [:], hash: "f:" + Self.sha(Data(paths.joined(separator: "\n").utf8)), files: paths)
        }

        let text = string ?? rtf.flatMap { Self.attributedText($0, .rtf) } ?? html.flatMap { Self.attributedText($0, .html) }
        if let text, !text.isEmpty {
            var blobs: [String: Data] = [:]
            if let rtf { blobs["rtf"] = rtf }
            if let html { blobs["html"] = html }
            let limit = ClipboardLimits.indexTextLimit
            let truncated = text.count > limit
            if truncated { blobs["txt"] = Data(text.utf8) }
            return make(blobs["rtf"] != nil || blobs["html"] != nil ? .richText : .text, text: truncated ? String(text.prefix(limit)) : text,
                        truncated: truncated, blobs: blobs, hash: "t:" + Self.sha(Data(text.utf8)))
        }

        if let image {
            guard image.count <= ClipboardLimits.maxCaptureBytes * 4 else { return .failure(.tooLarge) }
            guard let png = Self.png(image) else { return .failure(.empty) }
            guard png.data.count <= ClipboardLimits.maxImageBytes else { return .failure(.tooLarge) }
            return make(.image, text: "", blobs: ["png": png.data], hash: "i:" + Self.sha(png.data), size: (png.width, png.height))
        }
        return .failure(.empty)
    }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func attributedText(_ data: Data, _ type: NSAttributedString.DocumentType) -> String? {
        // HTML parsing through NSAttributedString needs the main thread (WebKit); use a tag strip instead.
        if type == .html {
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            return html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil))?.string
    }

    /// PNG data and pixel size, re-encoding TIFF and other formats.
    static func png(_ data: Data) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        if CGImageSourceGetType(source) as String? == "public.png" { return (data, width, height) }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, image.width, image.height)
    }
}

/// Reading and writing the system pasteboard, for the app and the CLI.
public enum PasteboardIO {
    public static let concealed = NSPasteboard.PasteboardType(ClipboardRules.concealedType)
    public static let transient = NSPasteboard.PasteboardType(ClipboardRules.transientType)

    /// The types on the pasteboard, as strings.
    public static func types(_ pb: NSPasteboard = .general) -> [String] {
        (pb.types ?? []).map(\.rawValue)
    }

    /// Reads the representations history keeps. Call only after the skip rules passed: reading
    /// concealed data is what they prevent.
    public static func capture(_ pb: NSPasteboard = .general) -> ClipboardCapture? {
        let types = pb.types ?? []
        guard !types.isEmpty else { return nil }
        var capture = ClipboardCapture(types: types.map(\.rawValue))
        if types.contains(.fileURL) {
            capture.fileURLs = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            if !capture.fileURLs.isEmpty { return capture }
        }
        capture.string = pb.string(forType: .string)
        if types.contains(.rtf) { capture.rtf = pb.data(forType: .rtf) }
        if types.contains(.html) { capture.html = pb.data(forType: .html) }
        if capture.string == nil {
            if types.contains(.png) { capture.image = pb.data(forType: .png) }
            else if types.contains(.tiff) { capture.image = pb.data(forType: .tiff) }
        }
        return capture
    }

    /// The pasteboard as plain text: its string, the text of RTF or HTML, or file paths one per line.
    public static func plainText(_ pb: NSPasteboard = .general) -> String? {
        if let s = pb.string(forType: .string) { return s }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(\.path).joined(separator: "\n")
        }
        if let rtf = pb.data(forType: .rtf) { return ClipboardCapture.attributedText(rtf, .rtf) }
        if let html = pb.data(forType: .html) { return ClipboardCapture.attributedText(html, .html) }
        return nil
    }

    /// Replaces the pasteboard with plain text. `transient` marks it so clipboard managers skip it.
    @discardableResult
    public static func setText(_ text: String, _ pb: NSPasteboard = .general, transient: Bool = false) -> Int {
        pb.clearContents()
        pb.setString(text, forType: .string)
        if transient { pb.setData(Data(), forType: Self.transient) }
        return pb.changeCount
    }

    /// Puts a history item on the pasteboard, with all its stored representations or as plain text.
    /// Returns the new change count.
    public static func write(_ item: ClipboardItem, from store: ClipboardStore, to pb: NSPasteboard = .general, plain: Bool = false) throws -> Int {
        if plain || item.kind == .text {
            guard item.kind != .image else {
                throw IPCError("no_text", "That item is an image, so it has no plain text. Paste it without --plain.")
            }
            return setText(store.fullText(item), pb)
        }
        switch item.kind {
        case .files:
            pb.clearContents()
            pb.writeObjects(item.filePaths.map { URL(fileURLWithPath: $0) as NSURL })
        case .image:
            guard let png = store.data(item.id, "png") else { throw missing(item) }
            pb.clearContents()
            pb.declareTypes([.png, .tiff], owner: nil)
            pb.setData(png, forType: .png)
            if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        case .richText, .text:
            var types: [NSPasteboard.PasteboardType] = []
            let rtf = store.data(item.id, "rtf")
            let html = store.data(item.id, "html")
            if rtf != nil { types.append(.rtf) }
            if html != nil { types.append(.html) }
            types.append(.string)
            pb.declareTypes(types, owner: nil)
            if let rtf { pb.setData(rtf, forType: .rtf) }
            if let html { pb.setData(html, forType: .html) }
            pb.setString(store.fullText(item), forType: .string)
        }
        return pb.changeCount
    }

    private static func missing(_ item: ClipboardItem) -> IPCError {
        IPCError("not_found", "The data for clipboard item \(item.id) is missing. Delete it with `lodestone clipboard delete \(item.id)`.")
    }
}

/// Every item and type on the pasteboard, to put back after a temporary change (paste as plain text).
public struct PasteboardSnapshot {
    private var items: [[(NSPasteboard.PasteboardType, Data)]]

    public init(_ pb: NSPasteboard = .general) {
        items = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Writes the saved contents back. Returns the new change count.
    @discardableResult
    public func restore(_ pb: NSPasteboard = .general) -> Int {
        pb.clearContents()
        let restored = items.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
        return pb.changeCount
    }
}
