import Foundation
import XCTest
@testable import TodoDesktop

final class FeishuBitableClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testUpdateRecordSendsOnlyRequestedFieldAndDecodesUpdatedRecord() async throws {
        StubURLProtocol.handler = { request in
            let body = try Self.requestBodyData(from: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let fields = try XCTUnwrap(json["fields"] as? [String: String])
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-token")
            XCTAssertEqual(request.url?.path, "/open-apis/bitable/v1/apps/app-token/tables/table-id/records/record-id")
            XCTAssertEqual(fields, ["状态": "已完成"])
            return (200, #"{"code":0,"data":{"record":{"id":"record-id","fields":{"状态":"已完成"}}},"msg":"success"}"#)
        }

        let client = FeishuBitableClient(session: makeSession())
        let record = try await client.updateRecord(appToken: "app-token",
                                                   tableID: "table-id",
                                                   recordID: "record-id",
                                                   fields: ["状态": .string("已完成")],
                                                   accessToken: "user-token")

        XCTAssertEqual(record.id, "record-id")
        XCTAssertEqual(record.fields["状态"]?.text, "已完成")
    }

    func testGetRecordReadsOneRecordByID() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/open-apis/bitable/v1/apps/app-token/tables/table-id/records/record-id")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-token")
            return (200, #"{"code":0,"data":{"record":{"id":"record-id","fields":{"状态":"未完成"}}},"msg":"success"}"#)
        }

        let client = FeishuBitableClient(session: makeSession())
        let record = try await client.getRecord(appToken: "app-token",
                                                tableID: "table-id",
                                                recordID: "record-id",
                                                accessToken: "user-token")

        XCTAssertEqual(record.id, "record-id")
        XCTAssertEqual(record.fields["状态"]?.text, "未完成")
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func requestBodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
