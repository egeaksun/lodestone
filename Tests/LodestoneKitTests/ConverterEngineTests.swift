import Foundation
import ImageIO
import LodestoneCore
@testable import LodestoneKit
import UniformTypeIdentifiers
import XCTest

final class ConverterEngineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lodestone-convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A 400×300 JPEG with GPS data and the given EXIF orientation.
    private func makeJPEG(_ name: String, orientation: Int = 1) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 41.0, kCGImagePropertyGPSLatitudeRef: "N"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func properties(_ url: URL) -> [CFString: Any] {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
    }

    func testProbeDetectsImages() async throws {
        let jpeg = try makeJPEG("a.jpg", orientation: 6)
        let probed = try await MediaProbe.probe(jpeg)
        XCTAssertEqual(probed.kind, .image)
        XCTAssertEqual(probed.image?.orientation, 6)
        XCTAssertTrue(probed.image!.orientedSize == (300, 400))
        XCTAssertEqual(probed.image?.sameFormat, .jpeg)
        XCTAssertEqual(MediaProbe.quickKind(URL(fileURLWithPath: "/x/y.MOV")), .video)
        XCTAssertEqual(MediaProbe.quickKind(URL(fileURLWithPath: "/x/y.flac")), .audio)
        do {
            _ = try await MediaProbe.probe(dir.appendingPathComponent("missing.jpg"))
            XCTFail("expected not_found")
        } catch let error as IPCError {
            XCTAssertEqual(error.code, "not_found")
        }
    }

    func testResizeAppliesOrientationAndStripsGPS() async throws {
        let jpeg = try makeJPEG("rot.jpg", orientation: 6)
        let request = ConvertRequest(inputs: [jpeg], target: ConvertTarget(format: .png, preset: "resize-50",
                                                                          overrides: ConvertOptions(stripMetadata: true)))
        let results = await Converter(presets: PresetStore(url: dir.appendingPathComponent("p.json"))).convert(request)
        let result = try XCTUnwrap(try results.first?.get())
        XCTAssertEqual(result.engine, .imageio)
        let props = properties(URL(fileURLWithPath: result.output))
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 150)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 200)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
    }

    func testStripMetadataIsLosslessAndKeepsOrientation() async throws {
        let jpeg = try makeJPEG("photo.jpg", orientation: 6)
        let converter = Converter(presets: PresetStore(url: dir.appendingPathComponent("p.json")))
        let plans = await converter.plan(ConvertRequest(inputs: [jpeg], target: ConvertTarget(preset: "strip-metadata")))
        let plan = try plans[0].get()
        XCTAssertTrue(plan.remux, "same format, no resize: metadata removed without re-encoding")
        XCTAssertEqual(plan.output.lastPathComponent, "photo (converted).jpg")
        let result = try await converter.run(plan)
        let props = properties(URL(fileURLWithPath: result.output))
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int, 6)
    }

    func testBatchReservesNamesAndReportsFailures() async throws {
        let a = try makeJPEG("same.jpg")
        let b = dir.appendingPathComponent("sub/same.jpg")
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: a, to: b)
        let out = dir.appendingPathComponent("out")
        let missing = dir.appendingPathComponent("nope.png")
        let request = ConvertRequest(inputs: [a, b, missing], target: ConvertTarget(format: .heic), outputDirectory: out)
        let results = await Converter(presets: PresetStore(url: dir.appendingPathComponent("p.json"))).convert(request)
        XCTAssertEqual(try results[0].get().output, out.appendingPathComponent("same.heic").path)
        XCTAssertEqual(try results[1].get().output, out.appendingPathComponent("same (converted).heic").path)
        guard case .failure(let failure) = results[2] else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.error.code, "not_found")
        XCTAssertEqual(failure.input, missing)
    }

    func testPresetKindMismatchIsAnError() async throws {
        let jpeg = try makeJPEG("x.jpg")
        let plans = await Converter(presets: PresetStore(url: dir.appendingPathComponent("p.json")))
            .plan(ConvertRequest(inputs: [jpeg], target: ConvertTarget(preset: "balanced")))
        guard case .failure(let failure) = plans[0] else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.error.code, "invalid_params")
    }

    func testPresetStore() throws {
        let store = PresetStore(url: dir.appendingPathComponent("presets.json"))
        XCTAssertTrue(store.custom().isEmpty)
        let saved = try store.save(name: "Web Clips", kind: .video, format: .mp4, options: ConvertOptions(quality: 45))
        XCTAssertEqual(saved.id, "web-clips")
        XCTAssertEqual(store.find("web clips")?.options.quality, 45)
        XCTAssertFalse(store.find("web-clips")!.builtIn)
        // Saving the same name replaces it.
        try store.save(name: "Web Clips", kind: .video, format: nil, options: ConvertOptions(quality: 50))
        XCTAssertEqual(store.custom().count, 1)
        XCTAssertEqual(store.find("web-clips")?.options.quality, 50)
        XCTAssertThrowsError(try store.save(name: "Balanced", kind: .video, format: nil, options: ConvertOptions()))
        XCTAssertThrowsError(try store.delete("balanced"))
        try store.delete("web-clips")
        XCTAssertTrue(store.custom().isEmpty)
    }
}
