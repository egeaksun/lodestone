import CoreGraphics
import Foundation
import ImageIO
import LodestoneCore

/// Reading and writing images with ImageIO, upright (EXIF orientation applied).
enum ImageLoading {
    struct Loaded {
        var cgImage: CGImage
        /// Size in points (1/72 inch), from the pixel size and the image's DPI (72 when it has none).
        var pointSize: CGSize
    }

    static func load(_ url: URL) throws -> Loaded {
        try ResultFiles.requireFile(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw IPCError("unreadable", "\(url.lastPathComponent) isn't an image macOS can read")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let image: CGImage?
        if orientation == 1 {
            // Unmodified, so Quartz can embed JPEG data in a PDF as is.
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            ] as CFDictionary)
        }
        guard let image else { throw IPCError("unreadable", "Couldn't decode \(url.lastPathComponent)") }
        let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let scale = 72 / (dpi > 0 ? dpi : 72)
        return Loaded(cgImage: image, pointSize: CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale))
    }

    static func write(_ image: CGImage, to url: URL, type: CFString, dpi: Int? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw IPCError("write_failed", "Couldn't create \(url.lastPathComponent)")
        }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let dpi {
            props[kCGImagePropertyDPIWidth] = dpi
            props[kCGImagePropertyDPIHeight] = dpi
        }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw IPCError("write_failed", "Couldn't write \(url.lastPathComponent)")
        }
    }
}
