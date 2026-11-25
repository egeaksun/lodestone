import AppKit
import ArgumentParser
import Foundation
import LodestoneCore
import LodestoneKit

struct ClipboardGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipboard",
        abstract: "Read and write the clipboard, and use clipboard history.",
        discussion: """
        `get` and `set` work on the clipboard directly and don't need the app. The other commands use the \
        history the app records. Items are named by id, a unique id prefix, or position (1 is the newest).
        """,
        subcommands: [Get.self, Set.self, History.self, Paste.self, Copy.self, Pin.self, Unpin.self, Delete.self,
                      Clear.self, Pause.self, Resume.self, Status.self])

    static func describe(_ item: JSONValue) -> String {
        var flags: [String] = []
        if item["pinned"]?.bool == true { flags.append("pinned") }
        return "\(Output.plain(item["position"])). \(Output.plain(item["id"])) \(Output.plain(item["kind"])): \(Output.plain(item["title"]))"
            + (flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]")
    }

    // MARK: In-process

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the clipboard as plain text.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let pb = NSPasteboard.general
            guard let text = PasteboardIO.plainText(pb) else {
                let types = PasteboardIO.types(pb)
                throw IPCError("no_text", types.isEmpty
                    ? "The clipboard is empty."
                    : "The clipboard has no text. It holds: \(types.prefix(5).joined(separator: ", ")).")
            }
            Log.shared.info("clipboard", "get", ["chars": .number(Double(text.count))])
            if global.json {
                print(JSONValue.object(["text": .string(text), "types": .array(PasteboardIO.types(pb).map { .string($0) })]).prettyJSONString)
            } else {
                print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
            }
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Put plain text on the clipboard.",
            discussion: "Give the text as an argument, with --file, or on stdin (`echo hi | lodestone clipboard set`).")
        @Argument(help: "The text. Omit to read --file or stdin.") var text: String?
        @Option(help: "Read the text from this file.") var file: String?
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let value: String
            if let text {
                guard file == nil else { throw ValidationError("Give the text or --file, not both.") }
                value = text
            } else if let file {
                let url = fileURL(file)
                guard let data = FileManager.default.contents(atPath: url.path) else {
                    throw IPCError.notFound("Can't read \(url.path).")
                }
                guard let s = String(data: data, encoding: .utf8) else {
                    throw IPCError.invalidParams("\(url.path) isn't UTF-8 text.")
                }
                value = s
            } else {
                guard isatty(STDIN_FILENO) == 0 else {
                    throw ValidationError("Give the text as an argument, with --file, or pipe it in.")
                }
                value = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            }
            PasteboardIO.setText(value)
            Log.shared.info("clipboard", "set", ["chars": .number(Double(value.count)), "source": .string(text != nil ? "argument" : file != nil ? "file" : "stdin")])
            if global.json {
                print(JSONValue.object(["ok": true, "chars": .number(Double(value.count))]).prettyJSONString)
            }
        }
    }

    // MARK: Through the app

    struct History: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List clipboard history, newest first.")
        @Option(help: "Show at most this many items.") var limit: Int?
        @Option(help: "Only items containing every word (case-insensitive).") var search: String?
        @OptionGroup var global: GlobalOptions

        func run() throws {
            var p: [String: JSONValue] = [:]
            if let limit { p["limit"] = .number(Double(limit)) }
            if let search { p["search"] = .string(search) }
            let list = try AppConnection.call("clipboard.history", .object(p))
            Output.emit(list, json: global.json) { l in
                let rows = l.array ?? []
                if rows.isEmpty { return search == nil ? "Clipboard history is empty." : "No matches." }
                return Output.table(["#", "ID", "KIND", "APP", "COPIED", "PIN", "CONTENT"], rows.map { i in
                    let date = i["date"]?.string.flatMap { ISO8601DateFormatter().date(from: $0) }
                    let title = Output.plain(i["title"])
                    return [Output.plain(i["position"]), Output.plain(i["id"]), Output.plain(i["kind"]), Output.plain(i["sourceApp"]),
                            date.map { RelativeTime.short(from: $0) } ?? "-", i["pinned"]?.bool == true ? "yes" : "",
                            title.count > 60 ? String(title.prefix(59)) + "…" : title]
                })
            }
        }
    }

    struct ItemArgument: ParsableArguments {
        @Argument(help: "Item id, unique id prefix, or position (1 = newest).") var id: String
    }

    struct Paste: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Paste a history item into the frontmost app.")
        @OptionGroup var item: ItemArgument
        @Flag(help: "Paste as plain text.") var plain = false
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let info = try AppConnection.call("clipboard.paste", ["id": .string(item.id), "plain": .bool(plain)])
            Output.emit(info, json: global.json) { "Pasted " + ClipboardGroup.describe($0) }
        }
    }

    struct Copy: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Put a history item on the clipboard.")
        @OptionGroup var item: ItemArgument
        @Flag(help: "Copy as plain text.") var plain = false
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let info = try AppConnection.call("clipboard.copy", ["id": .string(item.id), "plain": .bool(plain)])
            Output.emit(info, json: global.json) { "Copied " + ClipboardGroup.describe($0) }
        }
    }

    struct Pin: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pin a history item so it's never evicted.")
        @OptionGroup var item: ItemArgument
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let info = try AppConnection.call("clipboard.pin", ["id": .string(item.id), "pinned": true])
            Output.emit(info, json: global.json) { "Pinned " + ClipboardGroup.describe($0) }
        }
    }

    struct Unpin: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Unpin a history item.")
        @OptionGroup var item: ItemArgument
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let info = try AppConnection.call("clipboard.pin", ["id": .string(item.id), "pinned": false])
            Output.emit(info, json: global.json) { "Unpinned " + ClipboardGroup.describe($0) }
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a history item.")
        @OptionGroup var item: ItemArgument
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let info = try AppConnection.call("clipboard.delete", ["id": .string(item.id)])
            Output.emit(info, json: global.json) { "Deleted " + ClipboardGroup.describe($0) }
        }
    }

    struct Clear: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete clipboard history. Pinned items are kept unless --include-pinned.")
        @Flag(help: "Delete pinned items too.") var includePinned = false
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let result = try AppConnection.call("clipboard.clear", ["includePinned": .bool(includePinned)])
            Output.emit(result, json: global.json) { "Removed \(Output.plain($0["removed"])) items." }
        }
    }

    static func describeStatus(_ s: JSONValue) -> String {
        guard s["enabled"]?.bool == true else { return "Clipboard history is off." }
        var state = "on"
        if s["paused"]?.bool == true {
            if let until = s["pausedUntil"]?.string.flatMap({ ISO8601DateFormatter().date(from: $0) }) {
                state = "paused until " + DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short)
            } else {
                state = "paused"
            }
        }
        let bytes = RelativeTime.bytes(s["bytes"]?.int ?? 0)
        return "Clipboard history is \(state): \(Output.plain(s["items"])) items (\(Output.plain(s["pinned"])) pinned), \(bytes)"
            + (s["persistent"]?.bool == true ? ", kept across restarts." : ", in memory only.")
    }

    struct Pause: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop recording copies.")
        @Option(help: "Resume automatically after this many minutes.") var minutes: Double?
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let status = try AppConnection.call("clipboard.pause", ["minutes": minutes.map { .number($0) } ?? .null])
            Output.emit(status, json: global.json, human: ClipboardGroup.describeStatus)
        }
    }

    struct Resume: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Resume recording copies.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let status = try AppConnection.call("clipboard.resume")
            Output.emit(status, json: global.json, human: ClipboardGroup.describeStatus)
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show whether history is recording, and its size.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let status = try AppConnection.call("clipboard.status")
            Output.emit(status, json: global.json, human: ClipboardGroup.describeStatus)
        }
    }
}
