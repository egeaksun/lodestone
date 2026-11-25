import AppKit

/// A small confirmation near the pointer ("Copied 42 words", a color swatch with its hex) that fades
/// out on its own. It never takes focus and clicks pass through it.
///
/// The window is created on first use and reused. While hidden it has no timers or observers.
@MainActor
final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let swatch = SwatchView()
    private let imageView = NSImageView()
    private var stack: NSStackView!
    /// Incremented on every show, so a fade scheduled by an earlier show doesn't hide a newer one.
    private var generation = 0

    nonisolated static let visibleDuration: TimeInterval = 1.2
    nonisolated static let fadeDuration: TimeInterval = 0.25

    /// Shows `text` near the pointer, with a color swatch or an icon-sized image in front of it.
    /// `point` (screen coordinates) overrides the pointer location.
    func show(_ text: String, color: NSColor? = nil, image: NSImage? = nil, at point: NSPoint? = nil,
              duration: TimeInterval = Toast.visibleDuration) {
        let panel = self.panel ?? makePanel()
        label.stringValue = text
        swatch.color = color
        swatch.isHidden = color == nil
        imageView.image = image
        imageView.isHidden = image == nil || color != nil

        let size = stack.fittingSize
        let frame = NSRect(origin: origin(for: size, near: point ?? NSEvent.mouseLocation, explicit: point != nil), size: size)
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        generation += 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.generation == current else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fadeDuration
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    if self.generation == current { panel.orderOut(nil) }
                }
            })
        }
    }

    /// Hides the toast immediately.
    func hide() {
        generation += 1
        panel?.orderOut(nil)
    }

    /// The panel, for rendering it offscreen in checks.
    var window: NSWindow? { panel }

    /// Below and to the right of the pointer, kept inside the visible frame of the pointer's screen.
    private func origin(for size: NSSize, near point: NSPoint, explicit: Bool) -> NSPoint {
        var origin = NSPoint(x: point.x + 14, y: point.y - 18 - size.height)
        if explicit { return origin }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return origin }
        let visible = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        if origin.x + size.width > visible.maxX { origin.x = point.x - 14 - size.width }
        if origin.y < visible.minY { origin.y = point.y + 18 }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return origin
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 32),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        // Keep confirmations out of screenshots and screen recordings.
        panel.sharingType = .none

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true

        swatch.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([swatch.widthAnchor.constraint(equalToConstant: 18), swatch.heightAnchor.constraint(equalToConstant: 18)])
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([imageView.widthAnchor.constraint(equalToConstant: 18), imageView.heightAnchor.constraint(equalToConstant: 18)])

        stack = NSStackView(views: [swatch, imageView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 14)
        stack.detachesHiddenViews = true

        let background = BackgroundView()
        background.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        self.panel = panel
        return panel
    }
}

/// Rounded, slightly translucent background that follows light and dark mode.
private final class BackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// A rounded color sample with a hairline border, so white and transparent colors stay visible.
private final class SwatchView: NSView {
    var color: NSColor? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let color else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        // A checkerboard under translucent colors.
        if color.alphaComponent < 1 {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSColor.white.setFill(); bounds.fill()
            NSColor(white: 0.8, alpha: 1).setFill()
            let cell: CGFloat = 4
            for row in 0..<Int(bounds.height / cell) + 1 {
                for col in 0..<Int(bounds.width / cell) + 1 where (row + col) % 2 == 0 {
                    NSRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        color.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
