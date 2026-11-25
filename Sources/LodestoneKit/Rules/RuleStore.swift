import Foundation
import LodestoneCore

/// Folder rules, stored as JSON in ~/Library/Application Support/Lodestone/rules.json (0600).
/// The app owns them at runtime; `lodestone rules` changes them through the app.
public struct RuleStore: Sendable {
    public let url: URL

    public static let shared = RuleStore(url: Paths.appSupport.appendingPathComponent("rules.json"))

    public init(url: URL) { self.url = url }

    private struct File: Codable {
        var version = 1
        var rules: [FolderRule]
    }

    /// The saved rules. A missing file means none; an unreadable one is logged and treated as none
    /// (and left in place, so nothing is lost until the next save).
    public func load() -> [FolderRule] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode(File.self, from: data).rules
        } catch {
            Log.shared.warn("rules", "store.unreadable", ["path": .string(url.path), "error": .string(String(describing: error))])
            return []
        }
    }

    public func save(_ rules: [FolderRule]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(File(rules: rules))
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw IPCError("write_failed", "Couldn't save folder rules to \(url.path): \(error.localizedDescription)")
        }
    }
}
