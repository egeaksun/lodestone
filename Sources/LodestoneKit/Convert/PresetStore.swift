import Foundation
import LodestoneCore

/// Built-in presets plus the user's own, stored as JSON in
/// ~/Library/Application Support/Lodestone/presets.json. The app and the CLI read the file on every
/// call, so a preset saved by one shows up in the other immediately.
public struct PresetStore: Sendable {
    public let url: URL

    public static let shared = PresetStore(url: Paths.appSupport.appendingPathComponent("presets.json"))

    public init(url: URL) { self.url = url }

    private struct File: Codable {
        var version = 1
        var presets: [Preset]
    }

    /// Custom presets only. A missing or unreadable file means none.
    public func custom() -> [Preset] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode(File.self, from: data).presets.map {
                var p = $0
                p.builtIn = false
                return p
            }
        } catch {
            Log.shared.warn("converter", "presets.unreadable", ["path": .string(url.path), "error": .string(String(describing: error))])
            return []
        }
    }

    public func all() -> [Preset] { BuiltInPresets.all + custom() }

    public func forKind(_ kind: MediaKind) -> [Preset] { all().filter { $0.kind == kind } }

    /// By id or name, case-insensitive.
    public func find(_ query: String) -> Preset? { BuiltInPresets.find(query, in: all()) }

    /// Saves (or replaces) a custom preset. Its id is derived from the name.
    @discardableResult
    public func save(name: String, kind: MediaKind, format: OutputFormat?, options: ConvertOptions, summary: String = "") throws -> Preset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = Preset.slug(trimmed)
        guard !id.isEmpty else { throw IPCError.invalidParams("Give the preset a name.") }
        if BuiltInPresets.all.contains(where: { $0.id == id || $0.name.lowercased() == trimmed.lowercased() }) {
            throw IPCError.invalidParams("'\(trimmed)' is a built-in preset. Choose another name.")
        }
        try options.validate()
        let preset = Preset(id: id, name: trimmed, kind: kind, summary: summary.isEmpty ? options.summary : summary,
                            format: format, options: options)
        var presets = custom().filter { $0.id != id }
        presets.append(preset)
        try write(presets)
        Log.shared.info("converter", "preset.saved", ["id": .string(id), "kind": .string(kind.rawValue)])
        return preset
    }

    /// Deletes a custom preset. Built-in presets can't be deleted.
    @discardableResult
    public func delete(_ query: String) throws -> Preset {
        guard let preset = BuiltInPresets.find(query, in: custom()) else {
            if BuiltInPresets.find(query, in: BuiltInPresets.all) != nil {
                throw IPCError.invalidParams("'\(query)' is a built-in preset and can't be deleted.")
            }
            throw IPCError.notFound("No custom preset '\(query)'. Run `lodestone presets list`.")
        }
        try write(custom().filter { $0.id != preset.id })
        Log.shared.info("converter", "preset.deleted", ["id": .string(preset.id)])
        return preset
    }

    private func write(_ presets: [Preset]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(File(presets: presets.sorted { $0.name < $1.name }))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
