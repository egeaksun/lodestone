import Foundation
import LodestoneCore
import LodestoneKit

/// Maps IPC method names ("window.snap") to handlers. Features register their methods in
/// `registerIPC`; `lodestone methods` lists everything registered, with each method's summary and
/// parameters, so agents can discover the whole surface.
@MainActor
final class IPCRouter {
    struct Method {
        let name: String
        let summary: String
        /// Human-readable parameter description, e.g. `{"action": string, "app"?: string}`.
        let params: String
        let handler: @MainActor (JSONValue) async throws -> JSONValue
    }

    private(set) var methods: [String: Method] = [:]

    /// Registers a method that takes raw JSON.
    func register(_ name: String, summary: String, params: String = "{}",
                  _ handler: @escaping @MainActor (JSONValue) async throws -> JSONValue) {
        methods[name] = Method(name: name, summary: summary, params: params, handler: handler)
    }

    /// Registers a method with typed, Codable parameters and result.
    func register<P: Decodable, R: Encodable>(_ name: String, summary: String, params: String = "{}",
                                              _ type: P.Type, _ handler: @escaping @MainActor (P) async throws -> R) {
        register(name, summary: summary, params: params) { raw in
            let decoded: P
            do {
                decoded = try raw.decode(P.self)
            } catch {
                throw IPCError.invalidParams("Invalid params for \(name): \(Self.describe(error)). Expected \(params)")
            }
            return try JSONValue(encoding: try await handler(decoded))
        }
    }

    func handle(_ request: IPCRequest) async -> IPCResponse {
        let start = Date()
        guard let method = methods[request.method] else {
            Log.shared.warn("ipc", "unknown_method", ["method": .string(request.method)])
            return IPCResponse(id: request.id, error: .unknownMethod(request.method))
        }
        do {
            let result = try await method.handler(request.params ?? .object([:]))
            Log.shared.info("ipc", "call", ["method": .string(request.method), "ms": .number(Self.ms(since: start))])
            return IPCResponse(id: request.id, result: result)
        } catch let error as IPCError {
            Log.shared.warn("ipc", "call.failed", ["method": .string(request.method), "code": .string(error.code), "error": .string(error.message)])
            return IPCResponse(id: request.id, error: error)
        } catch {
            Log.shared.error("ipc", "call.failed", ["method": .string(request.method), "error": .string(String(describing: error))])
            return IPCResponse(id: request.id, error: .failed(String(describing: error)))
        }
    }

    static func ms(since start: Date) -> Double {
        (Date().timeIntervalSince(start) * 1000).rounded()
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): "missing '\(key.stringValue)'"
        case DecodingError.typeMismatch(_, let c): "wrong type at '\(c.codingPath.map(\.stringValue).joined(separator: "."))'"
        case DecodingError.valueNotFound(_, let c): "missing value at '\(c.codingPath.map(\.stringValue).joined(separator: "."))'"
        case DecodingError.dataCorrupted(let c): c.debugDescription
        default: String(describing: error)
        }
    }
}

/// Parameters for methods that take none.
struct NoParams: Decodable {}

/// A result for methods that only report success.
struct OK: Encodable {
    var ok = true
}
