import Foundation
import LodestoneCore

/// Where the results of PDF and image tools go, and how they get there: work is written to a
/// temporary file, then moved next to the source (or to an explicit path) under a name that isn't
/// taken yet. Existing files are never overwritten.
public enum ResultFiles {
    /// The output path for a result of `source`. With `explicit`, that path (an existing folder means
    /// "inside it", under the usual name); otherwise "<source name> (<tag>).<ext>" next to the source
    /// ("<source name>.<ext>" without a tag).
    public static func destination(explicit: URL?, source: URL, tag: String?, ext: String) throws -> URL {
        let base = SiblingFile.base(of: source)
        guard let explicit else {
            return SiblingFile.unique(in: source.deletingLastPathComponent(), base: base, tag: tag, ext: ext, exists: exists)
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: explicit.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return SiblingFile.unique(in: explicit, base: base, tag: tag, ext: ext, exists: exists)
            }
            throw IPCError("file_exists", "\(explicit.path) already exists. Choose another output path or delete it first.")
        }
        let folder = explicit.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw IPCError.notFound("The folder \(folder.path) doesn't exist. Create it first or choose another output path.")
        }
        return explicit
    }

    /// The folder for several results: `explicit` (created if missing), or a new
    /// "<source name> (<tag>)" folder next to the source.
    public static func folder(explicit: URL?, source: URL, tag: String) throws -> URL {
        let url: URL
        if let explicit {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: explicit.path, isDirectory: &isDirectory) {
                // An existing folder is used as is.
                guard isDirectory.boolValue else {
                    throw IPCError("file_exists", "\(explicit.path) is a file. Give a folder for the results.")
                }
                return explicit
            }
            url = explicit
        } else {
            url = try destination(explicit: nil, source: source, tag: tag, ext: "")
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            throw IPCError("write_failed", "Couldn't create the folder \(url.path): \(error.localizedDescription)")
        }
        return url
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A scratch file to write into before `place` moves it to its destination.
    static func temporary(ext: String) -> URL {
        Paths.ensure(Paths.caches.appendingPathComponent("work", isDirectory: true))
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    /// Moves a finished scratch file to `destination`. If that name was taken in the meantime, the
    /// next free name is used instead. Returns where the file ended up.
    static func place(_ temp: URL, at destination: URL) throws -> URL {
        var target = destination
        let fm = FileManager.default
        for _ in 0..<50 {
            do {
                try fm.moveItem(at: temp, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                let ext = destination.pathExtension
                target = SiblingFile.unique(in: destination.deletingLastPathComponent(),
                                            base: destination.deletingPathExtension().lastPathComponent,
                                            tag: nil, ext: ext, exists: exists)
            } catch {
                try? fm.removeItem(at: temp)
                throw IPCError("write_failed", "Couldn't save \(destination.lastPathComponent) in \(destination.deletingLastPathComponent().path): \(error.localizedDescription)")
            }
        }
        try? fm.removeItem(at: temp)
        throw IPCError("write_failed", "Couldn't find a free file name for \(destination.path)")
    }

    public static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    public static func requireFile(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw IPCError.notFound("\(url.path) doesn't exist")
        }
    }
}

/// Progress from 0 to 1, called from a background thread.
public typealias ProgressHandler = @Sendable (Double) -> Void

/// Logs an operation's start and outcome (done with duration, failed, or cancelled) under `category`.
enum LoggedOperation {
    static func run<T>(_ category: String, _ name: String, _ data: [String: JSONValue],
                       _ body: () async throws -> T, outcome: (T) -> [String: JSONValue]) async throws -> T {
        let start = Date()
        Log.shared.info(category, "\(name).start", data)
        func ms() -> JSONValue { .number((Date().timeIntervalSince(start) * 1000).rounded()) }
        do {
            let result = try await body()
            Log.shared.info(category, "\(name).done", data.merging(outcome(result)) { $1 }.merging(["ms": ms()]) { $1 })
            return result
        } catch is CancellationError {
            Log.shared.info(category, "\(name).cancelled", data.merging(["ms": ms()]) { $1 })
            throw IPCError("cancelled", "Cancelled")
        } catch let error as IPCError {
            let level: LogEntry.Level = error.code == "cancelled" ? .info : .warn
            Log.shared.write(level, category, error.code == "cancelled" ? "\(name).cancelled" : "\(name).failed",
                             data.merging(["code": .string(error.code), "error": .string(error.message), "ms": ms()]) { $1 })
            throw error
        } catch {
            Log.shared.error(category, "\(name).failed", data.merging(["error": .string(String(describing: error)), "ms": ms()]) { $1 })
            throw IPCError.failed(error.localizedDescription)
        }
    }
}

extension URL {
    var logValue: JSONValue { .string(path) }
}

extension Array where Element == URL {
    var logValue: JSONValue { .array(map { .string($0.path) }) }
}
