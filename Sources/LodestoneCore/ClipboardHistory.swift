import Foundation

/// One entry of clipboard history. The index stores these; larger contents (full text, RTF, HTML,
/// PNG) live in blob files named `<id>.<blob>` next to it.
public struct ClipboardItem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case text, richText, image, files
    }

    /// Short random hex id, stable for the item's lifetime.
    public var id: String
    public var kind: Kind
    /// Plain text for display and search: the text itself (up to `ClipboardLimits.indexTextLimit`
    /// characters), file paths one per line, or "" for images.
    public var text: String
    /// True when `text` is cut short and the full text is in the "txt" blob.
    public var textTruncated: Bool
    /// Blob names stored for this item: "txt", "rtf", "html", "png".
    public var blobs: [String]
    public var filePaths: [String]
    public var imageWidth: Int?
    public var imageHeight: Int?
    /// Bytes this item takes: blobs plus inline text. Counted against the size cap.
    public var byteSize: Int
    /// Identifies the content for dedupe ("t:<sha>", "i:<sha>", "f:<sha>").
    public var contentHash: String
    public var sourceApp: String?
    public var sourceBundleID: String?
    /// When it was last copied (dedupe and pasting from history move it forward).
    public var date: Date
    public var pinned: Bool

    public init(id: String = ClipboardItem.newID(), kind: Kind, text: String, textTruncated: Bool = false,
                blobs: [String] = [], filePaths: [String] = [], imageWidth: Int? = nil, imageHeight: Int? = nil,
                byteSize: Int, contentHash: String, sourceApp: String? = nil, sourceBundleID: String? = nil,
                date: Date = Date(), pinned: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.textTruncated = textTruncated
        self.blobs = blobs
        self.filePaths = filePaths
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.byteSize = byteSize
        self.contentHash = contentHash
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.date = date
        self.pinned = pinned
    }

    public static func newID() -> String {
        (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// A one-line summary for lists: the first non-empty line of text, the file names, or "Image 1200×800".
    public var title: String {
        switch kind {
        case .image:
            if let w = imageWidth, let h = imageHeight { return "Image \(w)×\(h)" }
            return "Image"
        case .files:
            let names = filePaths.map { ($0 as NSString).lastPathComponent }
            return names.count <= 3 ? names.joined(separator: ", ") : "\(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) more"
        case .text, .richText:
            let line = text.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }
            return line.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
    }
}

/// Size limits for clipboard history.
public struct ClipboardLimits: Sendable, Equatable {
    /// Unpinned items kept.
    public var maxItems: Int
    /// Total bytes of unpinned items kept.
    public var maxBytes: Int

    public init(maxItems: Int = 200, maxBytes: Int = 256 * 1024 * 1024) {
        self.maxItems = maxItems
        self.maxBytes = maxBytes
    }

    /// Characters of text kept in the index for display and search; longer text goes in a blob.
    public static let indexTextLimit = 4096
    /// Captures bigger than this are skipped (a single copied item, all representations).
    public static let maxCaptureBytes = 20 * 1024 * 1024
    /// Stored images are re-encoded as PNG; larger PNGs are skipped.
    public static let maxImageBytes = 15 * 1024 * 1024
}

/// The ordered list of history items, newest first, with dedupe, limits, pinning and search.
/// Pure value logic; `ClipboardStore` (LodestoneKit) adds files on disk.
public struct ClipboardHistory: Codable, Sendable, Equatable {
    public private(set) var items: [ClipboardItem]

    public init(items: [ClipboardItem] = []) {
        self.items = items
    }

    public var totalBytes: Int { items.reduce(0) { $0 + $1.byteSize } }

    public func item(_ id: String) -> ClipboardItem? { items.first { $0.id == id } }

    /// Adds an item at the top. An item with the same content is replaced (it moves to the top and
    /// keeps its pin). Then the limits are applied. Returns the items removed, whose blobs the caller
    /// deletes: the replaced duplicate and anything evicted.
    @discardableResult
    public mutating func insert(_ item: ClipboardItem, limits: ClipboardLimits) -> [ClipboardItem] {
        var item = item
        var removed: [ClipboardItem] = []
        if let i = items.firstIndex(where: { $0.contentHash == item.contentHash }) {
            let old = items.remove(at: i)
            item.pinned = item.pinned || old.pinned
            removed.append(old)
        }
        items.insert(item, at: 0)
        return removed + enforce(limits)
    }

    /// Moves an item to the top with a new date (after pasting it from history).
    @discardableResult
    public mutating func touch(_ id: String, date: Date = Date()) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return false }
        var item = items.remove(at: i)
        item.date = date
        items.insert(item, at: 0)
        return true
    }

    /// Drops the oldest unpinned items until the unpinned ones fit the limits. Pinned items don't
    /// count and are never dropped; the newest item is always kept.
    @discardableResult
    public mutating func enforce(_ limits: ClipboardLimits) -> [ClipboardItem] {
        var count = 0
        var bytes = 0
        var keep: [ClipboardItem] = []
        var removed: [ClipboardItem] = []
        for (i, item) in items.enumerated() {
            if item.pinned {
                keep.append(item)
                continue
            }
            if i == 0 || (count < limits.maxItems && bytes + item.byteSize <= limits.maxBytes) {
                count += 1
                bytes += item.byteSize
                keep.append(item)
            } else {
                removed.append(item)
            }
        }
        items = keep
        return removed
    }

    @discardableResult
    public mutating func remove(_ id: String) -> ClipboardItem? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: i)
    }

    @discardableResult
    public mutating func setPinned(_ id: String, _ pinned: Bool) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return false }
        items[i].pinned = pinned
        return true
    }

    /// Removes every item, or every unpinned item. Returns what was removed.
    @discardableResult
    public mutating func clear(keepPinned: Bool) -> [ClipboardItem] {
        let removed = items.filter { !keepPinned || !$0.pinned }
        items = keepPinned ? items.filter(\.pinned) : []
        return removed
    }

    /// Items matching every word of `query` (case- and diacritic-insensitive) in their text, file
    /// names or source app. An empty query matches everything.
    public func search(_ query: String) -> [ClipboardItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            words.allSatisfy { word in
                item.text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || (item.sourceApp?.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
            }
        }
    }

    /// Finds an item by id, unique id prefix, or 1-based position ("1" is the newest).
    public func resolve(_ ref: String) -> ClipboardItem? {
        let ref = ref.trimmingCharacters(in: .whitespaces).lowercased()
        if let exact = item(ref) { return exact }
        if ref.count <= 4, let n = Int(ref) {
            return n >= 1 && n <= items.count ? items[n - 1] : nil
        }
        let matches = items.filter { $0.id.hasPrefix(ref) }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Which copies are not recorded.
public enum ClipboardRules {
    /// nspasteboard.org markers: password managers and apps that write temporary data set these.
    public static let concealedType = "org.nspasteboard.ConcealedType"
    public static let transientType = "org.nspasteboard.TransientType"
    public static let autoGeneratedType = "org.nspasteboard.AutoGeneratedType"

    /// 1Password 8 and 7, Bitwarden, Keychain Access, Passwords.
    public static let defaultIgnoredApps = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]

    /// Names for the default ignored apps, shown when they aren't installed.
    public static let knownAppNames = [
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7",
        "com.bitwarden.desktop": "Bitwarden",
        "com.apple.keychainaccess": "Keychain Access",
        "com.apple.Passwords": "Passwords",
    ]

    public enum SkipReason: String, Sendable {
        case concealed, transient, autoGenerated, ignoredApp
    }

    /// Why a copy should not be recorded, or nil to record it.
    public static func skipReason(types: [String], frontmostBundleID: String?, ignoredApps: [String]) -> SkipReason? {
        if types.contains(concealedType) { return .concealed }
        if types.contains(transientType) { return .transient }
        if types.contains(autoGeneratedType) { return .autoGenerated }
        if let id = frontmostBundleID?.lowercased(), ignoredApps.contains(where: { $0.lowercased() == id }) { return .ignoredApp }
        return nil
    }

    /// The ignored-apps setting is a comma- or newline-separated list of bundle ids.
    public static func parseAppList(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    public static func formatAppList(_ ids: [String]) -> String { ids.joined(separator: ",") }
}

public enum RelativeTime {
    /// Compact age for lists: "now", "5m", "3h", "2d", "4w".
    public static func short(from date: Date, to now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        case ..<(86400 * 14): return "\(s / 86400)d"
        default: return "\(s / (86400 * 7))w"
        }
    }

    /// Human byte count: "512 B", "12 KB", "3.4 MB".
    public static func bytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return "\(n / 1024) KB" }
        return String(format: "%.1f MB", Double(n) / 1_048_576)
    }
}
