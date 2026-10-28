import XCTest
@testable import TodoDesktop

@MainActor
final class SnapshotRefreshCoordinatorTests: XCTestCase {
    func testConcurrentRequestsShareOneTaskAndDifferentBindingsRemainIndependent() async throws {
        let coordinator = SnapshotRefreshCoordinator<Int>()
        var calls = 0
        var release: CheckedContinuation<Int, Error>?
        let started = expectation(description: "first refresh started")
        let first = Task { try await coordinator.run(key: "a") {
            calls += 1
            return try await withCheckedThrowingContinuation { continuation in
                release = continuation
                started.fulfill()
            }
        } }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { try await coordinator.run(key: "a") { calls += 1; return 99 } }
        let other = Task { try await coordinator.run(key: "b") { calls += 1; return 2 } }
        let otherValue = try await other.value
        XCTAssertEqual(otherValue, 2)
        await Task.yield()
        release?.resume(returning: 1)
        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(secondValue, 1)
        XCTAssertEqual(calls, 2)
    }

    func testFailureClearsTaskForRetry() async throws {
        let coordinator = SnapshotRefreshCoordinator<Int>()
        enum Failure: Error { case failed }
        do {
            _ = try await coordinator.run(key: "a") { throw Failure.failed }
            XCTFail("Expected failure")
        } catch Failure.failed {}
        let retry = try await coordinator.run(key: "a") { 42 }
        XCTAssertEqual(retry, 42)
    }
}
