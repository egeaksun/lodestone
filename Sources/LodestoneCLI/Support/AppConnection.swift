import AppKit
import ArgumentParser
import Foundation
import LodestoneCore
import LodestoneKit

/// Connection to the running app. Launches it in the background when it isn't running.
enum AppConnection {
    private static var client: IPCClient?

    /// Calls an IPC method on the app and returns its result.
    static func call(_ method: String, _ params: JSONValue? = nil, launch: Bool = true) throws -> JSONValue {
        try connect(launch: launch).call(method, params)
    }

    /// Calls a method and decodes the result.
    static func call<T: Decodable>(_ method: String, _ params: JSONValue? = nil, as type: T.Type) throws -> T {
        try call(method, params).decode(T.self)
    }

    private static func connect(launch: Bool) throws -> IPCClient {
        if let client { return client }
        do {
            client = try IPCClient()
        } catch let error as IPCError where error.code == "not_running" && launch {
            try launchApp()
            let deadline = Date().addingTimeInterval(10)
            while client == nil {
                if Date() > deadline { throw IPCError("not_running", "Started Lodestone, but it didn't respond within 10 seconds.") }
                Thread.sleep(forTimeInterval: 0.2)
                client = try? IPCClient()
            }
        }
        return client!
    }

    private static func launchApp() throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Paths.bundleIdentifier) else {
            throw IPCError("not_installed", "Lodestone isn't installed. Build it with `make install` in the repo.")
        }
        Log.shared.info("cli", "launch_app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let done = DispatchSemaphore(value: 0)
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            launchError = error
            done.signal()
        }
        done.wait()
        if let launchError { throw IPCError("not_running", "Couldn't start Lodestone: \(launchError.localizedDescription)") }
    }
}
