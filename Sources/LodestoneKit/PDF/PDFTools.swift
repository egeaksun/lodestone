import CoreGraphics
import Foundation
import ImageIO
import LodestoneCore
import PDFKit

/// PDF work shared by the app and the CLI. Everything runs in the calling process (PDFKit, plus
/// Ghostscript for stronger compression when it's installed). Each operation logs its start and
/// outcome under the "pdf" category, writes to a scratch file first and never overwrites a file.
///
/// Call these off the main thread: they block while they work. Cancelling the calling Task stops
/// them between pages (and terminates Ghostscript).
public enum PDFTools {
    static let category = "pdf"

    // MARK: Merge

    public static func merge(_ inputs: [URL], output: URL? = nil, progress: ProgressHandler? = nil) async throws -> PDFMergeResult {
        try await LoggedOperation.run(category, "merge", ["inputs": inputs.logValue, "engine": "pdfkit"]) {
            guard inputs.count >= 2 else { throw IPCError.invalidParams("Merging needs at least two PDFs") }
            let destination = try ResultFiles.destination(explicit: output, source: inputs[0], tag: "merged", ext: "pdf")
            let merged = PDFDocument()
            for (i, url) in inputs.enumerated() {
                try Task.checkCancellation()
                let doc = try open(url)
                for p in 0..<doc.pageCount {
                    guard let page = doc.page(at: p)?.copy() as? PDFPage else { continue }
                    merged.insert(page, at: merged.pageCount)
                }
                progress?(Double(i + 1) / Double(inputs.count + 1))
            }
            let final = try write(merged, to: destination)
            progress?(1)
            return PDFMergeResult(inputs: inputs.map(\.path), output: final.path, pages: merged.pageCount, bytes: ResultFiles.size(final))
        } outcome: { ["output": .string($0.output), "pages": .number(Double($0.pages)), "bytes": .number(Double($0.bytes))] }
    }

    // MARK: Compress

    /// Compresses images in the PDF; text stays text. When the result isn't smaller, nothing is
    /// written and the result says the original was kept.
    public static func compress(_ input: URL, output: URL? = nil, level: PDFCompressionLevel,
                                engine requested: PDFCompressionEngine = .auto,
                                progress: ProgressHandler? = nil) async throws -> PDFCompressResult {
        try await LoggedOperation.run(category, "compress", ["input": input.logValue, "level": .string(level.rawValue),
                                                             "requestedEngine": .string(requested.rawValue)]) {
            let doc = try open(input)
            let pageCount = doc.pageCount
            let gs: URL?
            switch requested {
            case .auto: gs = ExternalTool.gs.url
            case .gs: gs = try ExternalTool.gs.require()
            case .pdfkit: gs = nil
            }
            let engine = gs == nil ? "pdfkit" : "gs"
            let destination = try ResultFiles.destination(explicit: output, source: input, tag: "compressed", ext: "pdf")
            let originalBytes = ResultFiles.size(input)
            let temp = ResultFiles.temporary(ext: "pdf")
            defer { try? FileManager.default.removeItem(at: temp) }
            if let gs {
                let args = GhostscriptArguments.compress(input: input.path, output: temp.path, level: level)
                let result = try await ProcessRunner.run(gs, args) { line in
                    if let page = GhostscriptArguments.page(fromOutputLine: line), pageCount > 0 {
                        progress?(min(0.99, Double(page) / Double(pageCount)))
                    }
                }
                try Task.checkCancellation()
                guard result.status == 0, ResultFiles.size(temp) > 0 else {
                    let reason = result.stderr.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "exit \(result.status)"
                    throw IPCError.failed("Ghostscript couldn't compress \(input.lastPathComponent): \(reason)")
                }
            } else {
                progress?(0.1)
                var options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
                if level != .light { options[.optimizeImagesForScreenOption] = true }
                guard doc.write(to: temp, withOptions: options) else {
                    throw IPCError.failed("Couldn't write a compressed copy of \(input.lastPathComponent)")
                }
            }
            let compressedBytes = ResultFiles.size(temp)
            progress?(1)
            guard compressedBytes < originalBytes else {
                return PDFCompressResult(input: input.path, output: nil, engine: engine, level: level.rawValue,
                                         originalBytes: originalBytes, compressedBytes: compressedBytes, saved: 0, keptOriginal: true,
                                         message: "\(input.lastPathComponent) is already compact (\(formatBytes(originalBytes))); kept the original.")
            }
            let final = try ResultFiles.place(temp, at: destination)
            let saved = 1 - Double(compressedBytes) / Double(max(1, originalBytes))
            return PDFCompressResult(input: input.path, output: final.path, engine: engine, level: level.rawValue,
                                     originalBytes: originalBytes, compressedBytes: compressedBytes, saved: saved, keptOriginal: false,
                                     message: "\(formatBytes(originalBytes)) → \(formatBytes(compressedBytes)) (\(Int((saved * 100).rounded()))% smaller)")
        } outcome: { r in
            ["engine": .string(r.engine), "output": r.output.map { .string($0) } ?? .null, "originalBytes": .number(Double(r.originalBytes)),
             "compressedBytes": .number(Double(r.compressedBytes)), "keptOriginal": .bool(r.keptOriginal)]
        }
    }

    // MARK: Images → PDF

    /// One page per image, in order. Images keep their encoding where Quartz allows (JPEG data is
    /// embedded as is).
    public static func fromImages(_ inputs: [URL], output: URL? = nil, pageSize: PDFPageSize, margin: Double,
                                  progress: ProgressHandler? = nil) async throws -> PDFFromImagesResult {
        try await LoggedOperation.run(category, "from_images", ["inputs": inputs.logValue, "pageSize": .string(pageSize.rawValue),
                                                                "margin": .number(margin)]) {
            guard let first = inputs.first else { throw IPCError.invalidParams("No images given") }
            guard (0...300).contains(margin) else { throw IPCError.invalidParams("Margin must be between 0 and 300 points") }
            for url in inputs { try ResultFiles.requireFile(url) }
            let destination = try ResultFiles.destination(explicit: output, source: first, tag: inputs.count > 1 ? "images" : nil, ext: "pdf")
            let temp = ResultFiles.temporary(ext: "pdf")
            defer { try? FileManager.default.removeItem(at: temp) }
            guard let context = CGContext(temp as CFURL, mediaBox: nil, [kCGPDFContextCreator: "Lodestone"] as CFDictionary) else {
                throw IPCError.failed("Couldn't create a PDF")
            }
            var closed = false
            defer { if !closed { context.closePDF() } }
            for (i, url) in inputs.enumerated() {
                try Task.checkCancellation()
                let image = try ImageLoading.load(url)
                let placed = PageLayout.place(image: image.pointSize, on: pageSize, margin: CGFloat(margin))
                var box = CGRect(origin: .zero, size: placed.page)
                let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
                context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                context.interpolationQuality = .high
                context.draw(image.cgImage, in: placed.imageRect)
                context.endPDFPage()
                progress?(Double(i + 1) / Double(inputs.count + 1))
            }
            context.closePDF()
            closed = true
            let final = try ResultFiles.place(temp, at: destination)
            progress?(1)
            return PDFFromImagesResult(inputs: inputs.map(\.path), output: final.path, pages: inputs.count, pageSize: pageSize.rawValue,
                                       margin: margin, bytes: ResultFiles.size(final))
        } outcome: { ["output": .string($0.output), "pages": .number(Double($0.pages)), "bytes": .number(Double($0.bytes))] }
    }

    // MARK: Extract / split

    public static func extract(_ input: URL, pages selection: PageRanges, mode: PDFExtractMode, output: URL? = nil,
                               progress: ProgressHandler? = nil) async throws -> PDFExtractResult {
        try await LoggedOperation.run(category, "extract", ["input": input.logValue, "mode": .string(mode.rawValue)]) {
            let doc = try open(input)
            let groups = try selection.groups(pageCount: doc.pageCount)
            let files: [[Int]]
            switch mode {
            case .combined: files = [groups.flatMap { $0 }]
            case .perRange: files = groups
            case .perPage: files = groups.flatMap { $0 }.map { [$0] }
            }
            var outputs: [PDFPagesFile] = []
            // Several files go into a new folder when -o names one; otherwise next to the source.
            let folder: URL? = files.count > 1 && output != nil ? try ResultFiles.folder(explicit: output, source: input, tag: "pages") : nil
            for (i, pages) in files.enumerated() {
                try Task.checkCancellation()
                let part = PDFDocument()
                for n in pages {
                    if let page = doc.page(at: n - 1)?.copy() as? PDFPage { part.insert(page, at: part.pageCount) }
                }
                let tag = pages.count == 1 ? "page \(pages[0])" : "pages \(PageRanges.label(pages))"
                let destination = try ResultFiles.destination(explicit: folder ?? (files.count == 1 ? output : nil),
                                                              source: input, tag: tag, ext: "pdf")
                let final = try write(part, to: destination)
                outputs.append(PDFPagesFile(path: final.path, pages: pages, bytes: ResultFiles.size(final)))
                progress?(Double(i + 1) / Double(files.count))
            }
            return PDFExtractResult(input: input.path, outputs: outputs)
        } outcome: { ["outputs": .array($0.outputs.map { .string($0.path) })] }
    }

    // MARK: Rotate

    /// Rotates pages clockwise by a multiple of 90°. Nil `pages` means every page.
    public static func rotate(_ input: URL, angle: Int, pages selection: PageRanges? = nil, output: URL? = nil) async throws -> PDFRotateResult {
        try await LoggedOperation.run(category, "rotate", ["input": input.logValue, "angle": .number(Double(angle))]) {
            guard angle % 90 == 0 else { throw IPCError.invalidParams("The angle must be a multiple of 90 (90, 180, 270, -90)") }
            let doc = try open(input)
            let pages = try (selection ?? .all).pages(pageCount: doc.pageCount)
            let destination = try ResultFiles.destination(explicit: output, source: input, tag: "rotated", ext: "pdf")
            for n in Set(pages) {
                guard let page = doc.page(at: n - 1) else { continue }
                page.rotation = ((page.rotation + angle) % 360 + 360) % 360
            }
            let final = try write(doc, to: destination)
            return PDFRotateResult(input: input.path, output: final.path, angle: angle, pages: pages, bytes: ResultFiles.size(final))
        } outcome: { ["output": .string($0.output), "pages": .number(Double($0.pages.count))] }
    }

    // MARK: PDF → images

    public static func toImages(_ input: URL, format: PDFImageFormat, dpi: Int, pages selection: PageRanges? = nil,
                                output: URL? = nil, progress: ProgressHandler? = nil) async throws -> PDFToImagesResult {
        try await LoggedOperation.run(category, "to_images", ["input": input.logValue, "format": .string(format.rawValue),
                                                              "dpi": .number(Double(dpi))]) {
            guard (36...1200).contains(dpi) else { throw IPCError.invalidParams("DPI must be between 36 and 1200") }
            let doc = try open(input)
            let pages = try (selection ?? .all).pages(pageCount: doc.pageCount)
            let folderExisted = output.map { ResultFiles.exists($0) } ?? false
            let folder = try ResultFiles.folder(explicit: output, source: input, tag: "pages")
            let digits = String(doc.pageCount).count
            let base = SiblingFile.base(of: input)
            var files: [String] = []
            do {
                for (i, n) in pages.enumerated() {
                    try Task.checkCancellation()
                    guard let page = doc.page(at: n - 1) else { continue }
                    let image = try render(page, dpi: dpi, opaque: true)
                    let number = String(repeating: "0", count: max(0, digits - String(n).count)) + String(n)
                    let url = SiblingFile.unique(in: folder, base: "\(base) page \(number)", tag: nil, ext: format.fileExtension,
                                                 exists: ResultFiles.exists)
                    try ImageLoading.write(image, to: url, type: format.typeIdentifier, dpi: dpi)
                    files.append(url.path)
                    progress?(Double(i + 1) / Double(pages.count))
                }
            } catch {
                // Don't leave half-done work behind when cancelled or failed; never touch other files
                // in a folder that was already there.
                if folderExisted {
                    files.forEach { try? FileManager.default.removeItem(atPath: $0) }
                } else {
                    try? FileManager.default.removeItem(at: folder)
                }
                throw error
            }
            return PDFToImagesResult(input: input.path, folder: folder.path, files: files, format: format.rawValue, dpi: dpi)
        } outcome: { ["folder": .string($0.folder), "files": .number(Double($0.files.count))] }
    }

    /// Renders a page (with its rotation) at `dpi`.
    static func render(_ page: PDFPage, dpi: Int, opaque: Bool) throws -> CGImage {
        guard let ref = page.pageRef else { throw IPCError.failed("Couldn't read a page") }
        let box = ref.getBoxRect(.cropBox)
        let quarterTurns = ((ref.rotationAngle % 360 + 360) % 360) / 90
        let size = quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
        let scale = CGFloat(dpi) / 72
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, width * height <= 150_000_000 else {
            throw IPCError.invalidParams("Page \(page.label ?? "") would be \(width)×\(height) pixels at \(dpi) dpi. Use a lower --dpi.")
        }
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue) else {
            throw IPCError.failed("Not enough memory to render at \(dpi) dpi")
        }
        if opaque {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        // At scale 1 the drawing transform only rotates and positions; the context does the scaling.
        ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: box)
        ctx.drawPDFPage(ref)
        guard let image = ctx.makeImage() else { throw IPCError.failed("Couldn't render a page") }
        return image
    }

    // MARK: Info

    public static func info(_ input: URL) throws -> PDFInfo {
        try ResultFiles.requireFile(input)
        guard let doc = PDFDocument(url: input) else {
            throw IPCError("unreadable", "\(input.lastPathComponent) isn't a readable PDF")
        }
        let attrs = doc.documentAttributes ?? [:]
        var info = PDFInfo(path: input.path, bytes: ResultFiles.size(input), pages: doc.pageCount, pageSize: nil, uniformPageSize: true,
                           version: "\(doc.majorVersion).\(doc.minorVersion)", encrypted: doc.isEncrypted, locked: doc.isLocked,
                           textPages: 0, hasTextLayer: false,
                           title: attrs[PDFDocumentAttribute.titleAttribute] as? String,
                           author: attrs[PDFDocumentAttribute.authorAttribute] as? String,
                           creator: attrs[PDFDocumentAttribute.creatorAttribute] as? String,
                           producer: attrs[PDFDocumentAttribute.producerAttribute] as? String)
        guard !doc.isLocked else { return info }
        var sizes: [PDFInfo.Size] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            sizes.append(displaySize(page))
        }
        info.pageSize = sizes.first
        info.uniformPageSize = Set(sizes.map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }).count <= 1
        info.textPages = textPageCount(doc)
        info.hasTextLayer = info.textPages > 0
        return info
    }

    static func displaySize(_ page: PDFPage) -> PDFInfo.Size {
        let b = page.bounds(for: .cropBox)
        let turned = (page.rotation / 90) % 2 != 0
        return PDFInfo.Size(width: Double(turned ? b.height : b.width).rounded(toPlaces: 2),
                            height: Double(turned ? b.width : b.height).rounded(toPlaces: 2))
    }

    static func textPageCount(_ doc: PDFDocument) -> Int {
        (0..<doc.pageCount).reduce(0) { count, i in
            let text = doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return count + (text.isEmpty ? 0 : 1)
        }
    }

    // MARK: OCR

    /// Adds an invisible, selectable text layer to pages that have none (Vision OCR through PDFKit).
    public static func makeSearchable(_ input: URL, output: URL? = nil, progress: ProgressHandler? = nil) async throws -> PDFOCRResult {
        try await LoggedOperation.run(category, "ocr", ["input": input.logValue]) {
            let doc = try open(input)
            let before = textPageCount(doc)
            let destination = try ResultFiles.destination(explicit: output, source: input, tag: "searchable", ext: "pdf")
            progress?(0.05)
            let temp = ResultFiles.temporary(ext: "pdf")
            defer { try? FileManager.default.removeItem(at: temp) }
            guard doc.write(to: temp, withOptions: [.saveTextFromOCROption: true]) else {
                throw IPCError.failed("Couldn't write a searchable copy of \(input.lastPathComponent)")
            }
            try Task.checkCancellation()
            let after = PDFDocument(url: temp).map(textPageCount) ?? 0
            let final = try ResultFiles.place(temp, at: destination)
            progress?(1)
            return PDFOCRResult(input: input.path, output: final.path, pages: doc.pageCount, textPagesBefore: before,
                                textPagesAfter: after, bytes: ResultFiles.size(final))
        } outcome: { ["output": .string($0.output), "pages": .number(Double($0.pages)),
                      "textPagesBefore": .number(Double($0.textPagesBefore)), "textPagesAfter": .number(Double($0.textPagesAfter))] }
    }

    // MARK: Helpers

    /// Opens a PDF for editing. Throws a clear error for missing, unreadable and password-protected files.
    public static func open(_ url: URL) throws -> PDFDocument {
        try ResultFiles.requireFile(url)
        guard let doc = PDFDocument(url: url) else {
            throw IPCError("unreadable", "\(url.lastPathComponent) isn't a readable PDF")
        }
        if doc.isLocked {
            throw IPCError("encrypted", "\(url.lastPathComponent) is password-protected. Open it in Preview, enter the password, and export an unlocked copy first.")
        }
        guard doc.pageCount > 0 else { throw IPCError("unreadable", "\(url.lastPathComponent) has no pages") }
        return doc
    }

    private static func write(_ doc: PDFDocument, to destination: URL) throws -> URL {
        let temp = ResultFiles.temporary(ext: "pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard doc.write(to: temp) else { throw IPCError.failed("Couldn't write \(destination.lastPathComponent)") }
        return try ResultFiles.place(temp, at: destination)
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let f = pow(10, Double(places))
        return (self * f).rounded() / f
    }
}
