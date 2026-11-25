import AppKit
import LodestoneCore
import LodestoneKit
import UniformTypeIdentifiers

/// Pieces the PDF and image tools share: recognizing files, picking them, asking for options, and
/// running a job in the background with menu bar progress.

enum FileKind {
    static func type(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
    }

    static func isPDF(_ url: URL) -> Bool { type(of: url)?.conforms(to: .pdf) == true }

    /// Raster images ImageIO can read (not PDFs or SVG).
    static func isImage(_ url: URL) -> Bool {
        guard let type = type(of: url) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .pdf) && !type.conforms(to: .svg)
    }

    static func allPDFs(_ urls: [URL]) -> Bool { !urls.isEmpty && urls.allSatisfy(isPDF) }
    static func allImages(_ urls: [URL]) -> Bool { !urls.isEmpty && urls.allSatisfy(isImage) }

    /// Finder hands over selections in no useful order; sort by name the way Finder lists them.
    static func byName(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// An open panel for the menu items. Returns nil when cancelled.
    static func pick(_ types: [UTType], multiple: Bool, prompt: String, message: String) -> [URL]? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        panel.prompt = prompt
        panel.message = message
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return panel.urls
    }
}

/// A compact options dialog: an alert with controls and, for options that have a default in
/// Settings, a "Don't ask again" checkbox.
@MainActor
enum OptionsPanel {
    /// Returns true when confirmed. When "Don't ask again" is checked, `askKey` is turned off;
    /// the caller then saves the chosen options as the new defaults.
    static func run(_ context: AppContext, title: String, message: String, accessory: NSView,
                    confirm: String, askKey: String?) -> (confirmed: Bool, dontAskAgain: Bool) {
        let alert = make(title: title, message: message, accessory: accessory, confirm: confirm, askKey: askKey)
        NSApp.activate()
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return (false, false) }
        let dontAsk = askKey != nil && alert.suppressionButton?.state == .on
        if dontAsk, let askKey { try? context.settings.set(askKey, .bool(false)) }
        return (true, dontAsk)
    }

    static func make(title: String, message: String, accessory: NSView, confirm: String, askKey: String?) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        accessory.layoutSubtreeIfNeeded()
        accessory.frame.size = accessory.fittingSize
        alert.accessoryView = accessory
        if askKey != nil {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
        }
        return alert
    }

    /// Label: control rows, labels right-aligned.
    static func form(_ rows: [(String, NSView)], footer: NSView? = nil) -> NSView {
        if rows.isEmpty { return footer ?? NSView() }
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        guard let footer else { return grid }
        let stack = NSStackView(views: [grid, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    static func popup(_ items: [(value: String, title: String)], selected: String) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for item in items {
            popup.addItem(withTitle: item.title)
            popup.lastItem?.representedObject = item.value
        }
        if let i = items.firstIndex(where: { $0.value == selected }) { popup.selectItem(at: i) }
        return popup
    }

    static func note(_ text: String, width: CGFloat = 300) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width
        return label
    }

    static func error(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}

extension NSPopUpButton {
    var selectedValue: String? { selectedItem?.representedObject as? String }
}

/// Runs PDF and image work off the main thread with a cancellable menu bar activity, then reveals
/// or announces the results according to the feature's "afterward" setting.
@MainActor
enum ToolJob {
    struct Outcome: Sendable {
        var files: [URL]
        /// One line for the notification ("Report.pdf: 12 MB → 2 MB").
        var summary: String
    }

    private final class TaskBox: @unchecked Sendable { var task: Task<Void, Never>? }

    static func run(_ context: AppContext, title: String, afterKey: String,
                    work: @escaping @Sendable (_ progress: @escaping ProgressHandler) async throws -> Outcome) {
        let box = TaskBox()
        let activity = context.activities.begin(title) { box.task?.cancel() }
        let progress: ProgressHandler = { value in
            Task { @MainActor in context.activities.update(activity, progress: value) }
        }
        box.task = Task.detached(priority: .userInitiated) {
            let result: Result<Outcome, Error>
            do { result = .success(try await work(progress)) } catch { result = .failure(error) }
            await MainActor.run {
                context.activities.end(activity)
                finish(context, title: title, result: result, afterKey: afterKey)
            }
        }
    }

    private static func finish(_ context: AppContext, title: String, result: Result<Outcome, Error>, afterKey: String) {
        switch result {
        case .success(let outcome):
            let after = AfterJob(rawValue: context.settings.string(afterKey)) ?? .reveal
            if outcome.files.isEmpty {
                // Nothing written (for example, compression didn't help): always say why.
                context.notify(title: title, body: outcome.summary)
                return
            }
            after.perform(context, files: outcome.files, title: title, body: outcome.summary)
        case .failure(let error):
            let ipc = error as? IPCError
            if ipc?.code == "cancelled" || error is CancellationError { return }
            OptionsPanel.error("\(title) failed", ipc?.message ?? error.localizedDescription)
        }
    }
}
