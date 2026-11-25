import CoreGraphics
import Foundation
import LodestoneCore

/// Screen captures through `/usr/sbin/screencapture`, which provides the system's region-selection
/// UI. The capture is attributed to the calling process, so it needs that process's Screen Recording
/// permission: without it the image shows only the wallpaper.
public enum ScreenCapture {
    static let tool = URL(fileURLWithPath: "/usr/sbin/screencapture")

    /// Captures a region to a new PNG in `Paths.caches` and returns its URL; the caller deletes it.
    /// With no `region`, the user drags out a region (or presses Space to pick a window); returns nil
    /// when they press Esc. `region` is in points, origin at the top-left of the main display.
    public static func capture(region: CGRect? = nil) async throws -> URL? {
        let url = Paths.caches.appendingPathComponent("capture-\(UUID().uuidString).png")
        var arguments = ["-x"] // No sound.
        if let region {
            guard region.width >= 1, region.height >= 1 else {
                throw IPCError.invalidParams("The region must be at least 1×1 point")
            }
            arguments.append("-R\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))")
        } else {
            arguments.append("-i")
        }
        arguments.append(url.path)
        let result = try await ProcessRunner.run(tool, arguments)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if region == nil { return nil } // Cancelled with Esc.
            throw IPCError.failed("screencapture failed (status \(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return url
    }
}
