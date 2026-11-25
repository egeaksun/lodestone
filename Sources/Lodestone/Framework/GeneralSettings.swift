import AppKit
import LodestoneKit
import ServiceManagement

/// The General tab: launch at login, permissions, the command-line tool and the activity log.
@MainActor
final class GeneralSettings {
    private let context: AppContext
    private var loginCheckbox: NSButton!
    private var accessibilityLabel: NSTextField!
    private var accessibilityButton: NSButton!
    private var cliLabel: NSTextField!
    private var cliButton: NSButton!

    init(context: AppContext) {
        self.context = context
    }

    func makeView() -> NSView {
        loginCheckbox = NSButton(checkboxWithTitle: "Launch Lodestone at login", target: nil, action: nil)
        let loginTarget = ClosureTarget { [weak self] in self?.toggleLogin() }
        loginCheckbox.target = loginTarget
        loginCheckbox.action = #selector(ClosureTarget.invoke)
        objc_setAssociatedObject(loginCheckbox!, &Self.key, loginTarget, .OBJC_ASSOCIATION_RETAIN)

        accessibilityLabel = NSTextField(wrappingLabelWithString: "")
        accessibilityLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        accessibilityButton = SettingsUI.button("Open Accessibility Settings…") { Self.openAccessibilitySettings() }

        cliLabel = NSTextField(wrappingLabelWithString: "")
        cliLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cliLabel.preferredMaxLayoutWidth = SettingsUI.width - 56
        cliButton = SettingsUI.button("Install") { [weak self] in self?.toggleCLI() }

        let logs = SettingsUI.button("Open Logs Folder") {
            NSWorkspace.shared.open(Paths.logs)
        }

        let view = SettingsUI.stack([
            loginCheckbox,
            SettingsUI.separator(),
            accessibilityLabel,
            accessibilityButton,
            SettingsUI.separator(),
            SettingsUI.header("Command-line tool"),
            cliLabel,
            cliButton,
            SettingsUI.separator(),
            SettingsUI.header("Activity log"),
            SettingsUI.note("Everything Lodestone does is logged for \(Log.retentionDays) days so problems can be traced. Clipboard and screen text are never logged. Read it with `lodestone logs`."),
            logs,
        ])
        refresh()
        return view
    }

    private static var key = 0

    func refresh() {
        guard loginCheckbox != nil else { return }
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let trusted = AXIsProcessTrusted()
        accessibilityLabel.stringValue = trusted ? "Accessibility access is granted." : "Lodestone needs Accessibility access to move windows and paste."
        accessibilityLabel.textColor = trusted ? .secondaryLabelColor : .systemRed
        accessibilityButton.isHidden = trusted

        let installed = Self.cliInstalledPath
        cliLabel.stringValue = installed.map { "`lodestone` is installed at \($0). Run `lodestone --help` in Terminal." }
            ?? "Installs `lodestone` into ~/.local/bin so scripts and agents can use every Lodestone feature."
        cliButton.title = installed == nil ? "Install" : "Uninstall"
    }

    private func toggleLogin() {
        do {
            if loginCheckbox.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.shared.info("app", "launchAtLogin", ["enabled": .bool(loginCheckbox.state == .on)])
        } catch {
            Log.shared.error("app", "launchAtLogin.failed", .error(error))
        }
        refresh()
    }

    /// Where the CLI link points if it's installed and points into this app.
    static var cliInstalledPath: String? {
        let link = Paths.cliLink.path
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != nil else { return nil }
        return (link as NSString).abbreviatingWithTildeInPath
    }

    static var bundledCLI: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(Paths.cliName)")
    }

    private func toggleCLI() {
        let fm = FileManager.default
        let link = Paths.cliLink
        do {
            if Self.cliInstalledPath != nil {
                try fm.removeItem(at: link)
                Log.shared.info("app", "cli.uninstalled")
            } else {
                try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(at: link, withDestinationURL: Self.bundledCLI)
                Log.shared.info("app", "cli.installed", ["path": .string(link.path)])
            }
        } catch {
            Log.shared.error("app", "cli.install_failed", .error(error))
            NSAlert(error: error).runModal()
        }
        refresh()
    }

    static func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
