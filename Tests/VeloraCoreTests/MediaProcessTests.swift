import XCTest
import Darwin
@testable import VeloraCore

final class MediaProcessTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    func testCapturesLargeOutputWithoutBlockingOnEitherStream() throws {
        let runner = MediaProcessRunner()
        let value = "0123456789abcdef"
        let output = try runner.run(shell, arguments: ["-c", """
        i=0
        while [ "$i" -lt 8192 ]; do
            printf '%s' "$1"
            printf '%s' "$1" >&2
            i=$((i + 1))
        done
        """, "velora-test", value], timeout: 5)
        XCTAssertEqual(output, Data(String(repeating: value, count: 8192).utf8))
    }

    func testTimeoutRemainsFailureWhenTermHandlerExitsSuccessfully() throws {
        let runner = MediaProcessRunner()
        XCTAssertThrowsError(try runner.run(shell, arguments: ["-c", """
        trap 'exit 0' TERM
        while :; do :; done
        """], timeout: 0.15)) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"), error.localizedDescription)
        }
        // A timed-out child does not permanently stop an otherwise usable runner.
        let output = try runner.run(shell, arguments: ["-c", "printf 'next conversion'"])
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "next conversion")
    }

    func testTimeoutKillsAndReapsChildIgnoringTerm() throws {
        let pidFile = try fixtureDirectory().appendingPathComponent("child.pid")
        let runner = MediaProcessRunner()
        let started = Date()
        XCTAssertThrowsError(try runner.run(shell, arguments: ignoringTerm(pidFile), timeout: 0.15)) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"), error.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "SIGKILL must bound an ignored SIGTERM")
        try assertChildIsReaped(pidFile)
    }

    func testStopKillsIgnoringTermAndReturnsCancellation() throws {
        let pidFile = try fixtureDirectory().appendingPathComponent("child.pid")
        let runner = MediaProcessRunner()
        let arguments = ignoringTerm(pidFile)
        let finished = expectation(description: "Cancelled media process exits")
        DispatchQueue.global().async { [shell] in
            defer { finished.fulfill() }
            do {
                _ = try runner.run(shell, arguments: arguments, timeout: 5)
                XCTFail("A stopped media process must report cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError, error.localizedDescription)
            }
        }
        let readyDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path), "Child must install its TERM handler before cancellation")
        runner.stop()
        runner.stop()
        wait(for: [finished], timeout: 2)
        try assertChildIsReaped(pidFile)
        XCTAssertThrowsError(try runner.run(shell, arguments: ["-c", "exit 0"])) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testStopResumesSuspendedChildToHandleTerm() throws {
        let directory = try fixtureDirectory()
        let pidFile = directory.appendingPathComponent("child.pid")
        let termFile = directory.appendingPathComponent("handled-term")
        let runner = MediaProcessRunner()
        let finished = expectation(description: "Suspended media process handles termination")
        DispatchQueue.global().async { [shell] in
            defer { finished.fulfill() }
            do {
                _ = try runner.run(shell, arguments: ["-c", """
                trap 'printf terminated > "$2"; exit 0' TERM
                printf '%s' "$$" > "$1"
                while :; do :; done
                """, "velora-test", pidFile.path, termFile.path], timeout: 5)
                XCTFail("A stopped media process must report cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError, error.localizedDescription)
            }
        }
        let readyDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path))
        runner.setSuspended(true)
        Thread.sleep(forTimeInterval: 0.03)
        runner.stop()
        wait(for: [finished], timeout: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: termFile.path), "SIGCONT must let the suspended child handle SIGTERM")
        try assertChildIsReaped(pidFile)
    }

    func testSuspendedTimeDoesNotConsumeTimeout() throws {
        let pidFile = try fixtureDirectory().appendingPathComponent("child.pid")
        let runner = MediaProcessRunner()
        defer { runner.stop() }
        let finished = DispatchSemaphore(value: 0)
        let arguments = ignoringTerm(pidFile)
        DispatchQueue.global().async { [shell] in
            defer { finished.signal() }
            do {
                _ = try runner.run(shell, arguments: arguments, timeout: 0.2)
                XCTFail("The resumed process must eventually time out")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("timed out"), error.localizedDescription)
            }
        }
        let readyDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path))
        runner.setSuspended(true)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.4), .timedOut, "Suspension must pause the conversion timeout")
        runner.setSuspended(false)
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        try assertChildIsReaped(pidFile)
    }

    private func ignoringTerm(_ pidFile: URL) -> [String] {
        ["-c", """
        trap '' TERM
        printf '%s' "$$" > "$1"
        while :; do :; done
        """, "velora-test", pidFile.path]
    }

    private func assertChildIsReaped(_ pidFile: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try XCTUnwrap(pid_t(pidText), file: file, line: line)
        let result = kill(pid, 0), signalError = errno
        XCTAssertEqual(result, -1, "Child must be gone before run returns", file: file, line: line)
        XCTAssertEqual(signalError, ESRCH, "No live or zombie process should remain", file: file, line: line)
    }

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VeloraProcessTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
