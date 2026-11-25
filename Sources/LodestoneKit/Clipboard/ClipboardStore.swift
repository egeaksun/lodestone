import Foundation
import LodestoneCore

/// Clipboard history on disk: `index.json` plus one blob file per stored representation
/// (`<id>.txt`, `.rtf`, `.html`, `.png`), all 0600 in a 0700 directory.
///
/// When `persistent` is false nothing is written: blobs stay in memory and anything left on disk is
/// deleted, so history ends with the app. All methods are thread-safe; disk writes run in order on
/// a background queue (`flush()` waits for them).
public final class ClipboardStore: @unchecked Sendable {
    public static var defaultDirectory: URL { Paths.appSupport.appendingPathComponent("Clipboard", isDirectory: true) }

    public let directory: URL
    private let lock = NSLock()
    private var history = ClipboardHistory()
    private var memoryBlobs: [String: Data] = [:]
    private var _persistent: Bool
    private var _limits: ClipboardLimits
    private let io = DispatchQueue(label: "lodestone.clipboard.store", qos: .utility)

    private struct Index: Codable {
        var version = 1
        var items: [ClipboardItem]
    }

    public init(directory: URL = ClipboardStore.defaultDirectory, persistent: Bool, limits: ClipboardLimits = ClipboardLimits()) {
        self.directory = directory
        self._persistent = persistent
        self._limits = limits
        if persistent {
            load()
        } else {
            wipeDisk()
        }
    }

    // MARK: Reading

    public var items: [ClipboardItem] { locked { history.items } }
    public var totalBytes: Int { locked { history.totalBytes } }
    public var persistent: Bool { locked { _persistent } }
    public var limits: ClipboardLimits { locked { _limits } }

    public func item(_ id: String) -> ClipboardItem? { locked { history.item(id) } }
    public func resolve(_ ref: String) -> ClipboardItem? { locked { history.resolve(ref) } }
    public func search(_ query: String) -> [ClipboardItem] { locked { history.search(query) } }

    /// A stored representation ("txt", "rtf", "html", "png"), or nil.
    public func data(_ id: String, _ blob: String) -> Data? {
        let name = "\(id).\(blob)"
        let (persistent, memory) = locked { (_persistent, memoryBlobs[name]) }
        guard persistent else { return memory }
        io.sync {} // pending writes first
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// The item's whole plain text (from the "txt" blob when the index copy is truncated).
    public func fullText(_ item: ClipboardItem) -> String {
        if item.textTruncated, let data = data(item.id, "txt"), let text = String(data: data, encoding: .utf8) { return text }
        return item.text
    }

    // MARK: Changes

    /// Adds an item with its blobs. Returns the items it replaced or evicted.
    @discardableResult
    public func add(_ item: ClipboardItem, blobs: [String: Data]) -> [ClipboardItem] {
        let (removed, persistent, snapshot) = locked { () -> ([ClipboardItem], Bool, [ClipboardItem]) in
            let removed = history.insert(item, limits: _limits)
            if !_persistent {
                for (blob, data) in blobs { memoryBlobs["\(item.id).\(blob)"] = data }
            }
            dropMemoryBlobs(removed)
            return (removed, _persistent, history.items)
        }
        if persistent {
            let dir = directory
            io.async {
                for (blob, data) in blobs { Self.writeSecure(data, to: dir.appendingPathComponent("\(item.id).\(blob)")) }
                Self.deleteBlobs(removed, in: dir)
                Self.writeIndex(snapshot, in: dir)
            }
        }
        return removed
    }

    @discardableResult
    public func touch(_ id: String, date: Date = Date()) -> Bool {
        mutate { $0.touch(id, date: date) ? [] : nil } != nil
    }

    @discardableResult
    public func delete(_ id: String) -> ClipboardItem? {
        mutate { h in h.remove(id).map { [$0] } }?.first
    }

    @discardableResult
    public func setPinned(_ id: String, _ pinned: Bool) -> Bool {
        let result = mutate { h -> [ClipboardItem]? in
            guard h.setPinned(id, pinned) else { return nil }
            // Unpinning can put the history over its limits.
            return pinned ? [] : h.enforce(self._limits)
        }
        return result != nil
    }

    /// Removes everything, or everything unpinned. Returns the number of items removed.
    @discardableResult
    public func clear(keepPinned: Bool) -> Int {
        mutate { $0.clear(keepPinned: keepPinned) }?.count ?? 0
    }

    /// Applies new limits. Returns the evicted items.
    @discardableResult
    public func setLimits(_ limits: ClipboardLimits) -> [ClipboardItem] {
        mutate { h in
            self._limits = limits
            return h.enforce(limits)
        } ?? []
    }

    /// Switches between keeping history on disk and in memory only.
    public func setPersistent(_ persistent: Bool) {
        let dir = directory
        lock.lock()
        guard persistent != _persistent else { lock.unlock(); return }
        _persistent = persistent
        if persistent {
            let blobs = memoryBlobs
            let snapshot = history.items
            memoryBlobs = [:]
            lock.unlock()
            io.async {
                Self.ensureDirectory(dir)
                for (name, data) in blobs { Self.writeSecure(data, to: dir.appendingPathComponent(name)) }
                Self.writeIndex(snapshot, in: dir)
            }
        } else {
            let names = history.items.flatMap { item in item.blobs.map { "\(item.id).\($0)" } }
            lock.unlock()
            var loaded: [String: Data] = [:]
            io.sync {
                for name in names { loaded[name] = try? Data(contentsOf: dir.appendingPathComponent(name)) }
            }
            locked { memoryBlobs.merge(loaded) { a, _ in a } }
            wipeDisk()
        }
    }

    /// Waits for queued disk writes.
    public func flush() { io.sync {} }

    // MARK: Internals

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Runs a change; `body` returns the removed items, or nil when nothing changed.
    private func mutate(_ body: (inout ClipboardHistory) -> [ClipboardItem]?) -> [ClipboardItem]? {
        let (removed, persistent, snapshot) = locked { () -> ([ClipboardItem]?, Bool, [ClipboardItem]) in
            let removed = body(&history)
            if let removed { dropMemoryBlobs(removed) }
            return (removed, _persistent, history.items)
        }
        if let removed, persistent {
            let dir = directory
            io.async {
                Self.deleteBlobs(removed, in: dir)
                Self.writeIndex(snapshot, in: dir)
            }
        }
        return removed
    }

    /// Call with the lock held.
    private func dropMemoryBlobs(_ removed: [ClipboardItem]) {
        for item in removed {
            // A replaced duplicate can share its id with nothing new; blobs are keyed by id.
            for blob in item.blobs where history.item(item.id) == nil { memoryBlobs["\(item.id).\(blob)"] = nil }
        }
    }

    private func load() {
        Self.ensureDirectory(directory)
        let url = directory.appendingPathComponent("index.json")
        var items: [ClipboardItem] = []
        if let data = try? Data(contentsOf: url) {
            do {
                items = try Self.decoder.decode(Index.self, from: data).items
            } catch {
                Log.shared.error("clipboard", "store.index_unreadable", ["path": .string(url.path), "error": .string(String(describing: error))])
            }
        }
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        // Items whose blobs are gone can't be pasted; drop them.
        items = items.filter { item in item.blobs.allSatisfy { files.contains("\(item.id).\($0)") } }
        history = ClipboardHistory(items: items)
        let removed = history.enforce(_limits)
        // Files no item refers to (left by a crash, or by evicted items) are deleted.
        let referenced = Set(history.items.flatMap { item in item.blobs.map { "\(item.id).\($0)" } } + ["index.json"])
        for name in files where !referenced.contains(name) && !name.hasPrefix(".") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        if !removed.isEmpty || items.count != history.items.count { Self.writeIndex(history.items, in: directory) }
    }

    private func wipeDisk() {
        let dir = directory
        io.async {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    private static func ensureDirectory(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    private static func writeIndex(_ items: [ClipboardItem], in dir: URL) {
        guard let data = try? encoder.encode(Index(items: items)) else { return }
        writeSecure(data, to: dir.appendingPathComponent("index.json"))
    }

    private static func deleteBlobs(_ items: [ClipboardItem], in dir: URL) {
        for item in items { for blob in item.blobs { try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(item.id).\(blob)")) } }
    }

    /// Writes a file readable only by the user, atomically (temporary file, then rename).
    static func writeSecure(_ data: Data, to url: URL) {
        ensureDirectory(url.deletingLastPathComponent())
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            Log.shared.error("clipboard", "store.write_failed", ["path": .string(url.path)])
            return
        }
        if rename(tmp.path, url.path) != 0 {
            Log.shared.error("clipboard", "store.write_failed", ["path": .string(url.path), "errno": .number(Double(errno))])
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
