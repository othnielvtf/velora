import Foundation
import Network
import Darwin

public struct ByteRange: Equatable, Sendable {
    public let lower: Int
    public let upper: Int
    public var count: Int { upper - lower + 1 }
    public static func parse(_ header: String, size: Int) throws -> ByteRange {
        guard size > 0, header.hasPrefix("bytes="), !header.contains(",") else { throw VeloraError("Invalid byte range") }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw VeloraError("Invalid byte range") }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { throw VeloraError("Invalid suffix range") }
            return ByteRange(lower: max(0, size - suffix), upper: size - 1)
        }
        guard let lower = Int(parts[0]), lower >= 0, lower < size else { throw VeloraError("Unsatisfiable byte range") }
        let upper: Int
        if parts[1].isEmpty { upper = size - 1 }
        else {
            guard let value = Int(parts[1]), value >= lower else { throw VeloraError("Invalid byte range") }
            upper = min(value, size - 1)
        }
        return ByteRange(lower: lower, upper: upper)
    }
}

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public init(_ data: Data) throws {
        guard data.count <= 16_384, let text = String(data: data, encoding: .utf8) else { throw VeloraError("Invalid HTTP request") }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[2].hasPrefix("HTTP/1."), first[1].hasPrefix("/") else { throw VeloraError("Invalid HTTP request line") }
        method = String(first[0])
        path = String(first[1].split(separator: "?", maxSplits: 1)[0])
        var parsed: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw VeloraError("Invalid HTTP header") }
            parsed[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        headers = parsed
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int = 200, type: String, body: Data, headers: [String: String] = [:]) {
        self.status = status; self.body = body
        self.headers = headers.merging(["Content-Type": type, "Content-Length": "\(body.count)", "Connection": "close"]) { current, _ in current }
    }
    public static func message(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, type: "text/plain; charset=utf-8", body: Data(text.utf8))
    }
    public func serialized(head: Bool) -> Data {
        let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 416: "Range Not Satisfiable", 503: "Service Unavailable"][status] ?? "Error"
        var result = Data("HTTP/1.1 \(status) \(reason)\r\n".utf8)
        for key in headers.keys.sorted() { result.append(Data("\(key): \(headers[key]!)\r\n".utf8)) }
        result.append(Data("\r\n".utf8))
        if !head { result.append(body) }
        return result
    }
}

public final class StreamHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.velora.http")
    private let session: TranscodeSession
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private let onError: @Sendable (String) -> Void
    public init(session: TranscodeSession, onError: @escaping @Sendable (String) -> Void = { _ in }) {
        self.session = session; self.onError = onError
    }

    public func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self, listener] in
                self.listener = listener
                var resolved = false
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    switch state {
                    case .ready:
                        if !resolved, let port = listener?.port?.rawValue { resolved = true; continuation.resume(returning: port) }
                    case .failed(let error):
                        if !resolved { resolved = true; continuation.resume(throwing: error) }
                        else { self?.onError("Local streaming server: \(error.localizedDescription)") }
                    case .cancelled:
                        if !resolved { resolved = true; continuation.resume(throwing: CancellationError()) }
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: self.queue)
            }
        }
    }

    public func url(host: String, port: UInt16) -> URL {
        URL(string: "http://\(host):\(port)/\(session.token)/master.m3u8")!
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 24 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.connections[id] = nil }
            if case .cancelled = state { self?.connections[id] = nil }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 120) { [weak self, weak connection] in
            if self?.connections[id] != nil { connection?.cancel(); self?.connections[id] = nil }
        }
        receive(connection, id: id, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard buffer.count <= 16_384 else { self.send(.message(400, "Headers too large"), head: false, connection: connection); return }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                do {
                    let request = try HTTPRequest(buffer)
                    Task {
                        let response = await self.respond(request)
                        self.queue.async { self.send(response, head: request.method == "HEAD", connection: connection) }
                    }
                } catch { self.send(.message(400, "Malformed request"), head: false, connection: connection) }
            } else if complete || error != nil { connection.cancel(); self.connections[id] = nil }
            else { self.receive(connection, id: id, accumulated: buffer) }
        }
    }

    private func send(_ response: HTTPResponse, head: Bool, connection: NWConnection) {
        connection.send(content: response.serialized(head: head), completion: .contentProcessed { _ in connection.cancel() })
    }

    public func respond(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else {
            var response = HTTPResponse.message(405, "Only GET and HEAD are supported")
            response.headers["Allow"] = "GET, HEAD"; return response
        }
        let prefix = "/\(session.token)/"
        guard request.path.hasPrefix(prefix) else { return .message(404, "Not found") }
        let name = String(request.path.dropFirst(prefix.count))
        let data: Data, type: String
        if name == "master.m3u8" { data = Data(session.masterPlaylist().utf8); type = "application/vnd.apple.mpegurl" }
        else if name == "video.m3u8" { data = Data(session.timeline.playlist().utf8); type = "application/vnd.apple.mpegurl" }
        else if name.hasPrefix("segment-"), name.hasSuffix(".ts"),
                let index = Int(name.dropFirst(8).dropLast(3)), (0..<session.timeline.count).contains(index) {
            do { data = try Data(contentsOf: await session.segment(index)); type = "video/mp2t" }
            catch is CancellationError { return .message(503, "Playback session closed") }
            catch { onError(error.localizedDescription); return .message(503, "This video chunk could not be prepared") }
        } else { return .message(404, "Not found") }
        let common = ["Accept-Ranges": "bytes", "Cache-Control": "private, max-age=3600"]
        if let rangeHeader = request.headers["range"] {
            do {
                let range = try ByteRange.parse(rangeHeader, size: data.count)
                var headers = common; headers["Content-Range"] = "bytes \(range.lower)-\(range.upper)/\(data.count)"
                return HTTPResponse(status: 206, type: type, body: data.subdata(in: range.lower..<(range.upper + 1)), headers: headers)
            } catch {
                var response = HTTPResponse.message(416, "Unsatisfiable range")
                response.headers["Content-Range"] = "bytes */\(data.count)"; return response
            }
        }
        return HTTPResponse(type: type, body: data, headers: common)
    }

    public func stop() {
        queue.async {
            self.listener?.cancel(); self.listener = nil
            self.connections.values.forEach { $0.cancel() }; self.connections.removeAll()
        }
    }
}

public struct LANAddress: Identifiable, Hashable, Sendable {
    public let interface: String
    public let address: String
    public var id: String { "\(interface):\(address)" }
    public var label: String { "\(interface) · \(address)" }
    public static func available() -> [LANAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var result: [LANAddress] = [], cursor = list
        while let node = cursor {
            let entry = node.pointee; cursor = entry.ifa_next
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(LANAddress(interface: name, address: String(cString: host)))
        }
        return result.sorted { ($0.interface == "en0" ? "0" : $0.interface) < ($1.interface == "en0" ? "0" : $1.interface) }
    }
}
