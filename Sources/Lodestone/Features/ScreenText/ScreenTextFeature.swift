import AppKit
import Carbon.HIToolbox
import LodestoneCore
import LodestoneKit

/// Copy text and QR codes from any region of the screen. Also owns the "Screen & Text" Settings
/// tab, which holds the color picker's and text transforms' settings and shortcuts too.
@MainActor
final class ScreenTextFeature: Feature {
    let id = "screen"
    let title = "Screen & Text"
    let symbol = "text.viewfinder"

    static let languagesKey = "screen.ocrLanguages"
    static let accuracyKey = "screen.ocrAccuracy"
    static let whenBothKey = "screen.whenBoth"
    static let toastsKey = "screen.showToasts"
    static let copyTextID = "screen.copyText"
    /// Set once the system's own Screen Recording prompt has been shown; later requests show ours.
    private static let requestedKey = "screen.requestedCapture"

    private var context: AppContext!
    private var capturing = false

    var settings: [SettingDefinition] {
        [
            SettingDefinition(Self.languagesKey, title: "Recognition languages", kind: .string, default: "",
                              help: "Comma-separated codes like en, de, zh-Hant. Empty: detect automatically."),
            SettingDefinition(Self.accuracyKey, title: "Recognition", kind: .choice(["accurate", "fast"]), default: "accurate",
                              help: "fast reads Latin scripts only."),
            SettingDefinition(Self.whenBothKey, title: "When a capture has both text and a code, copy",
                              kind: .choice(OCRPreference.allCases.map(\.rawValue)), default: .string(OCRPreference.code.rawValue)),
            SettingDefinition(Self.toastsKey, title: "Show a confirmation near the pointer", kind: .bool, default: true,
                              help: "After copying text, a color or a transformed clipboard."),
        ]
    }

    var commands: [AppCommand] {
        [AppCommand(Self.copyTextID, "Copy Text from Screen",
                    shortcut: KeyCombo(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey | shiftKey))) { [weak self] in
            self?.copyText()
        }]
    }

    func start(_ context: AppContext) {
        self.context = context
    }

    func menuItems() -> [NSMenuItem] {
        [context.menuItem(Self.copyTextID)]
    }

    // MARK: Capture

    private var options: TextRecognizer.Options {
        let requested = OCRLanguages.parse(context.settings.string(Self.languagesKey))
        let accurate = context.settings.string(Self.accuracyKey) != "fast"
        let resolved = TextRecognizer.resolveLanguages(requested, accurate: accurate)
        if !resolved.unsupported.isEmpty {
            Log.shared.warn(id, "languages.unsupported", ["languages": .array(resolved.unsupported.map { .string($0) })])
        }
        return TextRecognizer.Options(languages: resolved.languages, accurate: accurate)
    }

    /// Shortcut and menu entry point: select a region, recognize it, copy the result.
    private func copyText() {
        guard !capturing else { return }
        guard ensureScreenRecording() else { return }
        capturing = true
        let options = self.options
        let preference = OCRPreference(rawValue: context.settings.string(Self.whenBothKey)) ?? .code
        Task { @MainActor [self] in
            defer { capturing = false }
            do {
                guard let result = try await capture(region: nil, options: options) else {
                    Log.shared.info(id, "capture.cancelled")
                    return
                }
                guard let clip = OCRClipboard(result, preference: preference) else {
                    Log.shared.info(id, "copy.empty", ["ms": .number(result.ms)])
                    context.toast("No text found", failure: true)
                    return
                }
                Self.copy(clip.text)
                Log.shared.info(id, "copy", ["chars": .number(Double(clip.text.count)), "codes": .number(Double(result.codes.count)),
                                             "ms": .number(result.ms), "via": "shortcut"])
                context.toast(clip.message)
            } catch {
                Log.shared.error(id, "copy.failed", .error(error))
                context.toast("Couldn't read the screen", failure: true)
            }
        }
    }

    /// Captures (interactively when `region` is nil), recognizes off the main thread, deletes the
    /// capture. Returns nil when the user cancels.
    private func capture(region: CGRect?, options: TextRecognizer.Options) async throws -> OCRResult? {
        guard let url = try await ScreenCapture.capture(region: region) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return try await Task.detached(priority: .userInitiated) {
            try TextRecognizer.recognize(fileAt: url, options: options)
        }.value
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Permission

    static let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// True if Lodestone may capture the screen. Otherwise asks: the system prompt the first time,
    /// then an alert with a button to System Settings.
    private func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        Log.shared.warn(id, "permission.missing")
        if !UserDefaults.standard.bool(forKey: Self.requestedKey) {
            UserDefaults.standard.set(true, forKey: Self.requestedKey)
            if CGRequestScreenCaptureAccess() { return true }
            return false
        }
        context.activate()
        let alert = NSAlert()
        alert.messageText = "Lodestone needs Screen Recording permission"
        alert.informativeText = """
        To copy text from the screen, turn on Lodestone in System Settings → Privacy & Security → \
        Screen & System Audio Recording, then quit and reopen Lodestone.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.screenRecordingSettingsURL)
        }
        return false
    }

    // MARK: IPC

    private struct Region: Decodable { var x: Double, y: Double, width: Double, height: Double }
    private struct OCRParams: Decodable {
        var region: Region?
        var languages: [String]?
        var fast: Bool?
        var copy: Bool?
    }

    func registerIPC(_ router: IPCRouter) {
        router.register("screen.ocr", summary: "Capture the screen (interactively, or a region) and read its text and codes",
                        params: #"{"region"?: {"x","y","width","height": points, top-left origin}, "languages"?: [string], "fast"?: bool, "copy"?: bool}"#,
                        OCRParams.self) { [weak self] p -> JSONValue in
            guard let self else { throw IPCError.failed("Unavailable") }
            guard CGPreflightScreenCaptureAccess() else {
                throw IPCError.permission("""
                Lodestone needs Screen Recording permission. Turn it on in System Settings → Privacy & Security → \
                Screen & System Audio Recording, then quit and reopen Lodestone.
                """)
            }
            guard !self.capturing else { throw IPCError("busy", "A screen capture is already in progress.") }
            var options = self.options
            if let fast = p.fast { options.accurate = !fast }
            if let languages = p.languages {
                let resolved = TextRecognizer.resolveLanguages(languages, accurate: options.accurate)
                guard resolved.unsupported.isEmpty else {
                    throw IPCError.invalidParams("Vision can't read \(resolved.unsupported.joined(separator: ", ")). Run `lodestone ocr --list-languages`.")
                }
                options.languages = resolved.languages
            }
            let region = p.region.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            self.capturing = true
            defer { self.capturing = false }
            guard let result = try await self.capture(region: region, options: options) else {
                throw IPCError("cancelled", "The capture was cancelled.")
            }
            Log.shared.info(self.id, "ocr", ["chars": .number(Double(result.text.count)), "codes": .number(Double(result.codes.count)),
                                             "ms": .number(result.ms), "via": "ipc"])
            var copied = false
            if p.copy == true, let clip = OCRClipboard(result, preference: OCRPreference(rawValue: self.context.settings.string(Self.whenBothKey)) ?? .code) {
                Self.copy(clip.text)
                copied = true
            }
            guard case .object(var o) = try JSONValue(encoding: result) else { return .null }
            o["copied"] = .bool(copied)
            return .object(o)
        }
    }

    // MARK: Settings

    func makeSettingsView() -> NSView? {
        let accuracy = SettingsUI.popup(context, Self.accuracyKey, labels: ["accurate": "Accurate", "fast": "Fast (Latin scripts only)"])
        let whenBoth = SettingsUI.popup(context, Self.whenBothKey, labels: ["code": "Copy the code", "text": "Copy the text", "both": "Copy both"])
        var formatLabels: [String: String] = [:]
        let sample = ColorValue(red: 1, green: 136.0 / 255, blue: 0)
        for format in ColorFormat.allCases { formatLabels[format.rawValue] = "\(format.title) — \(sample.formatted(format))" }
        let colorFormat = SettingsUI.popup(context, ColorPickerFeature.formatKey, labels: formatLabels)

        let transforms = Self.scrolling(SettingsUI.shortcutGrid(context, groups: TextTransform.groups.map { $0.transforms.map(\.commandID) }))
        transforms.translatesAutoresizingMaskIntoConstraints = false
        transforms.heightAnchor.constraint(equalToConstant: 190).isActive = true
        transforms.widthAnchor.constraint(equalToConstant: SettingsUI.width - 56).isActive = true

        return SettingsUI.stack([
            SettingsUI.header("Copy Text from Screen"),
            SettingsUI.row("Recognition:", accuracy),
            SettingsUI.row("Languages:", SettingsUI.textField(context, Self.languagesKey, placeholder: "Automatic")),
            SettingsUI.note("Comma-separated, for example en, de, zh-Hant. Leave empty to detect the language automatically."),
            SettingsUI.row("Text and a code:", whenBoth),
            SettingsUI.separator(),
            SettingsUI.header("Color Picker"),
            SettingsUI.row("Copy colors as:", colorFormat),
            SettingsUI.separator(),
            SettingsUI.checkbox(context, Self.toastsKey),
            SettingsUI.header("Shortcuts"),
            SettingsUI.shortcutGrid(context, groups: [[Self.copyTextID, ColorPickerFeature.pickID]]),
            SettingsUI.header("Text Transform Shortcuts"),
            SettingsUI.note("Transform Clipboard in the menu bar menu replaces the clipboard's text with the result."),
            transforms,
        ], spacing: 10)
    }

    private static func scrolling(_ view: NSView) -> NSView {
        let document = FlippedView()
        view.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(view)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .lineBorder
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            view.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            view.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
            view.centerXAnchor.constraint(equalTo: document.centerXAnchor),
        ])
        return scroll
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension AppContext {
    /// Confirms an action with a toast near the pointer, unless toasts are turned off in Settings.
    /// Failures beep when toasts are off, so they never pass silently.
    func toast(_ text: String, color: NSColor? = nil, failure: Bool = false) {
        if settings.bool(ScreenTextFeature.toastsKey) {
            Toast.shared.show(text, color: color)
        } else if failure {
            NSSound.beep()
        }
    }
}
