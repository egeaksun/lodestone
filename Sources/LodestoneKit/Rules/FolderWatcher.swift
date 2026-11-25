import CoreServices
import Foundation

/// Reports files created, renamed into, or modified in a set of folders (and their subfolders),
/// using FSEvents. The kernel delivers events, so nothing runs while the folders are quiet.
public final class FolderWatcher: @unchecked Sendable {
    public let folders: [String]
    private let handler: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "lodestone.rules.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    /// `handler` runs on a background queue with the changed files' real paths (symlinks resolved,
    /// e.g. /private/tmp), batched over `latency` seconds.
    public init(folders: [String], latency: TimeInterval = 1.0, handler: @escaping @Sendable ([String]) -> Void) {
        self.folders = folders
        self.handler = handler
        start(latency: latency)
    }

    deinit { stop() }

    /// The path the way FSEvents reports it: absolute, `~` expanded, symlinks resolved with realpath(3)
    /// (/tmp → /private/tmp; Foundation's resolvingSymlinksInPath goes the other way). A path that
    /// doesn't exist yet is only standardized.
    public static func realPath(_ path: String) -> String {
        let expanded = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        guard let resolved = realpath(expanded, nil) else { return expanded }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public var isRunning: Bool { stream != nil }

    private func start(latency: TimeInterval) {
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let all = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let wanted = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)
            var changed: [String] = []
            for i in 0..<min(count, all.count) {
                let f = flags[i]
                if f & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 && f & wanted != 0 { changed.append(all[i]) }
            }
            if !changed.isEmpty { watcher.handler(changed) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, folders as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    /// Stops delivering events. Safe to call more than once; never call it from `handler`.
    public func stop() {
        guard let stream else { return }
        self.stream = nil
        // On the stream's queue, so no callback is running (with an unretained self) once this returns.
        queue.sync {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
