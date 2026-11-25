import Foundation
import LodestoneCore

/// Optional command-line tools Lodestone uses for formats macOS can't write (WebP, AVIF, WebM, MP3,
/// FLAC, ...) and for stronger PDF compression.
///
/// Apps launched from Finder don't inherit the shell's PATH, so the usual install locations are
/// searched explicitly, then PATH.
public enum ExternalTool: String, CaseIterable, Sendable {
    case ffmpeg, ffprobe, cwebp, avifenc, gs

    public var installHint: String {
        switch self {
        case .ffmpeg, .ffprobe: "brew install ffmpeg"
        case .cwebp: "brew install webp"
        case .avifenc: "brew install libavif"
        case .gs: "brew install ghostscript"
        }
    }

    private static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    /// The tool's path, or nil if it isn't installed. Cached after the first lookup.
    public var url: URL? {
        ExternalToolCache.shared.lookup(self)
    }

    /// The tool's path, or an error telling the user how to install it.
    public func require() throws -> URL {
        guard let url else {
            throw IPCError("missing_tool", "\(rawValue) is required for this. Install it with: \(installHint)")
        }
        return url
    }

    fileprivate func find() -> URL? {
        let fm = FileManager.default
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in Self.searchDirectories + pathDirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(rawValue)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

private final class ExternalToolCache: @unchecked Sendable {
    static let shared = ExternalToolCache()
    private let lock = NSLock()
    private var cache: [ExternalTool: URL?] = [:]

    func lookup(_ tool: ExternalTool) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[tool] { return cached }
        let found = tool.find()
        cache[tool] = found
        return found
    }
}

/// Runs a command-line tool and collects its output.
public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String
}

public enum ProcessRunner {
    /// Runs `executable` to completion. `onStderrLine` receives stderr line by line (ffmpeg reports
    /// progress there). Cancelling the calling Task terminates the process.
    public static func run(_ executable: URL, _ arguments: [String], onStderrLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector(onStderrLine: onStderrLine)
        out.fileHandleForReading.readabilityHandler = { h in collector.appendOut(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in collector.appendErr(h.availableData) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    collector.appendOut(out.fileHandleForReading.readDataToEndOfFile())
                    collector.appendErr(err.fileHandleForReading.readDataToEndOfFile())
                    continuation.resume(returning: collector.result(status: p.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var pendingLine = Data()
    private let onStderrLine: (@Sendable (String) -> Void)?

    init(onStderrLine: (@Sendable (String) -> Void)?) { self.onStderrLine = onStderrLine }

    func appendOut(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); out.append(data); lock.unlock()
    }

    func appendErr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        err.append(data)
        var lines: [String] = []
        if onStderrLine != nil {
            pendingLine.append(data)
            // ffmpeg ends progress lines with \r, everything else with \n.
            while let i = pendingLine.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: pendingLine[pendingLine.startIndex..<i], as: UTF8.self)
                pendingLine.removeSubrange(pendingLine.startIndex...i)
                if !line.isEmpty { lines.append(line) }
            }
        }
        lock.unlock()
        lines.forEach { onStderrLine?($0) }
    }

    func result(status: Int32) -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }
        return ProcessResult(status: status, stdout: out, stderr: String(decoding: err, as: UTF8.self))
    }
}
