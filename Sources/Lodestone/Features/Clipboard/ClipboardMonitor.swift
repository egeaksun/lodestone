import AppKit

/// Watches the general pasteboard for changes.
///
/// macOS posts no notification when the pasteboard changes, so the only way to notice a copy is to
/// poll `NSPasteboard.changeCount`. Each tick compares one integer; reading the contents happens only
/// when it changed. The timer exists only while history is on and not paused.
@MainActor
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount = 0
    /// Change counts of Lodestone's own writes (pasting from history, paste as plain text), which
    /// must not be recorded as new copies.
    private var ownChanges: [Int] = []
    var onChange: ((Int) -> Void)?

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        // Whatever is on the pasteboard now was copied before recording started (or while paused).
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        ownChanges.removeAll()
    }

    /// Marks a pasteboard change as made by Lodestone.
    func ignore(_ changeCount: Int) {
        guard isRunning else { return }
        ownChanges.append(changeCount)
        if ownChanges.count > 8 { ownChanges.removeFirst() }
    }

    private func tick() {
        let count = NSPasteboard.general.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if let i = ownChanges.firstIndex(of: count) {
            ownChanges.remove(at: i)
            return
        }
        onChange?(count)
    }
}
