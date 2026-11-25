// Renders Assets/*.svg into the bundle resources: AppIcon.icns and the menu bar template PNGs.
// Usage: swift scripts/render-icons.swift <assets dir> <resources dir>
// Uses AppKit's built-in SVG support (macOS 14+), so no extra tools are needed.
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: render-icons.swift <assets dir> <resources dir>\n".data(using: .utf8)!)
    exit(1)
}
let assets = URL(fileURLWithPath: args[1])
let resources = URL(fileURLWithPath: args[2])

func load(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: assets.appendingPathComponent(name)) else {
        fatalError("cannot load \(name)")
    }
    return image
}

/// Draws `image` into a square bitmap. `shadow` adds the soft drop shadow macOS icons carry under the body.
func png(_ image: NSImage, pixels: Int, shadow: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    if shadow {
        let scale = CGFloat(pixels) / 1024
        context.cgContext.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale,
                                    color: NSColor.black.withAlphaComponent(0.35).cgColor)
    }
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
try fm.createDirectory(at: resources, withIntermediateDirectories: true)

// App icon.
let icon = load("AppIcon.svg")
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try png(icon, pixels: points * scale, shadow: true).write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

// Menu bar template image, 18pt at 1x and 2x. NSImage(named:) pairs the two files automatically.
let menu = load("MenuBarIcon.svg")
try png(menu, pixels: 18, shadow: false).write(to: resources.appendingPathComponent("MenuBarIcon.png"))
try png(menu, pixels: 36, shadow: false).write(to: resources.appendingPathComponent("MenuBarIcon@2x.png"))

print("Rendered AppIcon.icns and MenuBarIcon.png into \(resources.path)")
