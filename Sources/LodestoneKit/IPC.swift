import Foundation
import LodestoneCore

/// Server side of the app <-> CLI connection. The app owns it.
///
/// A blocking accept loop runs on one background thread, so an idle server costs nothing. Each
/// connection is served on its own thread: requests are read line by line and every request is
/// answered with exactly one response line. Handlers run through `handle`, which the app routes.
public final class IPCServer: @unchecked Sendable {
    public typealias Handler = @Sendable (IPCRequest) async -> IPCResponse

    private let path: String
    private let handle: Handler
    private var listenFD: Int32 = -1

    public init(path: String = Paths.socket.path, handle: @escaping Handler) {
        self.path = path
        self.handle = handle
    }

    public func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.failed("socket() failed: \(errno)") }
        var addr = sockaddr_un.make(path: path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0 else {
            close(fd)
            throw IPCError.failed("bind(\(path)) failed: \(String(cString: strerror(errno)))")
        }
        chmod(path, 0o600) // Only this user can connect.
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw IPCError.failed("listen() failed: \(errno)")
        }
        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "lodestone.ipc.accept"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func stop() {
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return // Closed by stop().
            }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let thread = Thread { [handle] in Self.serve(client, handle: handle) }
            thread.name = "lodestone.ipc.client"
            thread.start()
        }
    }

    private static func serve(_ fd: Int32, handle: @escaping Handler) {
        defer { close(fd) }
        let reader = LineReader(fd: fd)
        while let line = reader.next() {
            let response: IPCResponse
            if let request = try? JSONDecoder.lodestone.decode(IPCRequest.self, from: line) {
                let box = ResponseBox()
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    box.value = await handle(request)
                    done.signal()
                }
                done.wait()
                response = box.value ?? IPCResponse(id: request.id, error: .failed("No response"))
            } else {
                response = IPCResponse(id: 0, error: .invalidParams("Malformed request"))
            }
            guard var data = try? JSONEncoder.lodestone.encode(response) else { return }
            data.append(0x0A)
            guard writeAll(fd, data) else { return }
        }
    }
}

private final class ResponseBox: @unchecked Sendable {
    var value: IPCResponse?
}

/// Client side, used by the CLI. One connection per process; requests are sent sequentially.
public final class IPCClient {
    private let fd: Int32
    private let reader: LineReader
    private var nextID = 1

    /// Connects to a running app. Throws `IPCError("not_running", ...)` when nothing is listening.
    public init(path: String = Paths.socket.path) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.failed("socket() failed") }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un.make(path: path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) } }
        guard ok == 0 else {
            close(fd)
            throw IPCError("not_running", "Lodestone isn't running.")
        }
        self.fd = fd
        reader = LineReader(fd: fd)
    }

    deinit { close(fd) }

    /// Sends one request and waits for its response. Throws the server's error, if any.
    public func call(_ method: String, _ params: JSONValue? = nil) throws -> JSONValue {
        let request = IPCRequest(id: nextID, method: method, params: params)
        nextID += 1
        var data = try JSONEncoder.lodestone.encode(request)
        data.append(0x0A)
        guard writeAll(fd, data) else { throw IPCError.failed("Lost connection to Lodestone") }
        guard let line = reader.next() else { throw IPCError.failed("Lodestone closed the connection") }
        let response = try JSONDecoder.lodestone.decode(IPCResponse.self, from: line)
        if let error = response.error { throw error }
        return response.result ?? .null
    }
}

/// Reads newline-delimited messages from a socket.
final class LineReader {
    private let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    func next() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += n
        }
        return true
    }
}

extension sockaddr_un {
    static func make(path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(103))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }
}
