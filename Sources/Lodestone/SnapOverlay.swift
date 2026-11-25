import AppKit

/// Snap preview: one reusable borderless window, drawn by Core Animation. No blur (a full-screen
/// backdrop blur is the most expensive thing a preview can do), no animation, and nothing is redrawn
/// unless the target rectangle changes.
final class SnapOverlay {
    private var current: CGRect?

    private lazy var window: NSWindow = {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .floating
        w.animationBehavior = .none
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]

        let view = NSView()
        view.wantsLayer = true
        if let layer = view.layer {
            let accent = NSColor.controlAccentColor
            layer.backgroundColor = accent.withAlphaComponent(0.2).cgColor
            layer.borderColor = accent.withAlphaComponent(0.75).cgColor
            layer.borderWidth = 2
            layer.cornerRadius = 12
        }
        w.contentView = view
        return w
    }()

    func show(_ rect: CGRect) {
        let r = rect.insetBy(dx: 6, dy: 6)
        guard r != current else { return }
        window.setFrame(r, display: false)
        if current == nil { window.orderFrontRegardless() }
        current = r
    }

    func hide() {
        guard current != nil else { return }
        window.orderOut(nil)
        current = nil
    }
}
