import XCTest
import Darwin
@testable import VeloraCore

final class HTTPServerTests: XCTestCase {
    func testIdleSocketsDoNotBlockAPlayerRequest() async throws {
        try await withServer { _, port, token in
            let idle = try (0..<24).map { _ in try TestSocket(port: port) }
            defer { idle.forEach { $0.close() } }
            try await Task.sleep(for: .milliseconds(100))

            let player = try TestSocket(port: port)
            defer { player.close() }
            try player.send("GET /\(token)/master.m3u8 HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let response = try player.readResponse()
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
            XCTAssertTrue(response.contains("#EXTM3U"))
        }
    }

    func testRequestHalfCloseStillReceivesItsResponse() async throws {
        try await withServer(responseHandler: { _ in
            try? await Task.sleep(for: .milliseconds(50))
            return .message(200, "Complete response")
        }) { _, port, _ in
            let player = try TestSocket(port: port)
            defer { player.close() }
            try player.send("GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n")
            try player.finishSending()
            let response = try player.readResponse()
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
            XCTAssertTrue(response.hasSuffix("Complete response"))
        }
    }

    func testIncompleteHeadersExpirePromptly() async throws {
        try await withServer { _, port, _ in
            let idle = try TestSocket(port: port, receiveTimeout: 7)
            defer { idle.close() }
            try idle.send("GET /unfinished HTTP/1.1\r\nHost:")
            let started = Date()
            do {
                let response = try idle.readResponse()
                XCTAssertEqual(response, "")
            }
            catch let error as POSIXError where error.code == .ECONNRESET { }
            XCTAssertLessThan(Date().timeIntervalSince(started), 7)
        }
    }

    func testResetPeerCancelsItsPendingResponse() async throws {
        let started = expectation(description: "Response work started")
        let cancelled = expectation(description: "Abandoned response work cancelled")
        try await withServer(responseHandler: { _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled.fulfill() }
            return .message(200, "Unused")
        }) { _, port, _ in
            let player = try TestSocket(port: port)
            defer { player.close() }
            try player.send("GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n")
            await self.fulfillment(of: [started], timeout: 2)
            try player.reset()
            await self.fulfillment(of: [cancelled], timeout: 2)
        }
    }

    func testStoppingServerCancelsPendingResponses() async throws {
        let started = expectation(description: "Response work started")
        let cancelled = expectation(description: "Stopped server cancelled response work")
        try await withServer(responseHandler: { _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled.fulfill() }
            return .message(200, "Unused")
        }) { server, port, _ in
            let player = try TestSocket(port: port)
            defer { player.close() }
            try player.send("GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n")
            await self.fulfillment(of: [started], timeout: 2)
            server.stop()
            await self.fulfillment(of: [cancelled], timeout: 2)
        }
    }

    func testOnlyAuthenticatedSubtitleSegmentsReceiveAFullScanDeadline() async throws {
        try await withServer(subtitleSourceSize: 20_000_000_000) { server, _, token in
            func request(_ path: String, method: String = "GET") throws -> HTTPRequest {
                try HTTPRequest(Data("\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))
            }
            XCTAssertEqual(server.responseTimeout(for: try request("/\(token)/subtitles/embedded-1/segment-0.vtt")), 4_090)
            XCTAssertEqual(server.responseTimeout(for: try request("/\(token)/subtitles/embedded-1/segment-0.vtt", method: "HEAD")), 4_090)
            for path in ["/wrong/subtitles/embedded-1/segment-0.vtt", "/\(token)/subtitles/unknown/segment-0.vtt",
                         "/\(token)/subtitles/embedded-1/segment-999.vtt", "/\(token)/subtitles/embedded-1/index.m3u8",
                         "/\(token)/segment-0.ts"] {
                XCTAssertEqual(server.responseTimeout(for: try request(path)), 120)
            }
            XCTAssertEqual(server.responseTimeout(for: try request("/\(token)/subtitles/embedded-1/segment-0.vtt", method: "POST")), 120)
        }
    }

    func testVideoResponsesDisableClientCachingForGETRangeAndHEAD() async throws {
        try await withServer(stubVideoEncoder: true) { server, _, token in
            func request(_ method: String = "GET", range: String = "") throws -> HTTPRequest {
                try HTTPRequest(Data("\(method) /\(token)/segment-0.ts HTTP/1.1\r\nHost: localhost\r\n\(range)\r\n".utf8))
            }
            let full = await server.respond(try request())
            XCTAssertEqual(full.status, 200)
            XCTAssertEqual(full.body, Data("epoch-segment".utf8))
            XCTAssertEqual(full.headers["Cache-Control"], "no-store")
            let partial = await server.respond(try request(range: "Range: bytes=0-2\r\n"))
            XCTAssertEqual(partial.status, 206)
            XCTAssertEqual(partial.body, Data("epo".utf8))
            XCTAssertEqual(partial.headers["Cache-Control"], "no-store")
            let head = await server.respond(try request("HEAD"))
            XCTAssertEqual(head.status, 200)
            XCTAssertEqual(head.headers["Cache-Control"], "no-store")
        }
    }

    func testExcessRequestsCloseWithoutDisplacingActiveResponses() async throws {
        let started = expectation(description: "All response slots are occupied")
        started.expectedFulfillmentCount = 24
        started.assertForOverFulfill = true
        let cancelled = expectation(description: "Remaining active responses stop")
        cancelled.expectedFulfillmentCount = 23
        let (releases, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        try await withServer(responseHandler: { request in
            started.fulfill()
            if request.path == "/release" {
                for await _ in releases { break }
                return .message(200, "Active response completed")
            }
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled.fulfill() }
            return .message(200, "Unused")
        }) { server, port, _ in
            let active = try (0..<24).map { index -> TestSocket in
                let socket = try TestSocket(port: port)
                let path = index == 0 ? "/release" : "/blocked-\(index)"
                try socket.send("GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n")
                return socket
            }
            defer { active.forEach { $0.close() } }
            await self.fulfillment(of: [started], timeout: 3)
            for request in ["GET /excess HTTP/1.1\r\nHost: localhost\r\n\r\n", "Malformed request\r\n\r\n"] {
                let excess = try TestSocket(port: port)
                defer { excess.close() }
                do {
                    try excess.send(request)
                    let response = try excess.readResponse()
                    XCTAssertEqual(response, "")
                } catch let error as POSIXError where error.code == .ECONNRESET { }
            }
            release.yield(())
            let completed = try active[0].readResponse()
            XCTAssertTrue(completed.hasPrefix("HTTP/1.1 200 OK\r\n"))
            XCTAssertTrue(completed.hasSuffix("Active response completed"))
            server.stop()
            await self.fulfillment(of: [cancelled], timeout: 2)
        }
    }

    private func withServer(
        responseHandler: (@Sendable (HTTPRequest) async -> HTTPResponse)? = nil,
        subtitleSourceSize: UInt64? = nil,
        stubVideoEncoder: Bool = false,
        _ operation: (StreamHTTPServer, UInt16, String) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("velora-http-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if stubVideoEncoder {
            let executable = root.appendingPathComponent("ffmpeg")
            try "#!/bin/sh\nfor output in \"$@\"; do :; done\nprintf 'epoch-segment' > \"$output\"\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        var streams: [[String: Any]] = [
            ["index": 0, "codec_type": "video", "codec_name": "h264", "width": 16, "height": 16]
        ]
        if let subtitleSourceSize {
            streams.append(["index": 1, "codec_type": "subtitle", "codec_name": "subrip"])
            let source = root.appendingPathComponent("movie.mkv")
            FileManager.default.createFile(atPath: source.path, contents: nil)
            let handle = try FileHandle(forWritingTo: source)
            try handle.truncate(atOffset: subtitleSourceSize)
            try handle.close()
        }
        let json: [String: Any] = ["format": ["duration": "8"], "streams": streams]
        let media = try MediaInfo.decodeProbe(JSONSerialization.data(withJSONObject: json), source: root.appendingPathComponent("movie.mkv"))
        let session = try TranscodeSession(media: media, quality: .hd, tools: MediaTools(directory: root), cacheRoot: root)
        let server: StreamHTTPServer
        if let responseHandler { server = StreamHTTPServer(session: session, responseHandler: responseHandler) }
        else { server = StreamHTTPServer(session: session) }
        do {
            let port = try await server.start()
            try await operation(server, port, session.token)
            server.stop(); await session.stop()
            try? FileManager.default.removeItem(at: root)
        } catch {
            server.stop(); await session.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}

private final class TestSocket {
    private var descriptor: Int32

    init(port: UInt16, receiveTimeout: Int = 2) throws {
        descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(descriptor); descriptor = -1
            throw error
        }
        var timeout = timeval(tv_sec: receiveTimeout, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    func send(_ text: String) throws {
        let data = Array(text.utf8)
        try data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.send(descriptor, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                sent += count
            }
        }
    }

    func readResponse() throws -> String {
        var response = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { return String(decoding: response, as: UTF8.self) }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            response.append(contentsOf: buffer.prefix(count))
        }
    }

    func finishSending() throws {
        guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func reset() throws {
        var reset = linger(l_onoff: 1, l_linger: 0)
        guard setsockopt(descriptor, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        close()
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor); descriptor = -1
    }

    deinit { close() }
}
