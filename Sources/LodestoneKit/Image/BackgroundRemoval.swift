import CoreImage
import Foundation
import LodestoneCore
import Vision

/// Removes the background behind an image's subject (people, animals, objects) with Vision's
/// foreground instance mask, and saves a PNG with transparency.
public enum BackgroundRemoval {
    static let category = "image"

    /// Blocks while Vision works; call off the main thread.
    public static func run(_ input: URL, output: URL? = nil, crop: Bool) async throws -> BackgroundRemovalResult {
        try await LoggedOperation.run(category, "remove_background", ["input": input.logValue, "crop": .bool(crop)]) {
            let image = try ImageLoading.load(input).cgImage
            let destination = try ResultFiles.destination(explicit: output, source: input, tag: "no background", ext: "png")
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let request = VNGenerateForegroundInstanceMaskRequest()
            do {
                try handler.perform([request])
            } catch {
                throw IPCError.failed("Vision couldn't analyze \(input.lastPathComponent): \(error.localizedDescription)")
            }
            try Task.checkCancellation()
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                throw IPCError("no_subject", "No subject found in \(input.lastPathComponent). Background removal needs a clear foreground subject, like a person, animal or object.")
            }
            let buffer: CVPixelBuffer
            do {
                buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: crop)
            } catch {
                throw IPCError.failed("Couldn't cut out the subject of \(input.lastPathComponent): \(error.localizedDescription)")
            }
            let ci = CIImage(cvPixelBuffer: buffer)
            let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            guard let cut = CIContext().createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!) else {
                throw IPCError.failed("Couldn't render the cut-out image")
            }
            let temp = ResultFiles.temporary(ext: "png")
            defer { try? FileManager.default.removeItem(at: temp) }
            try ImageLoading.write(cut, to: temp, type: "public.png" as CFString)
            let final = try ResultFiles.place(temp, at: destination)
            return BackgroundRemovalResult(input: input.path, output: final.path, width: cut.width, height: cut.height, cropped: crop,
                                           subjects: observation.allInstances.count, bytes: ResultFiles.size(final))
        } outcome: { (r: BackgroundRemovalResult) -> [String: JSONValue] in
            ["output": .string(r.output), "width": .number(Double(r.width)), "height": .number(Double(r.height)),
             "subjects": .number(Double(r.subjects)), "bytes": .number(Double(r.bytes))]
        }
    }
}
