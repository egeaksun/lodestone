import ArgumentParser
import Foundation
import LodestoneKit

@main
struct LodestoneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lodestone",
        abstract: "Control Lodestone from the command line: windows, conversions, clipboard, screen text and more.",
        discussion: """
        Every command accepts --json for machine-readable output. Commands that need the running app
        (windows, clipboard history, screen capture, settings) start it in the background if needed.
        Discover everything with `lodestone methods` (raw IPC methods) and `lodestone commands`
        (shortcut-able actions). Activity is logged for 7 days: `lodestone logs`.
        """,
        version: "0.2.0",
        subcommands: [
            Status.self,
            WindowGroup.self,
            ClipboardGroup.self,
            CommandsGroup.self,
            Run.self,
            ShortcutsGroup.self,
            SettingsGroup.self,
            FilesGroup.self,
            TextCommand.self,
            OCRCommand.self,
            ColorGroup.self,
            PDFGroup.self,
            ImageGroup.self,
            Logs.self,
            Methods.self,
            Call.self,
        ]
    )

    static func main() async {
        Log.shared.process = "cli"
        // Log which command ran, not its arguments (they can contain clipboard text or file contents).
        let words = CommandLine.arguments.dropFirst().prefix { !$0.hasPrefix("-") }.prefix(2)
        if !words.isEmpty { Log.shared.info("cli", "run", ["command": .string(words.joined(separator: " "))]) }
        do {
            var command = try parseAsRoot()
            if var async = command as? AsyncParsableCommand {
                try await async.run()
            } else {
                try command.run()
            }
            Log.shared.flush()
        } catch {
            Log.shared.flush()
            exit(withError: error)
        }
    }
}
