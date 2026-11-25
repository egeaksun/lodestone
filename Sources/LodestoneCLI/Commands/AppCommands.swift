import ArgumentParser
import Foundation
import LodestoneCore
import LodestoneKit

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show whether Lodestone is running, its permissions and file locations.")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        let status = try AppConnection.call("app.status")
        Output.emit(status, json: global.json) { s in
            var lines = [
                "Lodestone \(Output.plain(s["version"])) (pid \(Output.plain(s["pid"])))",
                "Accessibility:   \(s["accessibility"]?.bool == true ? "granted" : "NOT granted (window commands and pasting won't work)")",
                "Screen capture:  \(s["screenRecording"]?.bool == true ? "granted" : "not granted (asked for on first screen capture)")",
                "Launch at login: \(Output.plain(s["launchAtLogin"]))",
                "Features:        \((s["features"]?.array ?? []).map { Output.plain($0) }.joined(separator: ", "))",
                "Logs:            \(Output.plain(s["logs"])) (kept \(Output.plain(s["logRetentionDays"])) days)",
            ]
            for a in s["activities"]?.array ?? [] {
                lines.append("Running:         \(Output.plain(a["title"])) \(a["progress"]?.double.map { "\(Int($0 * 100))%" } ?? "")")
            }
            return lines.joined(separator: "\n")
        }
    }
}

struct Methods: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List every IPC method the app exposes (use with `lodestone call`).")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        let methods = try AppConnection.call("methods")
        Output.emit(methods, json: global.json) { m in
            Output.table(["METHOD", "PARAMS", "SUMMARY"], (m.array ?? []).map {
                [Output.plain($0["method"]), Output.plain($0["params"]), Output.plain($0["summary"])]
            })
        }
    }
}

struct Call: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Call any IPC method with JSON params and print the JSON result.",
        discussion: #"Example: lodestone call window.snap '{"action":"leftHalf","app":"Safari"}'"#)
    @Argument(help: "Method name, see `lodestone methods`.") var method: String
    @Argument(help: "Params as a JSON object.") var params: String?

    func run() throws {
        var value: JSONValue?
        if let params {
            do {
                value = try JSONDecoder().decode(JSONValue.self, from: Data(params.utf8))
            } catch {
                throw ValidationError("params must be valid JSON: \(error.localizedDescription)")
            }
        }
        print(try AppConnection.call(method, value).prettyJSONString)
    }
}

struct CommandsGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "commands",
        abstract: "List the commands that shortcuts and the menu can run (run one with `lodestone run <id>`).")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        let list = try AppConnection.call("commands.list")
        Output.emit(list, json: global.json) { l in
            Output.table(["ID", "SHORTCUT", "TITLE"], (l.array ?? []).map {
                [Output.plain($0["id"]), Output.plain($0["shortcut"]), Output.plain($0["title"])]
            })
        }
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a command as if its shortcut was pressed (see `lodestone commands`).")
    @Argument(help: "Command id, for example leftHalf or clipboard.history.") var id: String
    @OptionGroup var global: GlobalOptions

    func run() throws {
        let result = try AppConnection.call("commands.run", ["id": .string(id)])
        Output.emit(result, json: global.json) { _ in "" }
    }
}

struct ShortcutsGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "shortcuts", abstract: "List and change global shortcuts.",
                                                    subcommands: [List.self, Set.self, Reset.self], defaultSubcommand: List.self)

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List every command's shortcut.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let list = try AppConnection.call("shortcuts.list")
            Output.emit(list, json: global.json) { l in
                Output.table(["ID", "SHORTCUT", "DEFAULT", "TITLE"], (l.array ?? []).map {
                    let taken = $0["available"]?.bool == false ? " (taken by another app)" : ""
                    return [Output.plain($0["id"]), Output.plain($0["shortcut"]) + taken, Output.plain($0["default"]), Output.plain($0["title"])]
                })
            }
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set a command's shortcut, or remove it with `none`.",
                                                        discussion: "Examples: ctrl+opt+left, ctrl+opt+shift+v, cmd+f5, none")
        @Argument(help: "Command id (see `lodestone shortcuts`).") var id: String
        @Argument(help: "Shortcut like ctrl+opt+left, or none.") var shortcut: String
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let value: JSONValue = shortcut.lowercased() == "none" ? .null : .string(shortcut)
            let result = try AppConnection.call("shortcuts.set", ["id": .string(id), "shortcut": value])
            Output.emit(result, json: global.json) { r in
                var text = "\(id): \(Output.plain(r["shortcut"]))"
                if let from = r["takenFrom"]?.string { text += " (removed from \(from))" }
                if r["available"]?.bool == false { text += "\nwarning: another app already uses this shortcut" }
                return text
            }
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Reset every shortcut to its default.")
        func run() throws { _ = try AppConnection.call("shortcuts.reset") }
    }
}

struct SettingsGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "settings", abstract: "Read and change settings.",
                                                    subcommands: [List.self, Get.self, Set.self, Reset.self, Open.self], defaultSubcommand: List.self)

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List every setting with its value and type.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let list = try AppConnection.call("settings.list")
            Output.emit(list, json: global.json) { l in
                Output.table(["KEY", "VALUE", "TYPE", "TITLE"], (l.array ?? []).map {
                    [Output.plain($0["key"]), Output.plain($0["value"]), Output.plain($0["type"]), Output.plain($0["title"])]
                })
            }
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print one setting's value.")
        @Argument var key: String
        @OptionGroup var global: GlobalOptions

        func run() throws {
            Output.emit(try AppConnection.call("settings.get", ["key": .string(key)]), json: global.json) { Output.plain($0) }
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change a setting (values are validated).")
        @Argument var key: String
        @Argument var value: String
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let result = try AppConnection.call("settings.set", ["key": .string(key), "value": .string(value)])
            Output.emit(result, json: global.json) { "\(key) = \(Output.plain($0))" }
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Reset a setting to its default.")
        @Argument var key: String
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let result = try AppConnection.call("settings.reset", ["key": .string(key)])
            Output.emit(result, json: global.json) { "\(key) = \(Output.plain($0))" }
        }
    }

    struct Open: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open the Settings window.")
        @Argument(help: "Feature tab to show, for example snapping.") var tab: String?
        func run() throws { _ = try AppConnection.call("settings.open", ["id": tab.map { .string($0) } ?? .null]) }
    }
}

struct FilesGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "files",
        abstract: "File actions: what Lodestone offers for files dropped on its menu bar icon.",
        subcommands: [Actions.self, RunAction.self])

    struct Actions: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List actions available for these files.")
        @Argument(help: "Files.") var paths: [String]
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let list = try AppConnection.call("files.actions", ["paths": .array(paths.map { .string(fileURL($0).path) })])
            Output.emit(list, json: global.json) { l in
                Output.table(["ID", "TITLE"], (l.array ?? []).map { [Output.plain($0["id"]), Output.plain($0["title"])] })
            }
        }
    }

    struct RunAction: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "run", abstract: "Run a file action (opens its window in the app).")
        @Argument(help: "Action id from `lodestone files actions`.") var action: String
        @Argument(help: "Files.") var paths: [String]

        func run() throws {
            _ = try AppConnection.call("files.run", ["action": .string(action), "paths": .array(paths.map { .string(fileURL($0).path) })])
        }
    }
}
