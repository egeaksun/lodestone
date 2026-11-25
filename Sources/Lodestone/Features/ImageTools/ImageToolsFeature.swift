import AppKit
import LodestoneCore
import LodestoneKit
import UniformTypeIdentifiers

/// Image tools that aren't conversions. For now: remove the background behind a photo's subject
/// (Vision, on device). The CLI runs the same code: `lodestone image remove-background`.
@MainActor
final class ImageToolsFeature: Feature {
    let id = "image"
    let title = "Image"
    let symbol = "person.crop.square.filled.and.at.rectangle"

    static let cropKey = "image.cropToSubject"
    static let askKey = "image.askBackgroundOptions"
    static let afterKey = "image.afterward"

    private var context: AppContext!

    var settings: [SettingDefinition] {
        [
            SettingDefinition(Self.cropKey, title: "Crop to the subject", kind: .bool, default: false,
                              help: "Trim the transparent area around the subject."),
            SettingDefinition(Self.askKey, title: "Ask each time", kind: .bool, default: true),
            SettingDefinition(Self.afterKey, title: "When an image is ready", kind: .choice(AfterJob.allCases.map(\.rawValue)), default: "reveal"),
        ]
    }

    var commands: [AppCommand] {
        [AppCommand("image.removeBackground", "Remove Background") { [weak self] in self?.pickAndRemove() }]
    }

    var fileActions: [FileAction] {
        [FileAction(id: "image.removeBackground", title: "Remove Background", accepts: FileKind.allImages) { [weak self] in self?.removeBackground($0) }]
    }

    func start(_ context: AppContext) {
        self.context = context
    }

    func menuItems() -> [NSMenuItem] {
        [NSMenuItem(title: "Image Tools", submenu: [context.menuItem("image.removeBackground", title: "Remove Background…")])]
    }

    private func pickAndRemove() {
        guard let urls = FileKind.pick([.image], multiple: true, prompt: "Remove Background",
                                       message: "Choose photos. The subject is kept and the background made transparent.") else { return }
        guard FileKind.allImages(urls) else { return NSSound.beep() }
        Log.shared.info("files", "action", ["action": "image.removeBackground", "count": .number(Double(urls.count)), "source": "menu"])
        removeBackground(urls)
    }

    static func cropCheckbox(_ on: Bool) -> NSButton {
        let box = NSButton(checkboxWithTitle: "Crop to the subject", target: nil, action: nil)
        box.state = on ? .on : .off
        return box
    }

    private func removeBackground(_ urls: [URL]) {
        var crop = context.settings.bool(Self.cropKey)
        if context.settings.bool(Self.askKey) {
            let box = Self.cropCheckbox(crop)
            let view = OptionsPanel.form([], footer: box)
            let answer = OptionsPanel.run(context, title: urls.count == 1 ? "Remove the background of \(urls[0].lastPathComponent)" : "Remove the background of \(urls.count) images",
                                          message: "Saved as a PNG with transparency next to the original.",
                                          accessory: view, confirm: "Remove Background", askKey: Self.askKey)
            guard answer.confirmed else { return }
            crop = box.state == .on
            if answer.dontAskAgain { try? context.settings.set(Self.cropKey, .bool(crop)) }
        }
        let inputs = urls
        let cropToSubject = crop
        let title = "Removing background\(inputs.count == 1 ? " of \(inputs[0].lastPathComponent)" : "s of \(inputs.count) images")"
        ToolJob.run(context, title: title, afterKey: Self.afterKey) { progress in
            var files: [URL] = []
            for (i, url) in inputs.enumerated() {
                let r = try await BackgroundRemoval.run(url, crop: cropToSubject)
                files.append(URL(fileURLWithPath: r.output))
                progress(Double(i + 1) / Double(inputs.count))
            }
            return .init(files: files, summary: files.map(\.lastPathComponent).joined(separator: "\n"))
        }
    }

    func makeSettingsView() -> NSView? {
        SettingsUI.stack([
            SettingsUI.header("Remove Background"),
            SettingsUI.checkbox(context, Self.cropKey),
            SettingsUI.checkbox(context, Self.askKey, title: "Ask each time"),
            SettingsUI.note("Works on photos with a clear subject: people, animals, objects. It runs on this Mac; nothing is uploaded. The result is \"Name (no background).png\" next to the original."),
            SettingsUI.separator(),
            SettingsUI.row("When an image is ready:", SettingsUI.popup(context, Self.afterKey, labels: AfterJob.labels)),
            SettingsUI.separator(),
            SettingsUI.shortcutGrid(context, groups: [["image.removeBackground"]]),
        ])
    }

    private struct RemoveParams: Decodable { var path: String; var crop: Bool?; var output: String? }

    func registerIPC(_ router: IPCRouter) {
        router.register("image.removeBackground", summary: "Cut out an image's subject into a transparent PNG (crop defaults to the image.cropToSubject setting)",
                        params: #"{"path": path, "crop"?: bool, "output"?: path}"#, RemoveParams.self) { [weak self] p in
            let crop = p.crop ?? self?.context.settings.bool(Self.cropKey) ?? false
            return try await Task.detached {
                try await BackgroundRemoval.run(PDFToolsFeature.url(p.path), output: p.output.map(PDFToolsFeature.url), crop: crop)
            }.value
        }
    }
}
