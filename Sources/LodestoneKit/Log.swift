import Foundation
import LodestoneCore

/// One activity log entry. Stored as one JSON object per line.
public struct LogEntry: Codable, Sendable {
    public enum Level: String, Codable, Sendable, CaseIterable, Comparable {
        case debug, info, warn, error

        var rank: Int { Self.allCases.firstIndex(of: self)! }
        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    }

    public var ts: Date
    public var level: Level
    /// The feature or subsystem, for example "window", "convert", "clipboard", "ipc", "cli".
    public var cat: String
    /// What happened, short and stable ("snap", "convert.done", "hotkey.register_failed").
    public var msg: String
    /// Details for triage: inputs, outputs, durations, error text. Never clipboard or OCR contents.
    public var data: [String: JSONValue]?
    /// "app" or "cli".
    public var proc: String
    public var pid: Int32
}

/// Activity log shared by the app and the CLI: ~/Library/Logs/Lodestone/YYYY-MM-DD.jsonl.
///
/// Every user-visible action is logged so bugs can be triaged afterwards. Files older than
/// `retentionDays` are deleted. Writes go through a serial background queue and are appended with
/// O_APPEND, so the app and CLI can write to the same file at once. Nothing here runs on a hot path:
/// callers log outcomes (a snap, a conversion), never per-event work (mouse moves, clipboard polls).
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    public static let retentionDays = 7

    /// Set once at startup: "app" or "cli".
    public var process = "app"
    /// Entries below this level are dropped. Debug is off unless LODESTONE_DEBUG=1 is set.
    public var minimumLevel: LogEntry.Level = ProcessInfo.processInfo.environment["LODESTONE_DEBUG"] == "1" ? .debug : .info

    private let queue = DispatchQueue(label: "lodestone.log", qos: .utility)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Log.timestamp.string(from: date))
        }
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return e
    }()
    private var handle: FileHandle?
    private var currentDay = ""
    private let pid = ProcessInfo.processInfo.processIdentifier

    static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public func debug(_ cat: String, _ msg: String, _ data: [String: JSONValue]? = nil) { write(.debug, cat, msg, data) }
    public func info(_ cat: String, _ msg: String, _ data: [String: JSONValue]? = nil) { write(.info, cat, msg, data) }
    public func warn(_ cat: String, _ msg: String, _ data: [String: JSONValue]? = nil) { write(.warn, cat, msg, data) }
    public func error(_ cat: String, _ msg: String, _ data: [String: JSONValue]? = nil) { write(.error, cat, msg, data) }

    public func write(_ level: LogEntry.Level, _ cat: String, _ msg: String, _ data: [String: JSONValue]?) {
        guard level >= minimumLevel else { return }
        let entry = LogEntry(ts: Date(), level: level, cat: cat, msg: msg, data: data, proc: process, pid: pid)
        queue.async { [self] in
            guard var line = try? encoder.encode(entry) else { return }
            line.append(0x0A)
            fileHandle(for: entry.ts)?.write(line)
        }
    }

    /// Waits until queued entries are on disk. The CLI calls this before exiting.
    public func flush() {
        queue.sync {}
    }

    /// Deletes log files older than the retention window. Cheap; runs on each day change.
    public func prune(now: Date = Date()) {
        queue.async { [self] in pruneNow(now) }
    }

    private func fileHandle(for date: Date) -> FileHandle? {
        let day = Self.dayFormatter.string(from: date)
        if day != currentDay {
            try? handle?.close()
            handle = nil
            currentDay = day
            let url = Paths.logs.appendingPathComponent("\(day).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            // O_APPEND: every write lands at the current end, even with the CLI writing concurrently.
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CLOEXEC)
            if fd >= 0 { handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true) }
            pruneNow(date)
        }
        return handle
    }

    private func pruneNow(_ now: Date) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: now) ?? now
        let cutoffDay = Self.dayFormatter.string(from: cutoff)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.logs.path)) ?? []
        for name in files where name.hasSuffix(".jsonl") {
            let day = String(name.dropLast(6))
            if day < cutoffDay { try? FileManager.default.removeItem(at: Paths.logs.appendingPathComponent(name)) }
        }
    }

    /// Reads entries from the log files, oldest first.
    public static func read(since: Date? = nil) -> [LogEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            guard let date = timestamp.date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "bad date \(s)"))
            }
            return date
        }
        let sinceDay = since.map { dayFormatter.string(from: $0) }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: Paths.logs.path)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }
            .filter { sinceDay == nil || String($0.dropLast(6)) >= sinceDay! }
            .sorted()
        var entries: [LogEntry] = []
        for name in files {
            guard let text = try? String(contentsOf: Paths.logs.appendingPathComponent(name), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let entry = try? decoder.decode(LogEntry.self, from: Data(line.utf8)) else { continue }
                if let since, entry.ts < since { continue }
                entries.append(entry)
            }
        }
        return entries.sorted { $0.ts < $1.ts }
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    /// Convenience for log data: `["path": .string(url.path)]`.
    static func error(_ error: Error) -> [String: JSONValue] { ["error": .string(String(describing: error))] }
}
