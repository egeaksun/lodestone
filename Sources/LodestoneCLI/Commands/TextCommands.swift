import AppKit
import ArgumentParser
import Foundation
import LodestoneCore
import LodestoneKit

/// `lodestone text <transform> [text]`: runs in-process, so it works without the app.
struct TextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "text",
        abstract: "Transform text: JSON, Base64, URL, HTML, JWT, timestamps, case, lines, hashes.",
        discussion: """
        Reads the text argument, or stdin when there is none, and prints the result. With --clipboard
        it reads the clipboard and writes the result back (like Transform Clipboard in the menu).
        `lodestone text list` lists every transform; each is also the command `text.<id>` for shortcuts.

        Transforms: \(TextTransform.allCases.map(\.name).joined(separator: ", "))

        Examples:
          echo '{"b":1,"a":2}' | lodestone text json-pretty-sorted
          lodestone text timestamp 1700000000
          lodestone text jwt-decode --clipboard
        """)

    @Argument(help: "A transform name (see `lodestone text list`), or `list`.") var transform: String
    @Argument(help: "The text. Omit it to read stdin.") var text: String?
    @Flag(help: "Read the clipboard and replace it with the result.") var clipboard = false
    @OptionGroup var global: GlobalOptions

    func run() throws {
        if transform == "list" { return list() }
        guard let t = TextTransform(name: transform) else {
            throw IPCError.invalidParams("Unknown transform '\(transform)'. Run `lodestone text list`.")
        }
        if clipboard && text != nil { throw IPCError.invalidParams("Pass text or --clipboard, not both.") }

        let source: String
        let input: String
        if !t.takesInput {
            source = "none"
            input = ""
        } else if let text {
            source = "argument"
            input = text
        } else if clipboard {
            source = "clipboard"
            guard let s = NSPasteboard.general.string(forType: .string) else {
                throw IPCError("invalid_input", "The clipboard has no text.")
            }
            input = s
        } else {
            source = "stdin"
            guard isatty(STDIN_FILENO) == 0 else {
                throw IPCError.invalidParams("Pass the text as an argument, pipe it in, or use --clipboard.")
            }
            input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }

        let start = Date()
        let output: String
        do {
            output = try t.apply(input)
        } catch let error as TextTransformError {
            Log.shared.warn("text", "transform.failed", ["name": .string(t.rawValue), "source": .string(source), "error": .string(error.summary)])
            throw error.ipcError
        }
        let writesClipboard = clipboard && t.replacesText
        if writesClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
        }
        Log.shared.info("text", "transform", ["name": .string(t.rawValue), "source": .string(source), "chars": .number(Double(input.count)),
                                              "ms": .number((Date().timeIntervalSince(start) * 1000).rounded())])

        if global.json {
            var result: [String: JSONValue] = ["transform": .string(t.name), "clipboard": .bool(writesClipboard)]
            if t == .count {
                let counts = TextCounts(input)
                result["characters"] = .number(Double(counts.characters))
                result["words"] = .number(Double(counts.words))
                result["lines"] = .number(Double(counts.lines))
            } else {
                result["output"] = .string(output)
            }
            print(JSONValue.object(result).prettyJSONString)
        } else {
            print(output, terminator: output.hasSuffix("\n") ? "" : "\n")
        }
    }

    private func list() {
        let rows: [JSONValue] = TextTransform.groups.flatMap { group in
            group.transforms.map { t -> JSONValue in
                ["name": .string(t.name), "title": .string(t.title), "group": .string(group.title), "command": .string(t.commandID)]
            }
        }
        Output.emit(.array(rows), json: global.json) { l in
            Output.table(["NAME", "GROUP", "TITLE"], (l.array ?? []).map {
                [Output.plain($0["name"]), Output.plain($0["group"]), Output.plain($0["title"])]
            })
        }
    }
}
