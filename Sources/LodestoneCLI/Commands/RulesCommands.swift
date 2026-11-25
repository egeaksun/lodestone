import ArgumentParser
import Foundation
import LodestoneCore
import LodestoneKit

struct RulesGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules",
        abstract: "Folder rules: convert new files in a folder automatically.",
        discussion: """
        The app watches each enabled rule's folder and converts new matching files once they've finished \
        being written, with the converter's formats and presets. Rules are named by id or a unique id prefix.

        Example: lodestone rules add ~/Desktop --kinds video --to mp4 --preset balanced --match 'Screen Recording*'
        """,
        subcommands: [List.self, Add.self, Edit.self, Enable.self, Disable.self, Remove.self, Run.self, Status.self])

    static func describe(_ rule: JSONValue) -> String {
        let state = rule["enabled"]?.bool == true ? (rule["watching"]?.bool == true ? "on" : "on (not watching)") : "off"
        return "\(Output.plain(rule["id"]))  \(Output.plain(rule["name"]))  [\(state)]\n    \(Output.plain(rule["folder"])): \(Output.plain(rule["summary"]))"
            + (rule["pattern"].map { "\n    names matching \(Output.plain($0))" } ?? "")
            + (rule["folderExists"]?.bool == false ? "\n    the folder doesn't exist" : "")
    }

    /// The rule fields shared by `add` and `edit`.
    struct Fields: ParsableArguments {
        @Option(help: "Kinds of files to convert, comma-separated: image, video, audio.") var kinds: String?
        @Option(help: "Target format (see `lodestone convert formats`), or `same` to keep the format.") var to: String?
        @Option(help: "Preset id (see `lodestone presets list`), or `default`.") var preset: String?
        @Option(help: "Only file names matching this pattern (* and ?), e.g. 'Screen Recording*'. `''` for any.") var match: String?
        @Option(help: "Write results into this folder instead of next to the original. `''` for next to it.") var outputDir: String?
        @Option(help: "A name for the rule.") var name: String?
        @Flag(inversion: .prefixedNo, help: "Also convert files in subfolders.") var subfolders: Bool?
        @Flag(inversion: .prefixedNo, help: "Move originals to the Trash after converting.") var trashOriginals: Bool?

        func params() -> [String: JSONValue] {
            var p: [String: JSONValue] = [:]
            if let kinds { p["kinds"] = .array(kinds.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) }) }
            if let to { p["format"] = .string(to) }
            if let preset { p["preset"] = .string(preset == "default" ? "" : preset) }
            if let match { p["pattern"] = .string(match) }
            if let outputDir { p["outputFolder"] = .string(outputDir.isEmpty ? "" : fileURL(outputDir).path) }
            if let name { p["name"] = .string(name) }
            if let subfolders { p["includeSubfolders"] = .bool(subfolders) }
            if let trashOriginals { p["originals"] = .string(trashOriginals ? "trash" : "keep") }
            return p
        }
    }

    struct RuleArgument: ParsableArguments {
        @Argument(help: "Rule id or unique id prefix.") var id: String
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List folder rules.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let rules = try AppConnection.call("rules.list")
            Output.emit(rules, json: global.json) { r in
                let rows = r.array ?? []
                return rows.isEmpty ? "No folder rules. Add one with `lodestone rules add <folder> --kinds video --to mp4`."
                    : rows.map(RulesGroup.describe).joined(separator: "\n")
            }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a folder rule.")
        @Argument(help: "The folder to watch.") var folder: String
        @OptionGroup var fields: Fields
        @Flag(help: "Add it turned off.") var disabled = false
        @OptionGroup var global: GlobalOptions

        func validate() throws {
            guard fields.kinds != nil else { throw ValidationError("Give --kinds (image, video, audio).") }
        }

        func run() throws {
            var p = fields.params()
            p["folder"] = .string(fileURL(folder).path)
            if disabled { p["enabled"] = false }
            let rule = try AppConnection.call("rules.add", .object(p))
            Output.emit(rule, json: global.json) { "Added " + RulesGroup.describe($0) }
        }
    }

    struct Edit: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change a folder rule. Options not given stay as they are.")
        @OptionGroup var rule: RuleArgument
        @Option(help: "Watch this folder instead.") var folder: String?
        @OptionGroup var fields: Fields
        @OptionGroup var global: GlobalOptions

        func run() throws {
            var p = fields.params()
            p["id"] = .string(rule.id)
            if let folder { p["folder"] = .string(fileURL(folder).path) }
            let updated = try AppConnection.call("rules.update", .object(p))
            Output.emit(updated, json: global.json) { "Updated " + RulesGroup.describe($0) }
        }
    }

    struct Enable: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn a folder rule on.")
        @OptionGroup var rule: RuleArgument
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let updated = try AppConnection.call("rules.update", ["id": .string(rule.id), "enabled": true])
            Output.emit(updated, json: global.json) { "Enabled " + RulesGroup.describe($0) }
        }
    }

    struct Disable: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn a folder rule off.")
        @OptionGroup var rule: RuleArgument
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let updated = try AppConnection.call("rules.update", ["id": .string(rule.id), "enabled": false])
            Output.emit(updated, json: global.json) { "Disabled " + RulesGroup.describe($0) }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a folder rule.")
        @OptionGroup var rule: RuleArgument
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let removed = try AppConnection.call("rules.remove", ["id": .string(rule.id)])
            Output.emit(removed, json: global.json) { "Removed \(Output.plain($0["id"]))  \(Output.plain($0["name"]))" }
        }
    }

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Convert the matching files already in a rule's folder.",
            discussion: "The watcher only sees new files. Use --dry-run to list what would be converted, and why other files are skipped.")
        @OptionGroup var rule: RuleArgument
        @Flag(help: "Only list the files.") var dryRun = false
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let result = try AppConnection.call("rules.run", ["id": .string(rule.id), "dryRun": .bool(dryRun)])
            Output.emit(result, json: global.json) { r in
                let convert = (r["convert"]?.array ?? []).map(Output.plain)
                var lines = [convert.isEmpty ? "Nothing to convert."
                             : (dryRun ? "Would convert \(convert.count):" : "Converting \(convert.count) in the app (see `lodestone logs --category rules`):")]
                lines += convert.map { "  " + $0 }
                if dryRun, let skipped = r["skipped"]?.array, !skipped.isEmpty {
                    lines.append("Skipped \(skipped.count):")
                    lines += skipped.map { "  \(Output.plain($0["path"]))  (\(Output.plain($0["reason"]).replacingOccurrences(of: "_", with: " ")))" }
                }
                return lines.joined(separator: "\n")
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Whether rules are on, which folders are watched, and files waiting.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let status = try AppConnection.call("rules.status")
            Output.emit(status, json: global.json) { s in
                let folders = (s["watching"]?.array ?? []).map(Output.plain)
                return (s["enabled"]?.bool == true ? "Folder rules are on" : "Folder rules are paused")
                    + ", \(Output.plain(s["rules"])) rule(s).\n"
                    + (folders.isEmpty ? "Not watching any folder." : "Watching:\n" + folders.map { "  " + $0 }.joined(separator: "\n"))
                    + "\nSettling: \(Output.plain(s["settling"])), converting or queued: \(Output.plain(s["queued"]))"
            }
        }
    }
}
