import AppKit
import ArgumentParser
import Foundation
import LodestoneCore
import LodestoneKit

/// `lodestone ocr`: image files are read in-process; `--screen` asks the app, which has the Screen
/// Recording permission.
struct OCRCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ocr",
        abstract: "Read text, QR codes and barcodes from images or the screen.",
        discussion: """
        Files are read in this process (PNG, JPEG, HEIC, TIFF, GIF, WebP). --screen runs in the app:
        without --region you drag out a region (Esc cancels); with --region the capture is immediate.
        --json adds each line's confidence and bounding box (pixels, origin top-left) and the codes.
          lodestone ocr receipt.jpg --languages en,de
          lodestone ocr --screen --region 0,0,800,600 --json
        """)

    @Argument(help: "Image files.") var files: [String] = []
    @Flag(help: "Capture the screen instead of reading files.") var screen = false
    @Option(help: "With --screen: x,y,width,height in points, origin top-left of the main display.") var region: String?
    @Option(help: "Recognition languages, comma-separated (en, de, zh-Hant...). Default: automatic (--screen: the app's setting).")
    var languages: String?
    @Flag(help: "Faster, less accurate recognition (Latin scripts only).") var fast = false
    @Flag(help: "Copy the result (text or code payload) to the clipboard.") var copy = false
    @Flag(help: "List the languages Vision can recognize.") var listLanguages = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if listLanguages { return }
        if screen && !files.isEmpty { throw ValidationError("Pass image files or --screen, not both.") }
        if !screen && files.isEmpty { throw ValidationError("Pass one or more image files, or --screen.") }
        if region != nil && !screen { throw ValidationError("--region needs --screen.") }
    }

    func run() throws {
        if listLanguages {
            let list = JSONValue.array(TextRecognizer.supportedLanguages(accurate: !fast).map { .string($0) })
            return Output.emit(list, json: global.json) { l in (l.array ?? []).map { Output.plain($0) }.joined(separator: "\n") }
        }
        if screen { return try runScreen() }

        let requested = languages.map(OCRLanguages.parse) ?? []
        let resolved = TextRecognizer.resolveLanguages(requested, accurate: !fast)
        if !resolved.unsupported.isEmpty {
            throw IPCError.invalidParams("Vision can't read \(resolved.unsupported.joined(separator: ", ")). Supported: \(TextRecognizer.supportedLanguages(accurate: !fast).joined(separator: ", "))")
        }
        let options = TextRecognizer.Options(languages: resolved.languages, accurate: !fast)
        var results: [(path: String, result: OCRResult)] = []
        for path in files {
            let url = fileURL(path)
            do {
                let result = try TextRecognizer.recognize(fileAt: url, options: options)
                Log.shared.info("screen", "ocr", ["path": .string(url.path), "chars": .number(Double(result.text.count)),
                                                     "codes": .number(Double(result.codes.count)), "ms": .number(result.ms)])
                results.append((url.path, result))
            } catch {
                Log.shared.warn("screen", "ocr.failed", ["path": .string(url.path), "error": .string(String(describing: error))])
                throw error
            }
        }
        if copy, let clip = results.compactMap({ OCRClipboard($0.result, preference: .code) }).map(\.text).nilIfEmpty {
            PasteboardIO.setText(clip.joined(separator: "\n\n"))
        }

        if global.json {
            let array = try results.map { item -> JSONValue in
                guard case .object(var o) = try JSONValue(encoding: item.result) else { return .null }
                o["path"] = .string(item.path)
                return .object(o)
            }
            print(JSONValue.array(array).prettyJSONString)
            return
        }
        for (i, item) in results.enumerated() {
            if results.count > 1 { print((i > 0 ? "\n" : "") + "==> \(item.path) <==") }
            print(Self.human(item.result))
        }
    }

    private func runScreen() throws {
        var params: [String: JSONValue] = ["copy": .bool(copy)]
        if let region {
            let parts = region.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4 else { throw IPCError.invalidParams("--region expects x,y,width,height") }
            params["region"] = ["x": .number(parts[0]), "y": .number(parts[1]), "width": .number(parts[2]), "height": .number(parts[3])]
        }
        if let languages { params["languages"] = .array(OCRLanguages.parse(languages).map { .string($0) }) }
        if fast { params["fast"] = .bool(true) }
        let result = try AppConnection.call("screen.ocr", .object(params))
        Output.emit(result, json: global.json) { r in
            (try? r.decode(OCRResult.self)).map(Self.human) ?? ""
        }
    }

    /// The text, then one line per code. Says so on stderr when nothing was found.
    static func human(_ result: OCRResult) -> String {
        if result.isEmpty {
            FileHandle.standardError.write(Data("No text or codes found.\n".utf8))
            return ""
        }
        var parts: [String] = []
        if !result.text.isEmpty { parts.append(result.text) }
        if !result.codes.isEmpty { parts.append(result.codes.map { "[\($0.symbology)] \($0.payload)" }.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
