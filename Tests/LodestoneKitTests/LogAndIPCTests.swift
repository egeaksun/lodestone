import Foundation
import LodestoneCore
@testable import LodestoneKit
import XCTest

final class IPCTests: XCTestCase {
    func testRequestResponseRoundTrip() async throws {
        let path = NSTemporaryDirectory() + "lodestone-test-\(getpid()).sock"
        let server = IPCServer(path: path) { request in
            switch request.method {
            case "echo": return IPCResponse(id: request.id, result: request.params)
            default: return IPCResponse(id: request.id, error: .unknownMethod(request.method))
            }
        }
        try server.start()
        defer { server.stop() }

        let client = try IPCClient(path: path)
        XCTAssertEqual(try client.call("echo", ["a": 1]), ["a": 1])
        XCTAssertEqual(try client.call("echo", "second request on the same connection"), "second request on the same connection")
        XCTAssertThrowsError(try client.call("nope")) { error in
            XCTAssertEqual((error as? IPCError)?.code, "unknown_method")
        }
    }

    func testClientReportsNotRunning() {
        XCTAssertThrowsError(try IPCClient(path: NSTemporaryDirectory() + "no-such-socket")) { error in
            XCTAssertEqual((error as? IPCError)?.code, "not_running")
        }
    }
}
