import AppKit
import Darwin
import XCTest
import VeloraCore
@testable import Velora

final class ShutdownTests: XCTestCase {
    @MainActor func testTerminationKeepsTheRunLoopAliveAndRepliesOnceAfterCleanup() async throws {
        let coordinator = TerminationCoordinator(), gate = ShutdownGate()
        var cleanupCount = 0, replyCount = 0
        let shutdown = {
            cleanupCount += 1
            await gate.wait()
        }
        let reply = { replyCount += 1 }

        XCTAssertEqual(coordinator.requestTermination(shutdown: shutdown, reply: reply), .terminateLater)
        try await waitUntil { cleanupCount == 1 }
        XCTAssertEqual(replyCount, 0)
        XCTAssertEqual(coordinator.requestTermination(shutdown: shutdown, reply: reply), .terminateLater)
        XCTAssertEqual(cleanupCount, 1)

        gate.release()
        try await waitUntil { replyCount == 1 }
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(coordinator.requestTermination(shutdown: shutdown, reply: reply), .terminateNow)
        XCTAssertEqual(replyCount, 1)
    }

    @MainActor func testTerminationReapsRunningAndSuspendedWorkersBeforeReplying() async throws {
        for suspended in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VeloraShutdownTest-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let pidFile = directory.appendingPathComponent("pid")
            let runner = MediaProcessRunner()
            // Use one shell process, with no subprocesses, that requires the SIGKILL escalation.
            let worker = Task.detached {
                try runner.run(URL(fileURLWithPath: "/bin/sh"), arguments: [
                    "-c", "trap '' TERM; printf '%s' $$ > \"$1\"; while :; do :; done", "velora-shutdown-test", pidFile.path
                ], timeout: 30)
            }
            do {
                try await waitUntil {
                    guard let value = try? String(contentsOf: pidFile, encoding: .utf8) else { return false }
                    return Int32(value) != nil
                }
                let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
                runner.setSuspended(suspended)
                XCTAssertEqual(kill(pid, 0), 0)

                let coordinator = TerminationCoordinator()
                var replyCount = 0, workerWasReaped = false
                let result = coordinator.requestTermination(shutdown: {
                    await runner.stopAndWait()
                    _ = try? await worker.value
                }, reply: {
                    workerWasReaped = kill(pid, 0) == -1 && errno == ESRCH
                    replyCount += 1
                })
                XCTAssertEqual(result, .terminateLater)
                XCTAssertEqual(replyCount, 0)
                try await waitUntil { replyCount == 1 }
                XCTAssertTrue(workerWasReaped, "Quit must reap the \(suspended ? "suspended" : "running") worker before replying")
                do {
                    _ = try await worker.value
                    XCTFail("Stopped workers must report cancellation")
                } catch is CancellationError { }
            } catch {
                await runner.stopAndWait()
                _ = try? await worker.value
                throw error
            }
        }
    }

    @MainActor func testClosingTheLastWindowRequestsApplicationTermination() {
        XCTAssertTrue(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting for shutdown")
        guard condition() else { throw VeloraError("Timed out waiting for shutdown") }
    }
}

@MainActor
private final class ShutdownGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
