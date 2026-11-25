import Foundation

/// What a folder rule does with the original after converting it.
public enum RuleOriginals: String, Codable, CaseIterable, Sendable {
    case keep, trash
}

/// Automatic conversion: new files of the given kinds that land in `folder` are converted with the
/// converter engine ("new screen recordings on the Desktop become small MP4s").
public struct FolderRule: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    /// Absolute path of the watched folder.
    public var folder: String
    /// Also convert files in folders inside `folder`.
    public var includeSubfolders: Bool
    /// A file name pattern (`*` and `?`, case-insensitive), e.g. "Screen Recording*". Nil: any name.
    public var pattern: String?
    public var kinds: [MediaKind]
    /// Nil: the preset's format, else the kind's default (images keep their format).
    public var format: OutputFormat?
    /// Preset id. Nil: the default for the kind and format.
    public var preset: String?
    /// Absolute path for the results. Nil: next to the original.
    public var outputFolder: String?
    public var originals: RuleOriginals

    public init(id: String = FolderRule.newID(), name: String = "", enabled: Bool = true, folder: String,
                includeSubfolders: Bool = false, pattern: String? = nil, kinds: [MediaKind], format: OutputFormat? = nil,
                preset: String? = nil, outputFolder: String? = nil, originals: RuleOriginals = .keep) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.folder = folder
        self.includeSubfolders = includeSubfolders
        self.pattern = pattern
        self.kinds = kinds
        self.format = format
        self.preset = preset
        self.outputFolder = outputFolder
        self.originals = originals
        if self.name.isEmpty { self.name = defaultName }
    }

    /// Short, stable, easy to type in `lodestone rules enable <id>`.
    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// "Desktop: Screen Recording* → MP4".
    public var defaultName: String {
        let place = (folder as NSString).lastPathComponent
        let what = pattern.map { "\($0) " } ?? kinds.map(\.pluralTitle).joined(separator: ", ") + " "
        return "\(place): \(what)→ \(format?.title ?? "same format")"
    }

    /// A one-line description for lists: "Video → MP4 (balanced), trash originals".
    public var summary: String {
        var s = kinds.map(\.pluralTitle).joined(separator: ", ") + " → " + (format?.title ?? "same format")
        if let preset { s += " (\(preset))" }
        if let outputFolder { s += ", into \((outputFolder as NSString).abbreviatingWithTildeInPath)" }
        if originals == .trash { s += ", trash originals" }
        return s
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, folder, includeSubfolders, pattern, kinds, format, preset, outputFolder, originals
    }

    /// Lenient: fields added later get defaults, so an older rules.json keeps loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        folder = try c.decode(String.self, forKey: .folder)
        kinds = try c.decode([MediaKind].self, forKey: .kinds)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        includeSubfolders = try c.decodeIfPresent(Bool.self, forKey: .includeSubfolders) ?? false
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern)
        format = try c.decodeIfPresent(OutputFormat.self, forKey: .format)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        outputFolder = try c.decodeIfPresent(String.self, forKey: .outputFolder)
        originals = try c.decodeIfPresent(RuleOriginals.self, forKey: .originals) ?? .keep
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        if name.isEmpty { name = defaultName }
    }
}

/// Why a file is or isn't converted by a rule. `lodestone rules run --dry-run` shows these.
public enum RuleDecision: String, Codable, Sendable {
    case convert
    case outsideFolder = "outside_folder"
    case inSubfolder = "in_subfolder"
    case hidden
    case partial = "partial_download"
    case patternMismatch = "name_does_not_match"
    case wrongKind = "not_a_matching_kind"
    case alreadyTargetFormat = "already_in_target_format"
    /// Run Now only: the file's result is already there (converted earlier).
    case alreadyConverted = "already_converted"
}

public enum RuleMatching {
    /// Extensions of files still being written by browsers and sync tools.
    public static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "icloud", "opdownload"]

    /// Whether `path` is worth watching for `rule`, from the path alone (before the file settles and
    /// its kind is probed). `path` and `rule.folder` must be resolved the same way (FSEvents reports
    /// real paths, e.g. /private/tmp).
    public static func location(_ path: String, rule: FolderRule) -> RuleDecision {
        let folder = rule.folder.hasSuffix("/") ? String(rule.folder.dropLast()) : rule.folder
        guard path.hasPrefix(folder + "/") else { return .outsideFolder }
        let relative = path.dropFirst(folder.count + 1).split(separator: "/")
        guard let name = relative.last else { return .outsideFolder }
        if relative.contains(where: { $0.hasPrefix(".") }) { return .hidden }
        if relative.count > 1 && !rule.includeSubfolders { return .inSubfolder }
        let ext = (String(name) as NSString).pathExtension.lowercased()
        if partialExtensions.contains(ext) { return .partial }
        if let pattern = rule.pattern, !pattern.isEmpty, !glob(pattern, matches: String(name)) { return .patternMismatch }
        return .convert
    }

    /// The full decision once the file's kind is known (nil: not media).
    public static func decide(_ path: String, kind: MediaKind?, rule: FolderRule) -> RuleDecision {
        let where_ = location(path, rule: rule)
        guard where_ == .convert else { return where_ }
        guard let kind, rule.kinds.contains(kind) else { return .wrongKind }
        // Without this, a rule converting video to MP4 would convert its own MP4 output again.
        if let format = rule.format, OutputFormat.parse((path as NSString).pathExtension) == format { return .alreadyTargetFormat }
        return .convert
    }

    /// Where a rule writes `path`'s result under the plain name ("clip.mov" → "clip.mp4"), or nil
    /// when the rule keeps the format (the result then always gets a new name).
    public static func plainOutput(for path: String, rule: FolderRule) -> String? {
        guard let format = rule.format else { return nil }
        let directory = rule.outputFolder ?? (path as NSString).deletingLastPathComponent
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return (directory as NSString).appendingPathComponent("\(base).\(format.fileExtension)")
    }

    /// Shell-style matching of a whole file name: `*` any run, `?` one character, case-insensitive.
    public static func glob(_ pattern: String, matches name: String) -> Bool {
        let p = Array(pattern.lowercased()), n = Array(name.lowercased())
        var pi = 0, ni = 0, star = -1, mark = 0
        while ni < n.count {
            if pi < p.count, p[pi] == "?" || p[pi] == n[ni] {
                pi += 1; ni += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ni; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ni = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Problems that make a rule unusable, as messages for the user. Empty: the rule is fine.
    /// `presetKind` looks up a preset's media kind (nil: no such preset).
    public static func problems(_ rule: FolderRule, presetKind: (String) -> MediaKind?) -> [String] {
        var out: [String] = []
        if rule.folder.isEmpty || !rule.folder.hasPrefix("/") { out.append("The folder must be an absolute path.") }
        if rule.kinds.isEmpty { out.append("Choose at least one kind of file: images, video or audio.") }
        if let format = rule.format {
            for kind in rule.kinds where ConvertRoute(source: kind, format: format) == nil {
                out.append("\(kind.pluralTitle) can't be converted to \(format.title).")
            }
        }
        if let preset = rule.preset {
            if let presetKind = presetKind(preset) {
                for kind in rule.kinds {
                    let needed = rule.format.flatMap { ConvertRoute(source: kind, format: $0)?.presetKind } ?? kind
                    if needed != presetKind {
                        out.append("The preset '\(preset)' is for \(presetKind.pluralTitle.lowercased()), not \(kind.pluralTitle.lowercased()) to \(rule.format?.title ?? "the same format").")
                    }
                }
            } else {
                out.append("No preset '\(preset)'. See `lodestone presets list`.")
            }
        }
        if let output = rule.outputFolder, !output.hasPrefix("/") { out.append("The output folder must be an absolute path.") }
        return out
    }
}

/// Decides when a new file has finished being written: its size must stay the same across two
/// checks. Screen recordings, downloads and copies grow for a while before they're complete.
public struct SettleTracker: Sendable {
    private var sizes: [String: Int64] = [:]

    public init() {}

    public var pending: [String] { Array(sizes.keys) }
    public var isEmpty: Bool { sizes.isEmpty }

    public mutating func add(_ path: String) {
        // A new event for a pending file restarts its wait.
        sizes[path] = -1
    }

    public mutating func remove(_ path: String) { sizes[path] = nil }

    /// Records the current size (nil: the file is gone). Returns true once the file is ready, and
    /// then stops tracking it.
    public mutating func check(_ path: String, size: Int64?) -> Bool {
        guard let previous = sizes[path] else { return false }
        guard let size else {
            sizes[path] = nil
            return false
        }
        if size > 0 && size == previous {
            sizes[path] = nil
            return true
        }
        sizes[path] = size
        return false
    }
}
