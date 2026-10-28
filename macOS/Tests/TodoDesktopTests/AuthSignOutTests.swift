import Foundation
import XCTest
@testable import TodoDesktop

@MainActor
final class AuthSignOutTests: XCTestCase {
    func testDeletionFailureKeepsIdentityAndReportsError() throws {
        let suite = "TodoSignOutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = FeishuIdentity(userID: "user", tenantID: "tenant")
        defaults.set(try JSONEncoder().encode(identity), forKey: "TodoDesktop.auth.identity")
        defaults.set("Test", forKey: "TodoDesktop.auth.displayName")
        let coordinator = AuthCoordinator(defaults: defaults, deleteToken: { _ in throw KeychainStoreError(status: -128) })

        XCTAssertThrowsError(try coordinator.signOut())
        XCTAssertEqual(coordinator.currentIdentity, identity)
        XCTAssertEqual(coordinator.currentDisplayName, "Test")
    }

    func testSuccessfulDeletionClearsIdentity() throws {
        let suite = "TodoSignOutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = FeishuIdentity(userID: "user", tenantID: "tenant")
        defaults.set(try JSONEncoder().encode(identity), forKey: "TodoDesktop.auth.identity")
        var deletedKey: String?
        let coordinator = AuthCoordinator(defaults: defaults, deleteToken: { deletedKey = $0 })

        try coordinator.signOut()
        XCTAssertEqual(deletedKey, identity.storageKey)
        XCTAssertNil(coordinator.currentIdentity)
    }
}
