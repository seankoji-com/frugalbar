import Darwin
import Foundation
import Synchronization

/// Where the OAuth redirect lands.
public protocol SyncCallbackListener: Sendable {
    var redirectURI: String { get }
    /// The query of the first `GET /`. Cancelling the calling task closes the
    /// listener and throws `SyncSignInError.cancelled`.
    func awaitCallback() async throws -> [String: String]
    func close()
}

/// An ephemeral HTTP listener on `127.0.0.1` at a port the kernel picks.
///
/// Loopback only: binding every interface would put the callback on the
/// local network for the whole sign-in. It serves until the first `GET /`,
/// answers anything else with 404 (browsers ask for `/favicon.ico` on the
/// same origin), and closes on that success, on cancel, or when the sign-in
/// flow's five-minute timeout cancels it.
public final class SyncLoopbackListener: SyncCallbackListener {
    private struct Socket {
        var fd: Int32
        var closed = false
        var cancelled = false
    }

    public let port: UInt16
    private let socket: Mutex<Socket>

    public var redirectURI: String { "http://127.0.0.1:\(port)" }
    public var isClosed: Bool { socket.withLock { $0.closed } }

    public init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SyncSignInError.listenerFailed }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw SyncSignInError.listenerFailed
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        port = UInt16(bigEndian: actual.sin_port)
        socket = Mutex(Socket(fd: fd))
    }

    deinit { close() }

    /// The address the socket is actually bound to, for tests.
    var boundAddress: String? {
        socket.withLock { state -> String? in
            guard !state.closed else { return nil }
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(state.fd, $0, &length) }
            }
            guard result == 0 else { return nil }
            return String(cString: inet_ntoa(address.sin_addr))
        }
    }

    public func close() {
        socket.withLock { state in
            guard !state.closed else { return }
            Darwin.close(state.fd)
            state.closed = true
        }
    }

    public func awaitCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: String], Error>) in
                let thread = Thread { [self] in
                    continuation.resume(with: Result { try self.acceptLoop() })
                }
                thread.name = "frugalbar.sync.loopback"
                thread.start()
            }
        } onCancel: {
            socket.withLock { $0.cancelled = true }
        }
    }

    private func acceptLoop() throws -> [String: String] {
        defer { close() }
        while true {
            let (fd, cancelled, closed) = socket.withLock { ($0.fd, $0.cancelled, $0.closed) }
            if cancelled || closed { throw SyncSignInError.cancelled }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            if let parameters = handle(client: client) { return parameters }
        }
    }

    private func handle(client: Int32) -> [String: String]? {
        defer { Darwin.close(client) }
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var buffer = [UInt8](repeating: 0, count: 8192)
        var received = Data()
        while received.count < 16_384 {
            let count = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            if count <= 0 { break }
            received.append(contentsOf: buffer[0..<count])
            if received.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let text = String(data: received, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first
        else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
              components.path == "/" || components.path.isEmpty
        else {
            respond(client, status: "404 Not Found", body: "Not found")
            return nil
        }
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] { parameters[item.name] = item.value ?? "" }
        respond(client, status: "200 OK", body: "FrugalBar received the sign-in. You can close this tab.")
        return parameters
    }

    private func respond(_ client: Int32, status: String, body: String) {
        let payload = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let bytes = Array(payload.utf8)
        _ = bytes.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
    }
}
