import Foundation

/// The app and the `lodestone` CLI talk over a Unix domain socket, one JSON object per line.
///
/// Request:  {"id": 1, "method": "window.snap", "params": {...}}
/// Response: {"id": 1, "result": {...}}  or  {"id": 1, "error": {"code": "not_found", "message": "..."}}
public struct IPCRequest: Codable, Sendable {
    public var id: Int
    public var method: String
    public var params: JSONValue?

    public init(id: Int, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct IPCResponse: Codable, Sendable {
    public var id: Int
    public var result: JSONValue?
    public var error: IPCError?

    public init(id: Int, result: JSONValue? = nil, error: IPCError? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }
}

/// An error that crosses the IPC boundary. `code` is a stable machine-readable identifier.
public struct IPCError: Error, Codable, Sendable, CustomStringConvertible {
    public var code: String
    public var message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }

    public static func invalidParams(_ message: String) -> IPCError { IPCError("invalid_params", message) }
    public static func notFound(_ message: String) -> IPCError { IPCError("not_found", message) }
    public static func permission(_ message: String) -> IPCError { IPCError("permission_denied", message) }
    public static func failed(_ message: String) -> IPCError { IPCError("failed", message) }
    public static func unknownMethod(_ method: String) -> IPCError {
        IPCError("unknown_method", "Unknown method '\(method)'. Run `lodestone methods` to list them.")
    }
}
