import ArgumentParser
import Foundation
import LodestoneCore
import LodestoneKit

/// `lodestone image ...`: image tools that run in this process (no app needed). Format conversion,
/// resizing and compression live under `lodestone convert`.
struct ImageGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Image tools: remove the background behind a subject.",
        subcommands: [RemoveBackground.self])

    struct RemoveBackground: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove-background",
            abstract: "Cut out the subject of a photo and save it as a PNG with a transparent background.",
            discussion: "Uses Vision on this Mac (macOS 14+); nothing is uploaded. Fails with code no_subject when no clear foreground subject is found.")
        @Argument(help: "Images.") var inputs: [String]
        @Flag(help: "Crop the result to the subject.") var crop = false
        @Option(name: .shortAndLong, help: "Output file (one input only) or folder. Default: \"<name> (no background).png\" next to the input.") var output: String?
        @OptionGroup var global: GlobalOptions

        func validate() throws {
            if inputs.isEmpty { throw ValidationError("Give at least one image") }
            if inputs.count > 1, let output, !PDFGroup.isDirectory(fileURL(output)) {
                throw ValidationError("With several inputs, -o must be an existing folder")
            }
        }

        func run() async throws {
            var results: [BackgroundRemovalResult] = []
            for input in inputs {
                results.append(try await BackgroundRemoval.run(fileURL(input), output: output.map(fileURL), crop: crop))
            }
            if global.json {
                print((inputs.count == 1 ? try JSONValue(encoding: results[0]) : try JSONValue(encoding: results)).prettyJSONString)
            } else {
                for r in results {
                    print("\(r.output)  (\(r.width)×\(r.height), \(r.subjects) subject\(r.subjects == 1 ? "" : "s"), \(PDFTools.formatBytes(r.bytes)))")
                }
            }
        }
    }
}
