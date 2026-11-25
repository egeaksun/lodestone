import ArgumentParser
import Foundation
import LodestoneCore
import LodestoneKit

/// Reads the activity log files directly; works whether or not the app is running.
struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the activity log (kept for 7 days).",
        discussion: "Examples: lodestone logs --since 2h --level warn; lodestone logs --category convert --follow")

    @Option(help: "How far back: 30m, 2h, 3d (default 1d).") var since = "1d"
    @Option(help: "Minimum level: debug, info, warn, error.") var level = "info"
    @Option(help: "Only this category (window, convert, clipboard, ipc, cli, ...).") var category: String?
    @Option(help: "Only entries whose message or data contains this text.") var grep: String?
    @Option(help: "At most this many entries (the most recent).") var limit = 200
    @Flag(help: "Keep printing new entries as they arrive.") var follow = false
    @Flag(help: "Print the log directory and exit.") var path = false
    @OptionGroup var global: GlobalOptions

    func run() throws {
        if path {
            Swift.print(Paths.logs.path)
            return
        }
        guard let minLevel = LogEntry.Level(rawValue: level) else { throw ValidationError("--level must be debug, info, warn or error") }
        guard let window = Self.parseDuration(since) else { throw ValidationError("--since expects a duration like 30m, 2h or 3d") }
        let start = Date().addingTimeInterval(-window)

        func matches(_ e: LogEntry) -> Bool {
            guard e.level >= minLevel else { return false }
            if let category, e.cat != category { return false }
            if let grep {
                let haystack = e.msg + " " + (e.data.map { JSONValue.object($0).jsonString } ?? "")
                if !haystack.localizedCaseInsensitiveContains(grep) { return false }
            }
            return true
        }

        var entries = Log.read(since: start).filter(matches)
        if entries.count > limit { entries = Array(entries.suffix(limit)) }
        entries.forEach(print)

        guard follow else { return }
        var last = entries.last?.ts ?? Date()
        while true {
            Thread.sleep(forTimeInterval: 1)
            let fresh = Log.read(since: last).filter { $0.ts > last && matches($0) }
            fresh.forEach(print)
            if let t = fresh.last?.ts { last = t }
            fflush(stdout)
        }
    }

    private func print(_ e: LogEntry) {
        if global.json {
            Swift.print((try? JSONValue(encoding: e).jsonString) ?? "")
            return
        }
        let ts = Self.formatter.string(from: e.ts)
        let data = (e.data ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\(Output.plain($0.value))" }.joined(separator: " ")
        let lvl = e.level.rawValue.uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)
        let cat = e.cat.padding(toLength: 10, withPad: " ", startingAt: 0)
        Swift.print("\(ts) \(lvl) \(cat) \(e.msg)\(data.isEmpty ? "" : "  " + data)\(e.proc == "cli" ? "  [cli]" : "")")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func parseDuration(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let n = Double(text.dropLast()) else { return nil }
        switch unit {
        case "s": return n
        case "m": return n * 60
        case "h": return n * 3600
        case "d": return n * 86400
        default: return nil
        }
    }
}
