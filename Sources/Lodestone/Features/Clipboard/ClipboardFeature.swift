import AppKit
import Carbon.HIToolbox
import LodestoneCore
import LodestoneKit

/// Clipboard history (a searchable panel of what was copied) and paste as plain text, plus the
/// `lodestone clipboard ...` commands that need the app's history.
@MainActor
final class ClipboardFeature: Feature {
    let id = "clipboard"
    let title = "Clipboard"
    let symbol = "doc.on.clipboard"

    static let enabledKey = "clipboard.enabled"
    static let maxItemsKey = "clipboard.maxItems"
    static let maxStorageKey = "clipboard.maxStorageMB"
    static let persistKey = "clipboard.persist"
    static let ignoredAppsKey = "clipboard.ignoredApps"
    static let restoreKey = "clipboard.restoreAfterPlainPaste"

    static let historyCommand = "clipboard.history"
    static let pastePlainCommand = "clipboard.pastePlain"
    static let togglePauseCommand = "clipboard.togglePause"

    private var context: AppContext!
    private let storeDirectory: URL
    /// Loaded while history is enabled.
    private(set) var store: ClipboardStore?
    private let monitor = ClipboardMonitor()
    private lazy var panel = makePanel()
    private var ignoredApps: [String] = []
    /// Processes captures in order, off the main thread (PNG encoding, hashing, disk writes).
    private let captureQueue = DispatchQueue(label: "lodestone.clipboard.capture", qos: .utility)

    private enum Pause: Equatable {
        case none, indefinitely, until(Date)
    }
    private var pause = Pause.none
    private var resumeTimer: Timer?

    init(storeDirectory: URL = ClipboardStore.defaultDirectory) {
        self.storeDirectory = storeDirectory
    }

    var settings: [SettingDefinition] {
        [
            SettingDefinition(Self.enabledKey, title: "Keep a history of what you copy", kind: .bool, default: true),
            SettingDefinition(Self.maxItemsKey, title: "Items to keep", kind: .int(range: 10...1000), default: 200,
                              help: "Pinned items don't count."),
            SettingDefinition(Self.maxStorageKey, title: "Storage limit (MB)", kind: .int(range: 16...2048), default: 256,
                              help: "Total size of unpinned items; the oldest go first."),
            SettingDefinition(Self.persistKey, title: "Keep history across restarts", kind: .bool, default: true,
                              help: "Off: history is kept in memory only and is gone when Lodestone quits."),
            SettingDefinition(Self.ignoredAppsKey, title: "Apps whose copies aren't recorded", kind: .string,
                              default: .string(ClipboardRules.formatAppList(ClipboardRules.defaultIgnoredApps)),
                              help: "Comma-separated bundle ids."),
            SettingDefinition(Self.restoreKey, title: "Restore the clipboard after Paste as Plain Text", kind: .bool, default: true,
                              help: "Puts the original formatted contents back after pasting."),
        ]
    }

    var commands: [AppCommand] {
        let co = UInt32(controlKey | optionKey)
        return [
            AppCommand(Self.historyCommand, "Clipboard History", shortcut: KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: co)) { [weak self] in
                self?.showPanel()
            },
            AppCommand(Self.pastePlainCommand, "Paste as Plain Text",
                       shortcut: KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: co | UInt32(shiftKey))) { [weak self] in
                self?.pastePlain(via: "shortcut")
            },
            AppCommand(Self.togglePauseCommand, "Pause or Resume Clipboard History") { [weak self] in
                guard let self else { return }
                if self.isPaused { self.resume() } else { self.pauseHistory(minutes: nil) }
            },
        ]
    }

    func start(_ context: AppContext) {
        self.context = context
        monitor.onChange = { [weak self] _ in self?.pasteboardChanged() }
        ignoredApps = ClipboardRules.parseAppList(context.settings.string(Self.ignoredAppsKey))
        update()
    }

    func settingChanged(_ key: String) {
        switch key {
        case Self.enabledKey: update()
        case Self.maxItemsKey, Self.maxStorageKey:
            let removed = store?.setLimits(limits) ?? []
            if !removed.isEmpty { historyChanged() }
        case Self.persistKey: store?.setPersistent(context.settings.bool(Self.persistKey))
        case Self.ignoredAppsKey: ignoredApps = ClipboardRules.parseAppList(context.settings.string(Self.ignoredAppsKey))
        default: break
        }
    }

    private var enabled: Bool { context.settings.bool(Self.enabledKey) }
    private var isPaused: Bool { pause != .none }

    private var limits: ClipboardLimits {
        ClipboardLimits(maxItems: context.settings.int(Self.maxItemsKey), maxBytes: context.settings.int(Self.maxStorageKey) * 1024 * 1024)
    }

    /// Loads the store and runs the monitor only while history is enabled and not paused.
    private func update() {
        if enabled && store == nil {
            let start = Date()
            store = ClipboardStore(directory: storeDirectory, persistent: context.settings.bool(Self.persistKey), limits: limits)
            Log.shared.info("clipboard", "store.loaded", ["items": .number(Double(store?.items.count ?? 0)),
                                                         "ms": .number(IPCRouter.ms(since: start))])
        }
        if enabled && !isPaused { monitor.start() } else { monitor.stop() }
    }

    // MARK: Capture

    private func pasteboardChanged() {
        guard let store else { return }
        let pb = NSPasteboard.general
        let types = PasteboardIO.types(pb)
        let front = NSWorkspace.shared.frontmostApplication
        if let reason = ClipboardRules.skipReason(types: types, frontmostBundleID: front?.bundleIdentifier, ignoredApps: ignoredApps) {
            if reason == .ignoredApp {
                Log.shared.info("clipboard", "skip.ignored_app", ["app": .string(front?.bundleIdentifier ?? "?")])
            } else {
                Log.shared.debug("clipboard", "skip", ["reason": .string(reason.rawValue)])
            }
            return
        }
        guard let capture = PasteboardIO.capture(pb) else { return }
        let app = front?.localizedName
        let bundleID = front?.bundleIdentifier
        captureQueue.async { [weak self] in
            switch capture.prepare(sourceApp: app, sourceBundleID: bundleID) {
            case .success(let (item, blobs)):
                store.add(item, blobs: blobs)
                Log.shared.debug("clipboard", "capture", ["kind": .string(item.kind.rawValue), "bytes": .number(Double(item.byteSize))])
                DispatchQueue.main.async { self?.historyChanged() }
            case .failure(let reason):
                if reason == .tooLarge {
                    Log.shared.info("clipboard", "skip.too_large", ["types": .number(Double(capture.types.count))])
                } else {
                    Log.shared.debug("clipboard", "skip", ["reason": .string(reason.rawValue)])
                }
            }
        }
    }

    private func historyChanged() {
        if panel.isVisible, let store { panel.setItems(store.items) }
    }

    // MARK: Actions

    private func showPanel() {
        let items = store?.items ?? []
        let message: String
        if !enabled {
            message = "Clipboard history is off. Turn it on in Settings → Clipboard."
        } else if isPaused {
            message = "Clipboard history is paused."
        } else {
            message = "Nothing copied yet"
        }
        let store = self.store
        panel.loadBlob = { item, blob in store?.data(item.id, blob) }
        panel.show(items, emptyMessage: message)
        Log.shared.info("clipboard", "panel.show", ["items": .number(Double(items.count))])
    }

    private func makePanel() -> ClipboardPanelController {
        let panel = ClipboardPanelController()
        panel.onPaste = { [weak self, weak panel] item, plain in
            panel?.close()
            do {
                try self?.paste(item, plain: plain, via: "panel")
            } catch {
                NSSound.beep()
                Log.shared.warn("clipboard", "paste.failed", ["kind": .string(item.kind.rawValue), "error": .string(String(describing: error))])
            }
        }
        panel.onTogglePin = { [weak self] item in
            self?.setPinned(item, !item.pinned, via: "panel")
        }
        panel.onDelete = { [weak self] item in
            self?.delete(item, via: "panel")
        }
        return panel
    }

    /// Puts an item on the pasteboard and, unless `paste` is false, sends ⌘V to the frontmost app.
    private func paste(_ item: ClipboardItem, plain: Bool, via: String, paste: Bool = true) throws {
        guard let store else { throw Self.disabledError }
        let count = try PasteboardIO.write(item, from: store, plain: plain)
        monitor.ignore(count)
        store.touch(item.id)
        historyChanged()
        let action = paste ? "paste" : "copy"
        Log.shared.info("clipboard", action, ["kind": .string(plain ? "plain" : item.kind.rawValue), "bytes": .number(Double(item.byteSize)),
                                             "via": .string(via)])
        guard paste else { return }
        if context.isAccessibilityTrusted {
            context.paste(after: 0.08)
        } else {
            Log.shared.warn("clipboard", "paste.no_accessibility")
            context.notify(title: "Copied to the clipboard", body: "Lodestone needs Accessibility access to paste for you. Press ⌘V to paste.")
        }
    }

    private func setPinned(_ item: ClipboardItem, _ pinned: Bool, via: String) {
        guard store?.setPinned(item.id, pinned) == true else { return }
        Log.shared.info("clipboard", pinned ? "pin" : "unpin", ["kind": .string(item.kind.rawValue), "via": .string(via)])
        historyChanged()
    }

    private func delete(_ item: ClipboardItem, via: String) {
        guard store?.delete(item.id) != nil else { return }
        Log.shared.info("clipboard", "delete", ["kind": .string(item.kind.rawValue), "bytes": .number(Double(item.byteSize)), "via": .string(via)])
        historyChanged()
    }

    @discardableResult
    private func clear(keepPinned: Bool, via: String) -> Int {
        let removed = store?.clear(keepPinned: keepPinned) ?? 0
        Log.shared.info("clipboard", "clear", ["removed": .number(Double(removed)), "keepPinned": .bool(keepPinned), "via": .string(via)])
        historyChanged()
        return removed
    }

    /// Replaces the clipboard with its plain text, pastes, then (by default) puts the original back.
    private func pastePlain(via: String) {
        let pb = NSPasteboard.general
        guard let text = PasteboardIO.plainText(pb), !text.isEmpty else {
            NSSound.beep()
            Log.shared.info("clipboard", "pastePlain.no_text", ["types": .number(Double(pb.types?.count ?? 0))])
            return
        }
        guard context.isAccessibilityTrusted else {
            Log.shared.warn("clipboard", "paste.no_accessibility")
            context.notify(title: "Can't paste", body: "Lodestone needs Accessibility access to paste. Open Settings → General.")
            return
        }
        let restore = context.settings.bool(Self.restoreKey)
        let snapshot = restore ? PasteboardSnapshot(pb) : nil
        let plainCount = PasteboardIO.setText(text, pb, transient: restore)
        monitor.ignore(plainCount)
        context.paste(after: 0.05)
        Log.shared.info("clipboard", "paste", ["kind": "plain", "chars": .number(Double(text.count)), "restore": .bool(restore), "via": .string(via)])
        guard let snapshot, !snapshot.isEmpty else { return }
        // The target app reads the pasteboard when it handles ⌘V; give it time before restoring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard pb.changeCount == plainCount else {
                Log.shared.info("clipboard", "pastePlain.restore_skipped", ["reason": "clipboard changed"])
                return
            }
            self?.monitor.ignore(snapshot.restore(pb))
        }
    }

    private func pauseHistory(minutes: Double?) {
        resumeTimer?.invalidate()
        resumeTimer = nil
        if let minutes {
            let until = Date().addingTimeInterval(minutes * 60)
            pause = .until(until)
            let timer = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume(automatic: true) }
            }
            RunLoop.main.add(timer, forMode: .common)
            resumeTimer = timer
        } else {
            pause = .indefinitely
        }
        update()
        Log.shared.info("clipboard", "pause", ["minutes": minutes.map { .number($0) } ?? .null])
    }

    private func resume(automatic: Bool = false) {
        guard isPaused else { return }
        resumeTimer?.invalidate()
        resumeTimer = nil
        pause = .none
        update()
        Log.shared.info("clipboard", "resume", ["automatic": .bool(automatic)])
    }

    private func confirmClear() {
        guard let store else { return }
        let pinned = store.items.filter(\.pinned).count
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = pinned > 0
            ? "Removes \(store.items.count - pinned) items. \(pinned) pinned item\(pinned == 1 ? " is" : "s are") kept."
            : "Removes \(store.items.count) items."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        let includePinned = NSButton(checkboxWithTitle: "Also remove pinned items", target: nil, action: nil)
        if pinned > 0 { alert.accessoryView = includePinned }
        context.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        clear(keepPinned: includePinned.state != .on, via: "menu")
    }

    // MARK: Menu & Settings

    func menuItems() -> [NSMenuItem] {
        var items = [context.menuItem(Self.historyCommand), context.menuItem(Self.pastePlainCommand)]
        guard enabled else { return items }
        switch pause {
        case .none:
            items.append(NSMenuItem(title: "Pause Clipboard History", submenu: [
                NSMenuItem(title: "For 15 Minutes") { [weak self] in self?.pauseHistory(minutes: 15) },
                NSMenuItem(title: "For 1 Hour") { [weak self] in self?.pauseHistory(minutes: 60) },
                NSMenuItem(title: "Until Resumed") { [weak self] in self?.pauseHistory(minutes: nil) },
            ]))
        case .indefinitely:
            items.append(NSMenuItem(title: "Resume Clipboard History") { [weak self] in self?.resume() })
        case .until(let date):
            let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
            items.append(NSMenuItem(title: "Resume Clipboard History (paused until \(time))") { [weak self] in self?.resume() })
        }
        let clear = NSMenuItem(title: "Clear Clipboard History…") { [weak self] in self?.confirmClear() }
        clear.isEnabled = !(store?.items.isEmpty ?? true)
        items.append(clear)
        return items
    }

    func makeSettingsView() -> NSView? {
        ClipboardSettingsView.make(context, stats: { [weak self] in
            guard let store = self?.store else { return nil }
            return (store.items.count, store.totalBytes)
        }, clear: { [weak self] in self?.confirmClear() })
    }

    // MARK: IPC

    static let disabledError = IPCError("disabled", "Clipboard history is off. Turn it on with `lodestone settings set clipboard.enabled true`.")

    private struct ItemInfo: Encodable {
        var id: String
        var position: Int
        var kind: String
        var title: String
        var text: String?
        var textTruncated: Bool
        var files: [String]?
        var imageWidth: Int?
        var imageHeight: Int?
        var bytes: Int
        var sourceApp: String?
        var sourceBundleID: String?
        var date: Date
        var pinned: Bool

        init(_ item: ClipboardItem, position: Int) {
            id = item.id
            self.position = position
            kind = item.kind.rawValue
            title = item.title
            text = item.kind == .image || item.kind == .files ? nil : item.text
            textTruncated = item.textTruncated
            files = item.kind == .files ? item.filePaths : nil
            imageWidth = item.imageWidth
            imageHeight = item.imageHeight
            bytes = item.byteSize
            sourceApp = item.sourceApp
            sourceBundleID = item.sourceBundleID
            date = item.date
            pinned = item.pinned
        }
    }

    private struct Status: Encodable {
        var enabled: Bool
        var paused: Bool
        var pausedUntil: Date?
        var persistent: Bool
        var items: Int
        var pinned: Int
        var bytes: Int
        var maxItems: Int
        var maxBytes: Int
        var directory: String
    }

    private struct HistoryParams: Decodable { var limit: Int?; var search: String? }
    private struct ItemParams: Decodable { var id: String; var plain: Bool? }
    private struct PinParams: Decodable { var id: String; var pinned: Bool? }
    private struct ClearParams: Decodable { var includePinned: Bool? }
    private struct PauseParams: Decodable { var minutes: Double? }

    private func status() -> Status {
        let items = store?.items ?? []
        var until: Date?
        if case .until(let d) = pause { until = d }
        return Status(enabled: enabled, paused: isPaused, pausedUntil: until, persistent: context.settings.bool(Self.persistKey),
                      items: items.count, pinned: items.filter(\.pinned).count, bytes: store?.totalBytes ?? 0,
                      maxItems: limits.maxItems, maxBytes: limits.maxBytes, directory: storeDirectory.path)
    }

    private func requireStore() throws -> ClipboardStore {
        guard enabled, let store else { throw Self.disabledError }
        return store
    }

    private func resolve(_ ref: String) throws -> (ClipboardItem, Int) {
        let store = try requireStore()
        guard let item = store.resolve(ref), let index = store.items.firstIndex(where: { $0.id == item.id }) else {
            throw IPCError.notFound("No clipboard item '\(ref)'. Run `lodestone clipboard history` to list ids.")
        }
        return (item, index + 1)
    }

    func registerIPC(_ router: IPCRouter) {
        let idDoc = #""id": string (id, unique id prefix, or position: "1" is the newest)"#

        router.register("clipboard.status", summary: "Whether clipboard history is on or paused, with its size", NoParams.self) { [weak self] _ in
            guard let self else { throw IPCError.failed("Unavailable") }
            return self.status()
        }

        router.register("clipboard.history", summary: "Clipboard history, newest first",
                        params: #"{"limit"?: int, "search"?: string}"#, HistoryParams.self) { [weak self] p -> [ItemInfo] in
            guard let self else { return [] }
            let store = try self.requireStore()
            let all = store.items
            let positions = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, $0 + 1) })
            var items = p.search.map { store.search($0) } ?? all
            if let limit = p.limit, limit >= 0 { items = Array(items.prefix(limit)) }
            return items.map { ItemInfo($0, position: positions[$0.id] ?? 0) }
        }

        router.register("clipboard.paste", summary: "Paste a history item into the frontmost app",
                        params: "{" + idDoc + #", "plain"?: bool}"#, ItemParams.self) { [weak self] p -> ItemInfo in
            guard let self else { throw IPCError.failed("Unavailable") }
            let (item, position) = try self.resolve(p.id)
            guard self.context.isAccessibilityTrusted else {
                throw IPCError.permission("Pasting needs Accessibility access (System Settings → Privacy & Security → Accessibility). `lodestone clipboard copy` works without it.")
            }
            try self.paste(item, plain: p.plain ?? false, via: "ipc")
            return ItemInfo(item, position: position)
        }

        router.register("clipboard.copy", summary: "Put a history item on the clipboard without pasting",
                        params: "{" + idDoc + #", "plain"?: bool}"#, ItemParams.self) { [weak self] p -> ItemInfo in
            guard let self else { throw IPCError.failed("Unavailable") }
            let (item, position) = try self.resolve(p.id)
            try self.paste(item, plain: p.plain ?? false, via: "ipc", paste: false)
            return ItemInfo(item, position: position)
        }

        router.register("clipboard.pin", summary: "Pin (or with pinned: false, unpin) a history item; pinned items are never evicted",
                        params: "{" + idDoc + #", "pinned"?: bool}"#, PinParams.self) { [weak self] p -> ItemInfo in
            guard let self else { throw IPCError.failed("Unavailable") }
            let (item, position) = try self.resolve(p.id)
            let pinned = p.pinned ?? true
            self.setPinned(item, pinned, via: "ipc")
            var updated = item
            updated.pinned = pinned
            return ItemInfo(updated, position: position)
        }

        router.register("clipboard.delete", summary: "Delete a history item", params: "{" + idDoc + "}", ItemParams.self) { [weak self] p -> ItemInfo in
            guard let self else { throw IPCError.failed("Unavailable") }
            let (item, position) = try self.resolve(p.id)
            self.delete(item, via: "ipc")
            return ItemInfo(item, position: position)
        }

        router.register("clipboard.clear", summary: "Delete history items (pinned ones are kept unless includePinned)",
                        params: #"{"includePinned"?: bool}"#, ClearParams.self) { [weak self] p -> JSONValue in
            guard let self else { throw IPCError.failed("Unavailable") }
            _ = try self.requireStore()
            return ["removed": .number(Double(self.clear(keepPinned: !(p.includePinned ?? false), via: "ipc")))]
        }

        router.register("clipboard.pause", summary: "Stop recording copies, for some minutes or until resumed",
                        params: #"{"minutes"?: number}"#, PauseParams.self) { [weak self] p in
            guard let self else { throw IPCError.failed("Unavailable") }
            _ = try self.requireStore()
            if let m = p.minutes, m <= 0 { throw IPCError.invalidParams("minutes must be positive") }
            self.pauseHistory(minutes: p.minutes)
            return self.status()
        }

        router.register("clipboard.resume", summary: "Resume recording copies", NoParams.self) { [weak self] _ in
            guard let self else { throw IPCError.failed("Unavailable") }
            self.resume()
            return self.status()
        }
    }
}
