import Foundation

/// Minimal HTTP-over-unix-socket listener. Hook scripts POST one JSON body per connection.
/// The handler gets the path and body plus a `respond` callback: call it with nil for 204,
/// or with a JSON body for 200. It can be called later (permission prompts wait for you).
final class SocketServer: @unchecked Sendable {
    typealias Respond = @Sendable (Data?) -> Void

    enum ServerError: Error {
        case pathTooLong
        case posix(String, Int32)
    }

    private let path: String
    private let onRequest: @Sendable (_ path: String, _ body: Data, _ respond: @escaping Respond) -> Void
    private var listenFD: Int32 = -1
    private let maxRequestBytes = 4 * 1024 * 1024

    init(path: String, onRequest: @escaping @Sendable (_ path: String, _ body: Data, _ respond: @escaping Respond) -> Void) {
        self.path = path
        self.onRequest = onRequest
    }

    func start() throws {
        unlink(path) // clear a stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.posix("socket", errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else {
            close(fd)
            throw ServerError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8) }

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw ServerError.posix("bind", err)
        }
        chmod(path, 0o600) // only this user can talk to the pet
        guard listen(fd, 32) == 0 else {
            let err = errno
            close(fd)
            throw ServerError.posix("listen", err)
        }

        listenFD = fd
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return // listening socket closed
            }
            DispatchQueue.global(qos: .utility).async { [self] in handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let separator = Data("\r\n\r\n".utf8)
        var bodyStart: Int?
        var contentLength = 0
        var requestPath = "/"

        while buffer.count < maxRequestBytes {
            if let start = bodyStart, buffer.count - start >= contentLength { break }

            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(chunk, count: n)

            if bodyStart == nil, let range = buffer.range(of: separator) {
                bodyStart = range.upperBound
                let header = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                contentLength = Self.contentLength(in: header)
                requestPath = Self.path(in: header)
            }
        }

        let responder = Responder(fd: client)
        guard let start = bodyStart, buffer.count - start >= contentLength, contentLength > 0 else {
            responder.send(nil)
            return
        }
        onRequest(requestPath, buffer.subdata(in: start..<(start + contentLength))) { responder.send($0) }
    }

    /// Writes exactly one HTTP response and closes the connection, however many times it's called.
    private final class Responder: @unchecked Sendable {
        private let fd: Int32
        private let lock = NSLock()
        private var done = false

        init(fd: Int32) { self.fd = fd }

        func send(_ body: Data?) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true

            var response: Data
            if let body {
                response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
            } else {
                response = Data("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8)
            }
            response.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
            close(fd)
        }
    }

    private static func path(in header: String) -> String {
        // "POST /permission HTTP/1.1"
        let parts = header.prefix(while: { $0 != "\r" }).split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : "/"
    }

    private static func contentLength(in header: String) -> Int {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }
}
