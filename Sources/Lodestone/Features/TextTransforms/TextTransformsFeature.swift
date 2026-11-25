import AppKit
import LodestoneCore
import LodestoneKit

/// Developer text transforms applied to the clipboard in place: Transform Clipboard ▸ in the menu,
/// and one command per transform (`text.jsonPretty`, ...) with no default shortcut. The CLI runs the
/// same transforms in-process (`lodestone text`). Shortcuts are set in the "Screen & Text" tab.
@MainActor
final class TextTransformsFeature: Feature {
    let id = "text"
    let title = "Text Transforms"
    let symbol = "textformat"

    private var context: AppContext!

    var commands: [AppCommand] {
        TextTransform.allCases.map { transform in
            AppCommand(transform.commandID, transform.title) { [weak self] in self?.apply(transform) }
        }
    }

    func start(_ context: AppContext) {
        self.context = context
    }

    func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for group in TextTransform.groups {
            items.append(NSMenuItem.sectionHeader(title: group.title))
            items.append(contentsOf: group.transforms.map { context.menuItem($0.commandID) })
        }
        return [NSMenuItem(title: "Transform Clipboard", submenu: items)]
    }

    /// Replaces the clipboard's text with the transform's result (count only reports).
    private func apply(_ transform: TextTransform) {
        let pasteboard = NSPasteboard.general
        let input: String
        if transform.takesInput {
            guard let text = pasteboard.string(forType: .string) else {
                Log.shared.info(id, "transform.no_text", ["name": .string(transform.rawValue)])
                context.toast("The clipboard has no text", failure: true)
                return
            }
            input = text
        } else {
            input = ""
        }
        let start = Date()
        do {
            let output = try transform.apply(input)
            let ms = (Date().timeIntervalSince(start) * 1000).rounded()
            if transform.replacesText {
                PasteboardIO.setText(output, pasteboard)
            }
            Log.shared.info(id, "transform", ["name": .string(transform.rawValue), "chars": .number(Double(input.count)), "ms": .number(ms)])
            context.toast(transform.replacesText ? transform.doneMessage : output)
        } catch let error as TextTransformError {
            Log.shared.warn(id, "transform.failed", ["name": .string(transform.rawValue), "error": .string(error.summary)])
            context.toast(error.summary, failure: true)
        } catch {
            Log.shared.error(id, "transform.failed", ["name": .string(transform.rawValue), "error": .string(String(describing: error))])
            context.toast("Couldn't transform the clipboard", failure: true)
        }
    }
}
