import XCTest
@testable import TodoDesktop

final class SnapshotRefreshAdmissionTests: XCTestCase {
    func testRefreshRejectedDuringMutationDoesNotMarkSnapshotStale() {
        var staleBindings = Set<String>()

        let admitted = SnapshotRefreshAdmission.begin(
            bindingID: "binding-1",
            hasActiveMutation: true,
            markStale: { staleBindings.insert($0) }
        )

        XCTAssertFalse(admitted)
        XCTAssertTrue(staleBindings.isEmpty)
    }

    func testAdmittedRefreshMarksSnapshotStaleBeforeNetworkRequest() {
        var staleBindings = Set<String>()

        let admitted = SnapshotRefreshAdmission.begin(
            bindingID: "binding-1",
            hasActiveMutation: false,
            markStale: { staleBindings.insert($0) }
        )

        XCTAssertTrue(admitted)
        XCTAssertEqual(staleBindings, ["binding-1"])
    }
}
