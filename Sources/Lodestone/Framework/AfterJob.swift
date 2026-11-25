import AppKit

/// What happens after a job writes files (converter, PDF and image tools): a per-feature setting.
enum AfterJob: String, CaseIterable {
    case reveal, notify, nothing

    static let labels = ["reveal": "Reveal in Finder", "notify": "Show a notification", "nothing": "Do nothing"]
    static var values: [String] { allCases.map(\.rawValue) }

    /// Reveals `files` or posts `title`/`body`, as chosen.
    @MainActor
    func perform(_ context: AppContext, files: [URL], title: String, body: String) {
        switch self {
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting(files)
        case .notify: context.notify(title: title, body: body)
        case .nothing: break
        }
    }
}
