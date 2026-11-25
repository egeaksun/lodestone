import ArgumentParser
import Foundation
import LodestoneCore
import LodestoneKit

extension PDFCompressionLevel: ExpressibleByArgument {}
extension PDFCompressionEngine: ExpressibleByArgument {}
extension PDFPageSize: ExpressibleByArgument {}
extension PDFImageFormat: ExpressibleByArgument {}

/// `lodestone pdf ...`: runs in this process through LodestoneKit, so it works without the app.
struct PDFGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "Merge, compress, split, rotate, render and OCR PDFs; turn images into a PDF.",
        discussion: """
        Runs without the app. Results go next to the first input as "<name> (merged).pdf", \
        "<name> (compressed).pdf" and so on, unless -o is given; existing files are never overwritten.

        Page selections look like 1-3,5,8- (8- runs to the end, "last" is the last page).
        """,
        subcommands: [Merge.self, Compress.self, FromImages.self, Extract.self, Split.self, Rotate.self,
                      ToImages.self, Info.self, OCR.self])

    static func pages(_ text: String?) throws -> PageRanges? {
        try text.map(PageRanges.parse)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func describe(_ files: [PDFPagesFile]) -> String {
        files.map { "\($0.path)  (\($0.pages.count) page\($0.pages.count == 1 ? "" : "s"), \(PDFTools.formatBytes($0.bytes)))" }
            .joined(separator: "\n")
    }

    struct Merge: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Combine PDFs into one, in the given order.")
        @Argument(help: "PDFs to merge (two or more).") var inputs: [String]
        @Option(name: .shortAndLong, help: "Output file. Default: \"<first name> (merged).pdf\" next to the first input.") var output: String?
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let result = try await PDFTools.merge(inputs.map(fileURL), output: output.map(fileURL))
            try Output.emit(result, json: global.json) { "\($0.output)  (\($0.pages) pages, \(PDFTools.formatBytes($0.bytes)))" }
        }
    }

    struct Compress: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Make PDFs smaller by re-compressing their images. Text stays selectable.",
            discussion: "Uses Ghostscript when it's installed (brew install ghostscript), PDFKit otherwise. When the result isn't smaller, nothing is written and the original is kept.")
        @Argument(help: "PDFs to compress.") var inputs: [String]
        @Option(help: "light, balanced or strong.") var level: PDFCompressionLevel = .balanced
        @Option(help: "auto (Ghostscript if installed), gs or pdfkit.") var engine: PDFCompressionEngine = .auto
        @Option(name: .shortAndLong, help: "Output file (one input only) or folder.") var output: String?
        @OptionGroup var global: GlobalOptions

        func validate() throws {
            if inputs.isEmpty { throw ValidationError("Give at least one PDF") }
            if inputs.count > 1, let output, !PDFGroup.isDirectory(fileURL(output)) {
                throw ValidationError("With several inputs, -o must be an existing folder")
            }
        }

        func run() async throws {
            var results: [PDFCompressResult] = []
            for input in inputs {
                results.append(try await PDFTools.compress(fileURL(input), output: output.map(fileURL), level: level, engine: engine))
            }
            if global.json {
                print(try JSONValue(encoding: inputs.count == 1 ? try JSONValue(encoding: results[0]) : try JSONValue(encoding: results)).prettyJSONString)
            } else {
                for r in results {
                    print(r.keptOriginal ? r.message : "\(r.output ?? "")  \(r.message), \(r.engine) \(r.level)")
                }
            }
        }
    }

    struct FromImages: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "from-images", abstract: "Make a PDF with one page per image, in the given order.")
        @Argument(help: "Images (anything macOS can read: JPEG, PNG, HEIC, TIFF, ...).") var images: [String]
        @Option(help: "fit (page = image size), a4 or letter. Fixed sizes turn landscape for landscape images.") var pageSize: PDFPageSize = .fit
        @Option(help: "Margin around each image, in points (72 = 1 inch).") var margin: Double = 0
        @Option(name: .shortAndLong, help: "Output file. Default: next to the first image.") var output: String?
        @OptionGroup var global: GlobalOptions

        func validate() throws {
            if images.isEmpty { throw ValidationError("Give at least one image") }
        }

        func run() async throws {
            let result = try await PDFTools.fromImages(images.map(fileURL), output: output.map(fileURL), pageSize: pageSize, margin: margin)
            try Output.emit(result, json: global.json) { "\($0.output)  (\($0.pages) page\($0.pages == 1 ? "" : "s"), \(PDFTools.formatBytes($0.bytes)))" }
        }
    }

    struct Extract: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Copy selected pages into a new PDF.")
        @Argument(help: "The PDF.") var input: String
        @Option(help: "Pages, for example 1-3,5,8-.") var pages: String
        @Option(name: .shortAndLong, help: "Output file. Default: \"<name> (pages 1-3).pdf\" next to the input.") var output: String?
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let result = try await PDFTools.extract(fileURL(input), pages: try PageRanges.parse(pages), mode: .combined, output: output.map(fileURL))
            try Output.emit(result, json: global.json) { PDFGroup.describe($0.outputs) }
        }
    }

    struct Split: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Split a PDF into several files.",
            discussion: "Without --pages, every page becomes its own file. With --pages, each comma-separated item becomes a file (1-3,4-6 makes two); add --each-page to split the selected pages one per file.")
        @Argument(help: "The PDF.") var input: String
        @Option(help: "Pages, for example 1-3,4-6,7-.") var pages: String?
        @Flag(help: "One file per selected page.") var eachPage = false
        @Option(name: .shortAndLong, help: "Folder for the files (created if needed). Default: next to the input.") var output: String?
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let mode: PDFExtractMode = pages == nil || eachPage ? .perPage : .perRange
            let result = try await PDFTools.extract(fileURL(input), pages: try PDFGroup.pages(pages) ?? .all, mode: mode, output: output.map(fileURL))
            try Output.emit(result, json: global.json) { PDFGroup.describe($0.outputs) }
        }
    }

    struct Rotate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rotate pages clockwise.")
        @Argument(help: "The PDF.") var input: String
        @Option(help: "Degrees clockwise: 90, 180, 270 or -90.") var angle: Int = 90
        @Option(help: "Pages to rotate, for example 1-3,5. Default: all.") var pages: String?
        @Option(name: .shortAndLong, help: "Output file. Default: \"<name> (rotated).pdf\" next to the input.") var output: String?
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let result = try await PDFTools.rotate(fileURL(input), angle: angle, pages: try PDFGroup.pages(pages), output: output.map(fileURL))
            try Output.emit(result, json: global.json) { "\($0.output)  (\($0.pages.count) page\($0.pages.count == 1 ? "" : "s") rotated \($0.angle)°)" }
        }
    }

    struct ToImages: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "to-images", abstract: "Render pages as PNG or JPEG images.")
        @Argument(help: "The PDF.") var input: String
        @Option(help: "png or jpeg.") var format: PDFImageFormat = .png
        @Option(help: "Resolution in dots per inch (36-1200).") var dpi: Int = 150
        @Option(help: "Pages, for example 1-3,5. Default: all.") var pages: String?
        @Option(name: .shortAndLong, help: "Folder for the images (created if needed). Default: \"<name> (pages)\" next to the input.") var output: String?
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let result = try await PDFTools.toImages(fileURL(input), format: format, dpi: dpi, pages: try PDFGroup.pages(pages), output: output.map(fileURL))
            try Output.emit(result, json: global.json) { "\($0.folder)  (\($0.files.count) \($0.format) image\($0.files.count == 1 ? "" : "s") at \($0.dpi) dpi)" }
        }
    }

    struct Info: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Page count, page size, encryption and whether the PDF has selectable text.")
        @Argument(help: "PDFs.") var inputs: [String]
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let infos = try inputs.map { try PDFTools.info(fileURL($0)) }
            if global.json {
                print((inputs.count == 1 ? try JSONValue(encoding: infos[0]) : try JSONValue(encoding: infos)).prettyJSONString)
                return
            }
            print(infos.map { i in
                var lines = [i.path]
                func add(_ label: String, _ value: String?) {
                    if let value, !value.isEmpty { lines.append("  " + label.padding(toLength: 10, withPad: " ", startingAt: 0) + value) }
                }
                add("Pages", String(i.pages))
                if let s = i.pageSize {
                    add("Page size", "\(Output.plain(.number(s.width))) × \(Output.plain(.number(s.height))) pt\(Self.paperName(s).map { " (\($0))" } ?? "")\(i.uniformPageSize ? "" : ", varies")")
                }
                add("File size", PDFTools.formatBytes(i.bytes))
                add("Version", i.version)
                add("Encrypted", i.encrypted ? (i.locked ? "yes, needs a password to open" : "yes (no open password)") : "no")
                if !i.locked { add("Text", i.hasTextLayer ? "\(i.textPages) of \(i.pages) pages" : "none (scanned? try `lodestone pdf ocr`)") }
                add("Title", i.title)
                add("Author", i.author)
                add("Creator", i.creator)
                add("Producer", i.producer)
                return lines.joined(separator: "\n")
            }.joined(separator: "\n\n"))
        }

        static func paperName(_ s: PDFInfo.Size) -> String? {
            let (w, h) = (min(s.width, s.height), max(s.width, s.height))
            if abs(w - 595) < 2 && abs(h - 842) < 2 { return "A4" }
            if abs(w - 612) < 2 && abs(h - 792) < 2 { return "Letter" }
            if abs(w - 612) < 2 && abs(h - 1008) < 2 { return "Legal" }
            return nil
        }
    }

    struct OCR: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ocr",
            abstract: "Make a scanned PDF searchable: adds invisible, selectable text to pages that have none.")
        @Argument(help: "The PDF.") var input: String
        @Option(name: .shortAndLong, help: "Output file. Default: \"<name> (searchable).pdf\" next to the input.") var output: String?
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let result = try await PDFTools.makeSearchable(fileURL(input), output: output.map(fileURL))
            try Output.emit(result, json: global.json) { "\($0.output)  (text on \($0.textPagesAfter) of \($0.pages) pages, was \($0.textPagesBefore))" }
        }
    }
}
