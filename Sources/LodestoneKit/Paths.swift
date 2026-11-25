import Foundation

/// File locations shared by the app and the CLI.
public enum Paths {
    public static let bundleIdentifier = "app.lodestone.Lodestone"

    /// ~/Library/Application Support/Lodestone
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("Lodestone", isDirectory: true))
    }

    /// ~/Library/Logs/Lodestone, one JSON Lines file per day.
    public static var logs: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("Logs/Lodestone", isDirectory: true))
    }

    /// ~/Library/Caches/app.lodestone.Lodestone, for temporary files (screen captures, intermediate media).
    public static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent(bundleIdentifier, isDirectory: true))
    }

    /// The IPC socket. Kept short: Unix socket paths are limited to 104 bytes.
    public static var socket: URL { appSupport.appendingPathComponent("ipc.sock") }

    /// The CLI is installed by linking this name into a directory on PATH.
    public static let cliName = "lodestone"
    public static var cliLink: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/\(cliName)")
    }

    @discardableResult
    public static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }
}
