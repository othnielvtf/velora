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
    private final class Client: @unchecked Sendable {
        let id = UUID()
        let connection: NWConnection
        let acceptedAt = DispatchTime.now().uptimeNanoseconds
        var isReadingHeaders = true
        var deadline: DispatchWorkItem?
        var requestTask: Task<Void, Never>?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let queue = DispatchQueue(label: "app.velora.http")
    private let session: TranscodeSession
    private var listener: NWListener?
    private var connections: [UUID: Client] = [:]
    private let pendingConnectionLimit = 24
    private let responseConnectionLimit = 24
    private let onError: @Sendable (String) -> Void
    private let responseHandler: (@Sendable (HTTPRequest) async -> HTTPResponse)?
    public init(session: TranscodeSession, onError: @escaping @Sendable (String) -> Void = { _ in }) {
        self.session = session; self.onError = onError; responseHandler = nil
    }

    init(session: TranscodeSession, responseHandler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.session = session; self.onError = { _ in }; self.responseHandler = responseHandler
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

    func responseTimeout(for request: HTTPRequest) -> TimeInterval {
        let prefix = "/\(session.token)/"
        guard (request.method == "GET" || request.method == "HEAD"), request.path.hasPrefix(prefix) else { return 120 }
        let parts = request.path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "subtitles",
              let source = session.subtitles.first(where: { $0.id == parts[1] }),
              parts[2].hasPrefix("segment-"), parts[2].hasSuffix(".vtt"),
              let index = Int(parts[2].dropFirst(8).dropLast(4)), (0..<session.timeline.count).contains(index),
              let size = try? source.url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 120 }
        return SubtitleStore.extractionTimeout(fileSize: Int64(size)) + 30
    }

    private func accept(_ connection: NWConnection) {
        // Idle sockets have their own budget, so they cannot occupy the slots
        // needed by the player. Admit new headers by retiring the oldest idle peer.
        let pending = connections.values.filter(\.isReadingHeaders)
        if pending.count >= pendingConnectionLimit, let oldest = pending.min(by: { $0.acceptedAt < $1.acceptedAt }) {
            close(oldest)
        }
        let client = Client(connection); connections[client.id] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .failed, .cancelled: self.close(client)
            default: break
            }
        }
        connection.start(queue: queue)
        setDeadline(for: client, after: 5)
        receiveHeaders(client, accumulated: Data())
    }

    private func setDeadline(for client: Client, after seconds: TimeInterval) {
        client.deadline?.cancel()
        let deadline = DispatchWorkItem { [weak self, weak client] in
            guard let self, let client else { return }
            self.close(client)
        }
        client.deadline = deadline
        queue.asyncAfter(deadline: .now() + seconds, execute: deadline)
    }

    private func close(_ client: Client) {
        guard connections.removeValue(forKey: client.id) != nil else { return }
        client.deadline?.cancel(); client.deadline = nil
        client.requestTask?.cancel(); client.requestTask = nil
        client.connection.cancel()
    }

    private func receiveHeaders(_ client: Client, accumulated: Data) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak client] data, _, complete, error in
            guard let self, let client, self.connections[client.id] != nil else { return }
            guard error == nil else { self.close(client); return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard buffer.count <= 16_384 else { self.send(.message(400, "Headers too large"), head: false, client: client); return }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                do {
                    let request = try HTTPRequest(Data(buffer[..<end.upperBound]))
                    let activeResponses = self.connections.values.filter { !$0.isReadingHeaders }.count
                    guard activeResponses < self.responseConnectionLimit else {
                        self.close(client)
                        return
                    }
                    client.isReadingHeaders = false
                    self.setDeadline(for: client, after: self.responseTimeout(for: request))
                    client.requestTask = Task { [weak self, weak client] in
                        guard let self, let client else { return }
                        let response: HTTPResponse
                        if let handler = self.responseHandler { response = await handler(request) }
                        else { response = await self.respond(request) }
                        guard !Task.isCancelled else { return }
                        self.queue.async { [weak self, weak client] in
                            guard let self, let client, self.connections[client.id] != nil else { return }
                            self.send(response, head: request.method == "HEAD", client: client)
                        }
                    }
                    if !complete { self.monitorPeer(client) }
                } catch { self.send(.message(400, "Malformed request"), head: false, client: client) }
            } else if complete { self.close(client) }
            else { self.receiveHeaders(client, accumulated: buffer) }
        }
    }

    private func monitorPeer(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak client] _, _, complete, error in
            guard let self, let client, self.connections[client.id] != nil else { return }
            if error != nil { self.close(client) }
            // A clean EOF can be a legal shutdown(SHUT_WR): the client may still
            // be waiting to read our response. Only errors abandon its work.
            else if !complete { self.monitorPeer(client) }
        }
    }

    private func send(_ response: HTTPResponse, head: Bool, client: Client) {
        if client.isReadingHeaders {
            let activeResponses = connections.values.filter { !$0.isReadingHeaders }.count
            guard activeResponses < responseConnectionLimit else { close(client); return }
        }
        client.isReadingHeaders = false
        client.deadline?.cancel()
        setDeadline(for: client, after: 120)
        client.connection.send(content: response.serialized(head: head), completion: .contentProcessed { [weak self, weak client] _ in
            guard let self, let client else { return }
            self.close(client)
        })
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
        else if name.hasPrefix("subtitles/") {
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, session.subtitles.contains(where: { $0.id == parts[1] }) else { return .message(404, "Not found") }
            if parts[2] == "index.m3u8" {
                data = Data(session.timeline.playlist(segmentExtension: "vtt").utf8); type = "application/vnd.apple.mpegurl"
            } else if parts[2].hasPrefix("segment-"), parts[2].hasSuffix(".vtt"),
                      let index = Int(parts[2].dropFirst(8).dropLast(4)), (0..<session.timeline.count).contains(index) {
                do { data = try await session.subtitleSegment(trackID: String(parts[1]), index: index); type = "text/vtt; charset=utf-8" }
                catch is CancellationError { return .message(503, "Playback session closed") }
                catch { onError("Subtitles: \(error.localizedDescription)"); return .message(503, "This subtitle track could not be prepared") }
            } else { return .message(404, "Not found") }
        }
        else if name.hasPrefix("segment-"), name.hasSuffix(".ts"),
                let index = Int(name.dropFirst(8).dropLast(3)), (0..<session.timeline.count).contains(index) {
            do { data = try Data(contentsOf: await session.segment(index)); type = "video/mp2t" }
            catch is CancellationError { return .message(503, "Playback session closed") }
            catch { onError(error.localizedDescription); return .message(503, "This video chunk could not be prepared") }
        } else { return .message(404, "Not found") }
        // Audio can be remuxed from a new encoder epoch after a seek while the
        // segment URL stays the same. Receivers must fetch those bytes again.
        let common = ["Accept-Ranges": "bytes", "Cache-Control": type == "video/mp2t" ? "no-store" : "private, max-age=3600"]
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
            for client in Array(self.connections.values) { self.close(client) }
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
