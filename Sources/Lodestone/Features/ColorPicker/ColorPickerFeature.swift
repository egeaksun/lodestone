import AppKit
import Carbon.HIToolbox
import LodestoneCore
import LodestoneKit

/// Pick a color anywhere on screen with the system magnifier (`NSColorSampler`, no permission
/// needed) and copy it as hex, CSS or Swift code. The last ten colors stay in the menu.
/// Its settings and shortcut live in the "Screen & Text" tab (`ScreenTextFeature`).
@MainActor
final class ColorPickerFeature: Feature {
    let id = "color"
    let title = "Color Picker"
    let symbol = "eyedropper"

    static let formatKey = "color.format"
    static let pickID = "color.pick"
    /// Recent colors as hex strings, newest first. State, not a setting.
    private static let historyKey = "color.history"

    private var context: AppContext!
    /// Retained while the magnifier is showing.
    private var sampler: NSColorSampler?

    var settings: [SettingDefinition] {
        [SettingDefinition(Self.formatKey, title: "Copy colors as", kind: .choice(ColorFormat.allCases.map(\.rawValue)), default: "hex")]
    }

    var commands: [AppCommand] {
        [AppCommand(Self.pickID, "Pick Color",
                    shortcut: KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | optionKey | shiftKey))) { [weak self] in
            self?.pickAndCopy()
        }]
    }

    func start(_ context: AppContext) {
        self.context = context
    }

    private var format: ColorFormat { ColorFormat(rawValue: context.settings.string(Self.formatKey)) ?? .hex }

    private var history: ColorHistory {
        get { ColorHistory(hexStrings: UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? []) }
        set { UserDefaults.standard.set(newValue.hexStrings, forKey: Self.historyKey) }
    }

    // MARK: Picking

    /// Shows the magnifier; calls back with the clicked color in sRGB, or nil on Esc.
    private func pick(_ completion: @escaping @MainActor (ColorValue?) -> Void) -> Bool {
        guard sampler == nil else { return false }
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { [weak self] color in
            MainActor.assumeIsolated {
                self?.sampler = nil
                guard let rgb = color?.usingColorSpace(.sRGB) else { return completion(nil) }
                let value = ColorValue(red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
                                       blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent))
                self?.history.add(value)
                completion(value)
            }
        }
        return true
    }

    /// Shortcut and menu entry point.
    private func pickAndCopy() {
        let started = pick { [weak self] value in
            guard let self else { return }
            guard let value else {
                Log.shared.info(self.id, "pick.cancelled")
                return
            }
            self.copy(value, as: self.format, via: "shortcut")
        }
        if !started { Log.shared.info(id, "pick.busy") }
    }

    private func copy(_ value: ColorValue, as format: ColorFormat, via: String) {
        let text = value.formatted(format)
        PasteboardIO.setText(text)
        Log.shared.info(id, "copy", ["format": .string(format.rawValue), "via": .string(via)])
        context.toast("Copied \(text)", color: Self.nsColor(value))
    }

    static func nsColor(_ value: ColorValue) -> NSColor {
        NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }

    // MARK: Menu

    func menuItems() -> [NSMenuItem] {
        var items = [context.menuItem(Self.pickID)]
        let colors = history.colors
        guard !colors.isEmpty else { return items }
        var recent: [NSMenuItem] = colors.map { value in
            let formats = ColorFormat.allCases.map { format in
                NSMenuItem(title: value.formatted(format)) { [weak self] in self?.copy(value, as: format, via: "menu") }
            }
            let item = NSMenuItem(title: value.hex, submenu: formats)
            item.image = Self.swatchImage(value)
            return item
        }
        recent.append(.separator())
        recent.append(NSMenuItem(title: "Clear Recent Colors") { [weak self] in
            self?.history = ColorHistory()
            Log.shared.info("color", "history.cleared")
        })
        items.append(NSMenuItem(title: "Recent Colors", submenu: recent))
        return items
    }

    static func swatchImage(_ value: ColorValue) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            nsColor(value).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.stroke()
            return true
        }
    }

    // MARK: IPC

    private struct PickParams: Decodable {
        var format: String?
        var copy: Bool?
    }

    func registerIPC(_ router: IPCRouter) {
        router.register("color.pick", summary: "Show the magnifier and return the color the user clicks (waits; Esc cancels)",
                        params: #"{"format"?: "hex"|"rgb"|"hsl"|"swiftui"|"nscolor"|"uicolor", "copy"?: bool}"#,
                        PickParams.self) { [weak self] p -> JSONValue in
            guard let self else { throw IPCError.failed("Unavailable") }
            var format: ColorFormat?
            if let name = p.format {
                guard let f = ColorFormat(name: name) else {
                    throw IPCError.invalidParams("Unknown format '\(name)'. Use one of: \(ColorFormat.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                format = f
            }
            let value: ColorValue? = try await withCheckedThrowingContinuation { c in
                if !self.pick({ c.resume(returning: $0) }) {
                    c.resume(throwing: IPCError("busy", "The color picker is already showing."))
                }
            }
            guard let value else { throw IPCError("cancelled", "Color picking was cancelled.") }
            if p.copy == true {
                self.copy(value, as: format ?? self.format, via: "ipc")
            } else {
                Log.shared.info(self.id, "pick", ["format": .string((format ?? self.format).rawValue), "via": "ipc"])
            }
            return value.report(format: format)
        }

        router.register("color.history", summary: "Recently picked colors, newest first, in every format", NoParams.self) { [weak self] _ -> JSONValue in
            .array((self?.history.colors ?? []).map { $0.report() })
        }
    }
}
