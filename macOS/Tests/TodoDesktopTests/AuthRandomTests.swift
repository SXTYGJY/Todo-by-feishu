import XCTest
@testable import TodoDesktop

@MainActor
final class AuthRandomTests: XCTestCase {
    func testRandomGenerationFailureStopsAuthorization() {
        XCTAssertThrowsError(try AuthCoordinator.randomURLSafeString(byteCount: 32, fill: { _, _ in -1 })) { error in
            XCTAssertEqual(error.localizedDescription, "无法生成安全授权信息，请稍后重试。")
        }
    }

    func testRandomGenerationEncodesBytesAsURLSafeString() throws {
        let value = try AuthCoordinator.randomURLSafeString(byteCount: 3, fill: { _, bytes in
            bytes.storeBytes(of: UInt8(0xfb), toByteOffset: 0, as: UInt8.self)
            bytes.storeBytes(of: UInt8(0xff), toByteOffset: 1, as: UInt8.self)
            bytes.storeBytes(of: UInt8(0xff), toByteOffset: 2, as: UInt8.self)
            return 0
        })
        XCTAssertEqual(value, "-___")
    }
}
