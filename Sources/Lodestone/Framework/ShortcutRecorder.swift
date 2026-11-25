import AppKit
import Carbon.HIToolbox
import LodestoneCore

/// A button that shows a shortcut and records a new one when clicked.
///
/// While recording: press a combination with at least one of ⌃⌥⌘ (or a function key) to set it,
/// Delete to clear it, or Escape to cancel. Global shortcuts are suspended during recording so the
/// combination reaches this control instead of moving a window.
final class ShortcutRecorder: NSButton {
    var combo: KeyCombo? { didSet { refresh() } }
    /// Set when the combination could not be registered, usually because another app owns it.
    var isUnavailable = false { didSet { refresh() } }
    var onChange: ((KeyCombo?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var isRecording = false

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() {
        isRecording ? stop() : start()
    }

    private func start() {
        isRecording = true
        onRecordingChange?(true)
        refresh()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] e in
            self?.handle(e)
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                object: window, queue: .main) { [weak self] _ in
            self?.stop()
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
        refresh()
        onRecordingChange?(false)
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        switch e.type {
        case .leftMouseDown:
            // A click anywhere else ends recording; a click on this button is handled by `clicked`.
            if e.window != window || !bounds.contains(convert(e.locationInWindow, from: nil)) { stop() }
            return e
        case .flagsChanged:
            let live = KeyNames.symbols(for: KeyNames.carbonModifiers(e.modifierFlags))
            title = live.isEmpty ? "Type Shortcut…" : live
            return nil
        default:
            break
        }

        let code = Int(e.keyCode)
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty && code == kVK_Escape {
            stop()
            return nil
        }
        if flags.isEmpty && (code == kVK_Delete || code == kVK_ForwardDelete) {
            stop()
            combo = nil
            onChange?(nil)
            return nil
        }
        guard !flags.intersection([.command, .option, .control]).isEmpty || KeyNames.functionKeys.contains(code) else {
            NSSound.beep()
            return nil
        }
        let newCombo = KeyCombo(keyCode: UInt32(code), modifiers: KeyNames.carbonModifiers(flags))
        stop()
        combo = newCombo
        onChange?(newCombo)
        return nil
    }

    private func refresh() {
        let text: String
        if isRecording {
            text = "Type Shortcut…"
        } else if let combo {
            text = KeyNames.display(combo)
        } else {
            text = "Record Shortcut"
        }
        let color: NSColor = isRecording ? .controlAccentColor
            : combo == nil ? .secondaryLabelColor
            : isUnavailable ? .systemRed : .labelColor
        attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
        toolTip = isUnavailable && !isRecording ? "Another app is using this shortcut (is Magnet still running?)" : nil
    }
}
