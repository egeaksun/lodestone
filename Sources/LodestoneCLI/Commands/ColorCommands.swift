import ArgumentParser
import Foundation
import LodestoneCore
import LodestoneKit

struct ColorGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "color",
        abstract: "Pick colors from the screen and convert between color formats.",
        discussion: "Formats: \(ColorFormat.allCases.map(\.rawValue).joined(separator: ", ")).",
        subcommands: [Pick.self, Convert.self, History.self])

    static func parseFormat(_ name: String?) throws -> ColorFormat? {
        guard let name else { return nil }
        guard let format = ColorFormat(name: name) else {
            throw IPCError.invalidParams("Unknown format '\(name)'. Use one of: \(ColorFormat.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return format
    }

    /// Every format as aligned rows, or just the requested one.
    static func describe(_ color: JSONValue) -> String {
        if let value = color["value"]?.string { return value }
        return Output.table(["FORMAT", "VALUE"], ColorFormat.allCases.map { [$0.rawValue, Output.plain(color[$0.rawValue])] })
    }

    struct Pick: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Pick a color from the screen with the magnifier (waits for your click; Esc cancels).",
            discussion: "Runs in the app. The color is added to Recent Colors; --copy also copies it like the shortcut does.")
        @Option(help: "Print only this format.") var format: String?
        @Flag(help: "Copy the color to the clipboard (in --format, or the format set in Settings).") var copy = false
        @OptionGroup var global: GlobalOptions

        func run() throws {
            var params: [String: JSONValue] = ["copy": .bool(copy)]
            if let format = try ColorGroup.parseFormat(format) { params["format"] = .string(format.rawValue) }
            let color = try AppConnection.call("color.pick", .object(params))
            Output.emit(color, json: global.json) { ColorGroup.describe($0) }
        }
    }

    struct Convert: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Convert a color to other formats.",
            discussion: """
            Reads hex (#ff8800, #f80, #ff880080), rgb()/rgba(), hsl()/hsla(), and Color(red:green:blue:),
            NSColor(...) or UIColor(...). Runs in-process.
              lodestone color convert '#ff8800' --to swiftui
              lodestone color convert 'hsl(32, 100%, 50%)'
            """)
        @Argument(help: "The color.") var color: String
        @Option(name: .customLong("to"), help: "Print only this format.") var format: String?
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let format = try ColorGroup.parseFormat(format)
            let value: ColorValue
            do {
                value = try ColorValue.parse(color)
            } catch let error as TextTransformError {
                throw error.ipcError
            }
            Log.shared.info("color", "convert", ["format": .string(format?.rawValue ?? "all")])
            Output.emit(value.report(format: format), json: global.json) { ColorGroup.describe($0) }
        }
    }

    struct History: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List recently picked colors, newest first.")
        @Option(help: "Print only this format.") var format: String?
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let format = try ColorGroup.parseFormat(format) ?? .hex
            let list = try AppConnection.call("color.history")
            Output.emit(list, json: global.json) { l in
                (l.array ?? []).map { Output.plain($0[format.rawValue]) }.joined(separator: "\n")
            }
        }
    }
}
