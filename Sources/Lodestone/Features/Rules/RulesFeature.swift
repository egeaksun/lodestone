import AppKit
import LodestoneCore
import LodestoneKit

/// Automatic conversion: folder rules on top of the converter engine. New files that land in a
/// watched folder are converted once they've finished being written.
///
/// Idle cost: an FSEvents stream exists only while rules are on and at least one is enabled (the
/// kernel delivers events; nothing polls). The settle timer runs only while files are pending.
@MainActor
final class RulesFeature: Feature {
    let id = "rules"
    let title = "Folder Rules"
    let symbol = "folder.badge.gearshape"

    static let enabledKey = "rules.enabled"
    static let notifyKey = "rules.notify"

    private var context: AppContext!
    private let store: RuleStore
    private(set) var rules: [FolderRule] = []

    private var watcher: FolderWatcher?
    private var settle = SettleTracker()
    private var settleTimer: Timer?
    private var queue: [(rule: FolderRule, url: URL)] = []
    private var running: Task<Void, Never>?
    /// Outputs written by rules and inputs already handled, with when, so a rule never converts its
    /// own result and repeated events for one file don't convert it twice.
    private var seen: [String: Date] = [:]

    /// Settings views listening for rule changes.
    var onRulesChanged: (() -> Void)?

    init(store: RuleStore = .shared) {
        self.store = store
    }

    var settings: [SettingDefinition] {
        [
            SettingDefinition(Self.enabledKey, title: "Convert new files in watched folders automatically", kind: .bool, default: true),
            SettingDefinition(Self.notifyKey, title: "Notify when a rule converts a file", kind: .bool, default: true,
                              help: "Failures always notify."),
        ]
    }

    var commands: [AppCommand] {
        [AppCommand("rules.toggle", "Pause or Resume Folder Rules") { [weak self] in
            guard let self else { return }
            try? self.context.settings.set(Self.enabledKey, .bool(!self.enabled))
        }]
    }

    func start(_ context: AppContext) {
        self.context = context
        rules = store.load()
        updateWatcher()
    }

    func settingChanged(_ key: String) {
        if key == Self.enabledKey { updateWatcher() }
    }

    private var enabled: Bool { context.settings.bool(Self.enabledKey) }

    // MARK: Rules

    func rule(_ id: String) throws -> FolderRule {
        guard let rule = rules.first(where: { $0.id == id }) ?? uniquePrefixMatch(id) else {
            throw IPCError.notFound("No folder rule '\(id)'. Run `lodestone rules list` to see ids.")
        }
        return rule
    }

    private func uniquePrefixMatch(_ prefix: String) -> FolderRule? {
        let matches = rules.filter { $0.id.hasPrefix(prefix.lowercased()) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Validates, then adds or replaces (same id) a rule and saves.
    func save(_ rule: FolderRule) throws {
        var rule = rule
        rule.folder = Self.normalize(rule.folder)
        rule.outputFolder = rule.outputFolder.map(Self.normalize)
        if rule.pattern?.isEmpty == true { rule.pattern = nil }
        let problems = RuleMatching.problems(rule) { Converter.shared.presets.find($0)?.kind }
        guard problems.isEmpty else { throw IPCError.invalidParams(problems.joined(separator: " ")) }
        var updated = rules
        if let i = updated.firstIndex(where: { $0.id == rule.id }) { updated[i] = rule } else { updated.append(rule) }
        try store.save(updated)
        let isNew = !rules.contains { $0.id == rule.id }
        rules = updated
        Log.shared.info(id, isNew ? "rule.added" : "rule.updated",
                        ["rule": .string(rule.id), "folder": .string(rule.folder), "enabled": .bool(rule.enabled)])
        rulesChanged()
    }

    func remove(_ ruleID: String) throws -> FolderRule {
        let rule = try rule(ruleID)
        let updated = rules.filter { $0.id != rule.id }
        try store.save(updated)
        rules = updated
        queue.removeAll { $0.rule.id == rule.id }
        Log.shared.info(id, "rule.removed", ["rule": .string(rule.id)])
        rulesChanged()
        return rule
    }

    func setEnabled(_ ruleID: String, _ on: Bool) throws -> FolderRule {
        var rule = try rule(ruleID)
        rule.enabled = on
        try save(rule)
        return rule
    }

    private func rulesChanged() {
        updateWatcher()
        onRulesChanged?()
    }

    /// FSEvents reports real paths (/private/tmp), so rules store and compare those.
    static func normalize(_ path: String) -> String { FolderWatcher.realPath(path) }

    // MARK: Watching

    private var activeRules: [FolderRule] { enabled ? rules.filter(\.enabled) : [] }

    /// Folders being watched right now.
    var watchedFolders: [String] { watcher?.folders ?? [] }

    private func updateWatcher() {
        var isDirectory: ObjCBool = false
        let folders = Array(Set(activeRules.map(\.folder))).sorted().filter { folder in
            let exists = FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue
            if !exists { Log.shared.warn(id, "watch.missing_folder", ["folder": .string(folder)]) }
            return exists
        }
        guard folders != watcher?.folders ?? [] else { return }
        watcher?.stop()
        watcher = nil
        if folders.isEmpty {
            settle = SettleTracker()
            settleTimer?.invalidate()
            settleTimer = nil
            Log.shared.info(id, "watch.stop")
            return
        }
        watcher = FolderWatcher(folders: folders) { paths in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.filesChanged(paths) }
            }
        }
        Log.shared.info(id, watcher?.isRunning == true ? "watch.start" : "watch.failed", ["folders": .number(Double(folders.count))])
    }

    private func filesChanged(_ paths: [String]) {
        pruneSeen()
        for path in paths where seen[path] == nil {
            guard activeRules.contains(where: { RuleMatching.location(path, rule: $0) == .convert }) else { continue }
            settle.add(path)
        }
        if !settle.isEmpty && settleTimer == nil {
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkPending() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            settleTimer = timer
        }
    }

    /// Files whose size stopped changing are ready: decide with their kind, then queue them.
    private func checkPending() {
        for path in settle.pending {
            if seen[path] != nil {
                settle.remove(path)
                continue
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            guard settle.check(path, size: size) else { continue }
            let url = URL(fileURLWithPath: path)
            let kind = MediaProbe.quickKind(url)
            guard let rule = activeRules.first(where: { RuleMatching.decide(path, kind: kind, rule: $0) == .convert }) else { continue }
            enqueue(rule, url)
        }
        if settle.isEmpty {
            settleTimer?.invalidate()
            settleTimer = nil
        }
    }

    private func enqueue(_ rule: FolderRule, _ url: URL) {
        guard seen[url.path] == nil, !queue.contains(where: { $0.url == url }) else { return }
        seen[url.path] = Date()
        queue.append((rule, url))
        Log.shared.info(id, "match", ["rule": .string(rule.id), "path": .string(url.path)])
        runNext()
    }

    private func pruneSeen() {
        let cutoff = Date().addingTimeInterval(-600)
        seen = seen.filter { $0.value > cutoff }
    }

    // MARK: Converting

    /// One file at a time: rules run in the background and shouldn't compete with the user's own
    /// conversions for the encoder.
    private func runNext() {
        guard running == nil, !queue.isEmpty else { return }
        let (rule, url) = queue.removeFirst()
        let request = ConvertRequest(inputs: [url], target: ConvertTarget(format: rule.format, preset: rule.preset),
                                     outputDirectory: rule.outputFolder.map { URL(fileURLWithPath: $0) })
        let activity = context.activities.begin("\(rule.name): \(url.lastPathComponent)") { [weak self] in self?.running?.cancel() }
        let activities = context.activities
        running = Task { @MainActor [weak self] in
            let results = await Converter.shared.convert(request) { event in
                if case .progress(_, let fraction) = event {
                    Task { @MainActor in activities.update(activity, progress: fraction) }
                }
            }
            activities.end(activity)
            self?.finished(rule, url, results.first)
            self?.running = nil
            self?.runNext()
        }
    }

    private func finished(_ rule: FolderRule, _ url: URL, _ result: Result<ConvertResult, ConvertFailure>?) {
        switch result {
        case .success(let done):
            seen[Self.normalize(done.output)] = Date()
            var trashed = false
            if rule.originals == .trash { trashed = !Converter.trashOriginals([done]).isEmpty }
            Log.shared.info(id, "convert.done", ["rule": .string(rule.id), "input": .string(done.input), "output": .string(done.output),
                                                 "bytesIn": .number(Double(done.bytesIn)), "bytesOut": .number(Double(done.bytesOut)),
                                                 "seconds": .number(done.seconds), "trashedOriginal": .bool(trashed)])
            if context.settings.bool(Self.notifyKey) {
                let size = ByteCountFormatter.string(fromByteCount: done.bytesOut, countStyle: .file)
                context.notify(title: rule.name, body: "\(url.lastPathComponent) → \(URL(fileURLWithPath: done.output).lastPathComponent) (\(size))")
            }
        case .failure(let failure):
            if failure.error.code == "cancelled" {
                Log.shared.info(id, "convert.cancelled", ["rule": .string(rule.id), "input": .string(url.path)])
                return
            }
            Log.shared.warn(id, "convert.failed", ["rule": .string(rule.id), "input": .string(url.path),
                                                   "code": .string(failure.error.code), "error": .string(failure.error.message)])
            context.notify(title: "\(rule.name) failed", body: "\(url.lastPathComponent): \(failure.error.message)")
        case nil:
            break
        }
    }

    /// Applies a rule to the files already in its folder (they existed before the rule, so the
    /// watcher never saw them). With `dryRun`, only reports what would happen.
    func runNow(_ rule: FolderRule, dryRun: Bool) throws -> (convert: [String], skipped: [(String, RuleDecision)]) {
        let folder = URL(fileURLWithPath: rule.folder)
        let fm = FileManager.default
        var files: [URL] = []
        if rule.includeSubfolders {
            let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = e?.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { files.append(url) }
            }
        } else {
            do {
                files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                    .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            } catch {
                throw IPCError.notFound("Can't read \(rule.folder): \(error.localizedDescription)")
            }
        }
        var convert: [String] = [], skipped: [(String, RuleDecision)] = []
        for url in files.sorted(by: { $0.path < $1.path }) {
            let path = Self.normalize(url.path)
            var decision = RuleMatching.decide(path, kind: MediaProbe.quickKind(url), rule: rule)
            if decision == .convert, let output = RuleMatching.plainOutput(for: path, rule: rule), fm.fileExists(atPath: output) {
                decision = .alreadyConverted
            }
            if decision == .convert { convert.append(path) } else { skipped.append((path, decision)) }
        }
        Log.shared.info(id, dryRun ? "run.dry" : "run", ["rule": .string(rule.id), "convert": .number(Double(convert.count)),
                                                         "skipped": .number(Double(skipped.count))])
        if !dryRun {
            for path in convert { enqueue(rule, URL(fileURLWithPath: path)) }
        }
        return (convert, skipped)
    }

    var pendingCount: Int { settle.pending.count }
    var queuedCount: Int { queue.count + (running == nil ? 0 : 1) }

    // MARK: Menu

    func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for rule in rules {
            let item = NSMenuItem(title: rule.name) { [weak self] in _ = try? self?.setEnabled(rule.id, !rule.enabled) }
            item.state = rule.enabled ? .on : .off
            item.toolTip = rule.summary
            items.append(item)
        }
        if !rules.isEmpty { items.append(.separator()) }
        let toggle = context.menuItem("rules.toggle", title: enabled ? "Pause All Rules" : "Resume All Rules")
        toggle.isEnabled = !rules.isEmpty
        items.append(toggle)
        items.append(NSMenuItem(title: rules.isEmpty ? "Add a Folder Rule…" : "Edit Folder Rules…") { [weak self] in
            self?.context.openSettings(tab: "rules")
        })
        let title = enabled || rules.isEmpty ? "Folder Rules" : "Folder Rules (paused)"
        return [NSMenuItem(title: title, submenu: items)]
    }

    func makeSettingsView() -> NSView? {
        RulesSettingsView.make(feature: self, context: context)
    }

    // MARK: IPC

    struct RuleInfo: Encodable {
        var rule: FolderRule
        var summary: String
        var watching: Bool
        var folderExists: Bool

        func encode(to encoder: Encoder) throws {
            try rule.encode(to: encoder)
            enum Extra: String, CodingKey { case summary, watching, folderExists }
            var c = encoder.container(keyedBy: Extra.self)
            try c.encode(summary, forKey: .summary)
            try c.encode(watching, forKey: .watching)
            try c.encode(folderExists, forKey: .folderExists)
        }
    }

    func info(_ rule: FolderRule) -> RuleInfo {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: rule.folder, isDirectory: &isDirectory) && isDirectory.boolValue
        return RuleInfo(rule: rule, summary: rule.summary, watching: enabled && rule.enabled && watchedFolders.contains(rule.folder),
                        folderExists: exists)
    }

    /// The fields `rules.add` and `rules.update` accept. On update, absent fields stay as they are;
    /// `""` clears pattern, format, preset and outputFolder.
    struct RuleParams: Decodable {
        var id: String?
        var name: String?
        var enabled: Bool?
        var folder: String?
        var includeSubfolders: Bool?
        var pattern: String?
        var kinds: [String]?
        var format: String?
        var preset: String?
        var outputFolder: String?
        var originals: String?

        func apply(to rule: inout FolderRule) throws {
            if let name { rule.name = name }
            if let enabled { rule.enabled = enabled }
            if let folder { rule.folder = folder }
            if let includeSubfolders { rule.includeSubfolders = includeSubfolders }
            if let pattern { rule.pattern = pattern.isEmpty ? nil : pattern }
            if let kinds {
                rule.kinds = try kinds.map { name in
                    guard let kind = MediaKind(rawValue: name.lowercased()) else {
                        throw IPCError.invalidParams("Unknown kind '\(name)'. Use image, video or audio.")
                    }
                    return kind
                }
            }
            if let format {
                if format.isEmpty || format == "same" {
                    rule.format = nil
                } else {
                    guard let f = OutputFormat.parse(format) else {
                        throw IPCError.invalidParams("Unknown format '\(format)'. See `lodestone convert formats`.")
                    }
                    rule.format = f
                }
            }
            if let preset { rule.preset = preset.isEmpty ? nil : (Converter.shared.presets.find(preset)?.id ?? preset) }
            if let outputFolder { rule.outputFolder = outputFolder.isEmpty ? nil : outputFolder }
            if let originals {
                guard let o = RuleOriginals(rawValue: originals) else { throw IPCError.invalidParams("originals must be keep or trash") }
                rule.originals = o
            }
        }
    }

    private struct IDParams: Decodable { var id: String }
    private struct RunParams: Decodable { var id: String; var dryRun: Bool? }

    func registerIPC(_ router: IPCRouter) {
        let fields = #"{"folder": path, "kinds": ["image"|"video"|"audio"], "format"?: string, "preset"?: string, "pattern"?: "Screen Recording*", "name"?: string, "outputFolder"?: path, "originals"?: "keep"|"trash", "includeSubfolders"?: bool, "enabled"?: bool}"#

        router.register("rules.list", summary: "Folder rules (automatic conversion), with whether each is being watched", NoParams.self) { [weak self] _ -> [RuleInfo] in
            guard let self else { return [] }
            return self.rules.map(self.info)
        }

        router.register("rules.status", summary: "Whether folder rules are on, which folders are watched, and files waiting", NoParams.self) { [weak self] _ -> JSONValue in
            guard let self else { return .null }
            return ["enabled": .bool(self.enabled), "rules": .number(Double(self.rules.count)),
                    "watching": .array(self.watchedFolders.map { .string($0) }),
                    "settling": .number(Double(self.pendingCount)), "queued": .number(Double(self.queuedCount))]
        }

        router.register("rules.add", summary: "Add a folder rule: new matching files in the folder are converted automatically",
                        params: fields, RuleParams.self) { [weak self] p -> RuleInfo in
            guard let self else { throw IPCError.failed("Unavailable") }
            guard let folder = p.folder else { throw IPCError.invalidParams("folder is required") }
            var rule = FolderRule(folder: Self.normalize(folder), kinds: [])
            try p.apply(to: &rule)
            rule.folder = Self.normalize(rule.folder)
            if (p.name ?? "").isEmpty { rule.name = rule.defaultName }
            try self.save(rule)
            return self.info(rule)
        }

        router.register("rules.update", summary: "Change a folder rule's fields (absent fields are kept)",
                        params: #"{"id": string, ...same fields as rules.add}"#, RuleParams.self) { [weak self] p -> RuleInfo in
            guard let self else { throw IPCError.failed("Unavailable") }
            guard let id = p.id else { throw IPCError.invalidParams("id is required") }
            var rule = try self.rule(id)
            let automaticName = rule.name == rule.defaultName
            try p.apply(to: &rule)
            if automaticName && p.name == nil || p.name?.isEmpty == true { rule.name = rule.defaultName }
            try self.save(rule)
            return self.info(try self.rule(rule.id))
        }

        router.register("rules.remove", summary: "Delete a folder rule", params: #"{"id": string}"#, IDParams.self) { [weak self] p -> RuleInfo in
            guard let self else { throw IPCError.failed("Unavailable") }
            let rule = try self.remove(p.id)
            return self.info(rule)
        }

        router.register("rules.run", summary: "Convert the files already in a rule's folder (dryRun: only list them, with reasons for skips)",
                        params: #"{"id": string, "dryRun"?: bool}"#, RunParams.self) { [weak self] p -> JSONValue in
            guard let self else { throw IPCError.failed("Unavailable") }
            let rule = try self.rule(p.id)
            let dryRun = p.dryRun ?? false
            let (convert, skipped) = try self.runNow(rule, dryRun: dryRun)
            return ["rule": .string(rule.id), "dryRun": .bool(dryRun), "convert": .array(convert.map { .string($0) }),
                    "skipped": .array(skipped.map { ["path": .string($0.0), "reason": .string($0.1.rawValue)] })]
        }
    }
}
