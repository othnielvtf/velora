import XCTest
@testable import VeloraCore

final class EncoderGateTests: XCTestCase {
    func testCancelledQueuedWaiterDoesNotTakeSurvivingWaitersCapacity() async {
        let gate = EncoderGate()
        let first = await gate.acquire(), second = await gate.acquire()
        XCTAssertTrue(first); XCTAssertTrue(second)
        let cancelled = expectation(description: "Cancelled queued encoder leaves the gate")
        let survivor = expectation(description: "Surviving queued encoder receives released capacity")
        let abandoned = Task {
            let acquired = await gate.acquire()
            XCTAssertFalse(acquired)
            cancelled.fulfill()
        }
        let waiting = Task {
            let acquired = await gate.acquire()
            XCTAssertTrue(acquired)
            if acquired { await gate.release() }
            survivor.fulfill()
        }
        try? await Task.sleep(for: .milliseconds(30))
        abandoned.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        await gate.release()
        await fulfillment(of: [survivor], timeout: 1)
        await gate.stop()
        _ = await abandoned.value; _ = await waiting.value
    }

    func testEachReleaseTransfersOnlyOneOfTwoSharedSlots() async {
        let gate = EncoderGate(), grants = Grants()
        let first = await gate.acquire(), second = await gate.acquire()
        XCTAssertTrue(first); XCTAssertTrue(second)
        let firstGrant = expectation(description: "First released slot")
        let secondGrant = expectation(description: "Second released slot")
        let tasks = (0..<2).map { _ in
            Task {
                let acquired = await gate.acquire()
                XCTAssertTrue(acquired)
                if await grants.record() == 1 { firstGrant.fulfill() }
                else { secondGrant.fulfill() }
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        let initialCount = await grants.count
        XCTAssertEqual(initialCount, 0, "Two active encoders must keep other jobs queued")
        await gate.release()
        await fulfillment(of: [firstGrant], timeout: 1)
        try? await Task.sleep(for: .milliseconds(20))
        let singleReleaseCount = await grants.count
        XCTAssertEqual(singleReleaseCount, 1)
        await gate.release()
        await fulfillment(of: [secondGrant], timeout: 1)
        let bothReleaseCount = await grants.count
        XCTAssertEqual(bothReleaseCount, 2)
        await gate.stop()
        for task in tasks { _ = await task.value }
    }

    private actor Grants {
        private(set) var count = 0
        func record() -> Int { count += 1; return count }
    }
}
