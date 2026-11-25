import Foundation
import ImageIO
import LodestoneCore
import UniformTypeIdentifiers

/// Image conversion with ImageIO: PNG, JPEG, HEIC, TIFF and GIF, plus the upright, resized PNG that
/// cwebp and avifenc are fed when the source needs rotating or scaling first.
enum ImageEngine {
    static func typeIdentifier(_ format: OutputFormat) -> String? {
        switch format {
        case .png: UTType.png.identifier
        case .jpeg: UTType.jpeg.identifier
        case .heic: UTType.heic.identifier
        case .tiff: UTType.tiff.identifier
        case .gif: UTType.gif.identifier
        default: nil
        }
    }

    /// Whether this Mac's ImageIO can write the format.
    static func canWrite(_ format: OutputFormat) -> Bool {
        guard let type = typeIdentifier(format) else { return false }
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return writable.contains(type)
    }

    /// Whether the conversion changes pixels: a resize, or rotating an image stored sideways.
    static func needsRender(_ info: ImageInfo, options: ConvertOptions) -> Bool {
        info.orientation != 1 || targetSize(info, options: options) != nil
    }

    /// The upright output size, or nil to keep the original size.
    static func targetSize(_ info: ImageInfo, options: ConvertOptions) -> (width: Int, height: Int)? {
        let (w, h) = info.orientedSize
        let fitted = SizeFitting.image(width: w, height: h, limit: options.maxSize)
        return fitted.width == w && fitted.height == h ? nil : fitted
    }

    /// Lossless metadata removal applies when nothing else changes: same format, no resize, no
    /// quality given.
    static func canStripLosslessly(_ info: ImageInfo, format: OutputFormat, options: ConvertOptions) -> Bool {
        options.stripMetadata == true && options.quality == nil && targetSize(info, options: options) == nil
            && typeIdentifier(format) == info.typeIdentifier
    }

    static func convert(input: URL, output: URL, format: OutputFormat, options: ConvertOptions, info: ImageInfo) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw IPCError.failed("Couldn't read \(input.lastPathComponent) as an image.")
        }
        guard let type = typeIdentifier(format),
              let dest = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil) else {
            throw IPCError("unsupported", "This Mac can't write \(format.title) images.")
        }

        if canStripLosslessly(info, format: format, options: options) {
            // Rewrites the container without decoding: no quality loss. The color profile is part of
            // the image data, not the removed metadata.
            // Replaces all metadata with just the orientation, so the photo still displays upright.
            let metadata = CGImageMetadataCreateMutable()
            if info.orientation != 1 {
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation,
                                                             info.orientation as CFNumber)
            }
            let copyOptions: [CFString: Any] = [
                kCGImageDestinationMetadata: metadata,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageMetadataShouldExcludeXMP: true,
            ]
            var error: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(dest, source, copyOptions as CFDictionary, &error) { return }
            Log.shared.info("converter", "strip.lossless_unavailable", ["path": .string(input.path)])
            // Fall through to a re-encode with a fresh destination.
            try? FileManager.default.removeItem(at: output)
            guard let retry = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil) else {
                throw IPCError.failed("Couldn't create \(output.lastPathComponent).")
            }
            try encode(source: source, dest: retry, format: format, options: options, info: info)
            return
        }
        try encode(source: source, dest: dest, format: format, options: options, info: info)
    }

    private static func encode(source: CGImageSource, dest: CGImageDestination, format: OutputFormat, options: ConvertOptions, info: ImageInfo) throws {
        let (image, rendered) = try decode(source: source, info: info, options: options)
        let sourceProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var props: [CFString: Any] = [:]
        if options.stripMetadata != true {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                        kCGImagePropertyTIFFDictionary, kCGImagePropertyExifAuxDictionary] {
                if var dict = sourceProps[key] as? [CFString: Any] {
                    if key == kCGImagePropertyTIFFDictionary { dict[kCGImagePropertyTIFFOrientation] = nil }
                    props[key] = dict
                }
            }
        }
        props[kCGImagePropertyOrientation] = rendered ? 1 : info.orientation
        if format == .tiff {
            var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5 // LZW: lossless, a fraction of the uncompressed size.
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if format == .jpeg || format == .heic {
            props[kCGImageDestinationLossyCompressionQuality] = QualityMapping.imageIO(options.quality ?? 90)
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw IPCError.failed("Couldn't write the \(format.title) file.") }
    }

    /// Decodes the first frame, applying orientation and resizing when needed. `rendered` is true when
    /// the pixels are already upright.
    private static func decode(source: CGImageSource, info: ImageInfo, options: ConvertOptions) throws -> (CGImage, rendered: Bool) {
        if needsRender(info, options: options) {
            let size = targetSize(info, options: options) ?? info.orientedSize
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                throw IPCError.failed("Couldn't decode the image.")
            }
            return (image, true)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw IPCError.failed("Couldn't decode the image.")
        }
        return (image, false)
    }

    /// Writes an upright (and resized) PNG for tools that can't read the source or apply EXIF
    /// orientation. Keeps the color profile.
    static func renderIntermediate(input: URL, to png: URL, options: ConvertOptions, info: ImageInfo) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw IPCError.failed("Couldn't read \(input.lastPathComponent) as an image.")
        }
        guard let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw IPCError.failed("Couldn't create a temporary file in \(png.deletingLastPathComponent().path).")
        }
        var forced = options
        forced.quality = nil
        let (image, _) = try decode(source: source, info: info, options: forced)
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw IPCError.failed("Couldn't write a temporary PNG.") }
    }
}
