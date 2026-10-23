import Foundation
import XCTest
@testable import TodoDesktop

final class BitableCompletionTests: XCTestCase {
    private var storageDirectory: URL!

    override func setUp() {
        storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TodoCompletionTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        CompletionURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: storageDirectory)
        super.tearDown()
    }

    func testSetCompletionWritesOnlyMappedStatusWithoutRefreshingTheWholeView() async throws {
        let fixture = try makeFixture()
        var methods: [String] = []
        CompletionURLProtocol.handler = { request in
            methods.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            switch (request.httpMethod, request.url?.path) {
            case ("PUT", "/open-apis/bitable/v1/apps/app-token/tables/table-id/records/record-id"):
                let body = try Self.bodyData(from: request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let fields = try XCTUnwrap(json["fields"] as? [String: String])
                XCTAssertEqual(fields, ["完成状态": "已完成"])
                return (200, Self.recordResponse(status: "已完成"))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return (500, #"{"code":1,"msg":"unexpected request"}"#)
            }
        }

        let result = try await fixture.service.setCompletion(binding: fixture.binding,
                                                             identity: fixture.identity,
                                                             recordID: "record-id",
                                                             isDone: true,
                                                             accessToken: "user-token")

        XCTAssertFalse(result.isStale)
        XCTAssertNil(result.warning)
        XCTAssertEqual(result.snapshot.items.map(\.isDone), [true])
        XCTAssertEqual(methods, ["PUT /open-apis/bitable/v1/apps/app-token/tables/table-id/records/record-id"])
    }

    func testSnapshotRepositoryReadsBackItsISO8601FetchDate() throws {
        let identity = FeishuIdentity(userID: "user", tenantID: "tenant")
        let repository = SnapshotRepository(rootDirectory: storageDirectory)
        let timestamp = Date(timeIntervalSince1970: 1_792_108_800)
        let expected = ViewSnapshot(fetchedAt: timestamp,
                                    items: [ProjectedTodo(id: "record-id",
                                                          title: "Task",
                                                          priority: nil,
                                                          isDone: false,
                                                          dateMilliseconds: 1_792_108_800_000,
                                                          sourceOrder: 0)])

        try repository.save(expected, identity: identity, bindingID: "binding-id")
        let actual = try XCTUnwrap(repository.load(identity: identity, bindingID: "binding-id"))

        XCTAssertEqual(actual.fetchedAt, timestamp)
        XCTAssertEqual(actual.items.map(\.id), ["record-id"])
    }

    func testRefreshUsesCachedFieldNamesAndOnlyReadsViewRecords() async throws {
        let fixture = try makeFixture()
        var methods: [String] = []
        CompletionURLProtocol.handler = { request in
            methods.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            guard request.httpMethod == "GET",
                  request.url?.path == "/open-apis/bitable/v1/apps/app-token/tables/table-id/records" else {
                XCTFail("Refresh should not reload field or view metadata.")
                return (500, #"{"code":1,"msg":"unexpected metadata request"}"#)
            }
            return (200, Self.recordsResponse(status: "未完成"))
        }

        _ = try await fixture.service.refresh(binding: fixture.binding,
                                              identity: fixture.identity,
                                              accessToken: "user-token")

        XCTAssertEqual(methods, ["GET /open-apis/bitable/v1/apps/app-token/tables/table-id/records"])
    }

    func testLegacyBindingLoadsMetadataOnceAndPersistsFieldNames() async throws {
        let fixture = try makeFixture()
        var binding = fixture.binding
        binding.fieldMapping = FieldMapping(taskFieldID: "task-id",
                                            dateFieldID: "date-id",
                                            priorityFieldID: "priority-id",
                                            doneFieldID: "done-id",
                                            doneOptionID: "done-option",
                                            doneOptionName: "已完成",
                                            undoneOptionID: "undone-option",
                                            undoneOptionName: "未完成")
        let workspaceRepository = WorkspaceRepository(rootDirectory: storageDirectory.appendingPathComponent("workspaces"))
        try workspaceRepository.save(AccountWorkspace(identity: fixture.identity, bindings: [binding]))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletionURLProtocol.self]
        let service = BitableBindingService(client: FeishuBitableClient(session: URLSession(configuration: configuration)),
                                            workspaceRepository: workspaceRepository,
                                            snapshotRepository: SnapshotRepository(rootDirectory: storageDirectory.appendingPathComponent("snapshots")))
        var methods: [String] = []
        CompletionURLProtocol.handler = { request in
            methods.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/open-apis/bitable/v1/apps/app-token/tables/table-id/fields"):
                return (200, Self.fieldsResponse)
            case ("GET", "/open-apis/bitable/v1/apps/app-token/tables/table-id/records"):
                return (200, Self.recordsResponse(status: "未完成"))
            default:
                XCTFail("Legacy metadata migration should not request view details.")
                return (500, #"{"code":1,"msg":"unexpected request"}"#)
            }
        }

        _ = try await service.refresh(binding: binding,
                                      identity: fixture.identity,
                                      accessToken: "user-token")
        let storedMapping = try XCTUnwrap(workspaceRepository.load(for: fixture.identity).bindings.first?.fieldMapping)

        XCTAssertEqual(storedMapping.taskFieldName, "任务内容")
        XCTAssertEqual(storedMapping.doneFieldName, "完成状态")
        XCTAssertEqual(methods, [
            "GET /open-apis/bitable/v1/apps/app-token/tables/table-id/fields",
            "GET /open-apis/bitable/v1/apps/app-token/tables/table-id/records"
        ])
    }

    func testCreateBindingUsesInspectionMetadataAndOnlyFetchesRecords() async throws {
        let fixture = try makeFixture()
        let link = ParsedViewLink(kind: .base,
                                  resourceToken: fixture.binding.resourceToken,
                                  tableID: fixture.binding.tableID,
                                  viewID: fixture.binding.viewID,
                                  sourceURL: fixture.binding.sourceURL)
        let fields = [
            BitableField(id: "task-id", name: "任务内容", type: 1, property: nil),
            BitableField(id: "date-id", name: "所属日期", type: 5, property: nil),
            BitableField(id: "priority-id", name: "优先级", type: 3, property: nil),
            BitableField(id: "done-id", name: "完成状态", type: 3,
                         property: BitableFieldProperty(options: [
                            BitableOption(id: "done-option", name: "已完成"),
                            BitableOption(id: "undone-option", name: "未完成")
                         ]))
        ]
        let inspection = BindingInspection(link: link,
                                           view: BitableView(id: "view-id", name: "Today"),
                                           fields: fields)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletionURLProtocol.self]
        let client = FeishuBitableClient(session: URLSession(configuration: configuration))
        let service = BitableBindingService(client: client,
                                            workspaceRepository: WorkspaceRepository(rootDirectory: storageDirectory.appendingPathComponent("workspaces")),
                                            snapshotRepository: SnapshotRepository(rootDirectory: storageDirectory.appendingPathComponent("snapshots")))
        var methods: [String] = []
        CompletionURLProtocol.handler = { request in
            methods.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            guard request.httpMethod == "GET",
                  request.url?.path == "/open-apis/bitable/v1/apps/app-token/tables/table-id/records" else {
                XCTFail("Creating a binding should reuse inspected view and field metadata.")
                return (500, #"{"code":1,"msg":"unexpected metadata request"}"#)
            }
            return (200, Self.recordsResponse(status: "未完成"))
        }

        let (_, snapshot) = try await service.createBinding(inspection: inspection,
                                                            fieldMapping: try XCTUnwrap(fixture.binding.fieldMapping),
                                                            identity: fixture.identity,
                                                            accessToken: "user-token")

        XCTAssertEqual(snapshot.items.map(\.title), ["Task"])
        XCTAssertEqual(methods, ["GET /open-apis/bitable/v1/apps/app-token/tables/table-id/records"])
    }

    func testSetCompletionVerifiesAmbiguousWriteWithoutRepeatingTheUpdate() async throws {
        let fixture = try makeFixture()
        var status = "未完成"
        var updateCount = 0
        CompletionURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("PUT", "/open-apis/bitable/v1/apps/app-token/tables/table-id/records/record-id"):
                updateCount += 1
                status = "已完成"
                return (500, #"{"code":9999,"msg":"connection closed after processing"}"#)
            case ("GET", "/open-apis/bitable/v1/apps/app-token/tables/table-id/records/record-id"):
                return (200, Self.recordResponse(status: status))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return (500, #"{"code":1,"msg":"unexpected request"}"#)
            }
        }

        let result = try await fixture.service.setCompletion(binding: fixture.binding,
                                                             identity: fixture.identity,
                                                             recordID: "record-id",
                                                             isDone: true,
                                                             accessToken: "user-token")

        XCTAssertEqual(updateCount, 1)
        XCTAssertFalse(result.isStale)
        XCTAssertEqual(result.snapshot.items.map(\.isDone), [true])
    }

    func testConfirmedWriteDoesNotWaitForFollowUpViewRefresh() async throws {
        let fixture = try makeFixture()
        var methods: [String] = []
        CompletionURLProtocol.handler = { request in
            methods.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            switch (request.httpMethod, request.url?.path) {
            case ("PUT", "/open-apis/bitable/v1/apps/app-token/tables/table-id/records/record-id"):
                return (200, Self.recordResponse(status: "已完成"))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return (500, #"{"code":1,"msg":"unexpected request"}"#)
            }
        }

        let result = try await fixture.service.setCompletion(binding: fixture.binding,
                                                             identity: fixture.identity,
                                                             recordID: "record-id",
                                                             isDone: true,
                                                             accessToken: "user-token")

        XCTAssertFalse(result.isStale)
        XCTAssertNil(result.warning)
        XCTAssertEqual(result.snapshot.items.map(\.isDone), [true])
        XCTAssertEqual(methods, ["PUT /open-apis/bitable/v1/apps/app-token/tables/table-id/records/record-id"])
    }

    func testRejectedWriteIsNotReportedAsSuccessful() async throws {
        let fixture = try makeFixture()
        CompletionURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("PUT", "/open-apis/bitable/v1/apps/app-token/tables/table-id/records/record-id"):
                return (400, #"{"code":1254001,"msg":"WrongRequestBody"}"#)
            case ("GET", "/open-apis/bitable/v1/apps/app-token/tables/table-id/records/record-id"):
                return (200, Self.recordResponse(status: "未完成"))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return (500, #"{"code":1,"msg":"unexpected request"}"#)
            }
        }

        do {
            _ = try await fixture.service.setCompletion(binding: fixture.binding,
                                                        identity: fixture.identity,
                                                        recordID: "record-id",
                                                        isDone: true,
                                                        accessToken: "user-token")
            XCTFail("A rejected write must not be reported as successful.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("仍为“未完成”"))
        }
    }

    private func makeFixture() throws -> (service: BitableBindingService, binding: ViewBinding, identity: FeishuIdentity) {
        let identity = FeishuIdentity(userID: "user", tenantID: "tenant")
        let link = ParsedViewLink(kind: .base,
                                  resourceToken: "app-token",
                                  tableID: "table-id",
                                  viewID: "view-id",
                                  sourceURL: URL(string: "https://example.feishu.cn/base/app-token?table=table-id&view=view-id")!)
        let mapping = FieldMapping(taskFieldID: "task-id",
                                   dateFieldID: "date-id",
                                   priorityFieldID: "priority-id",
                                   doneFieldID: "done-id",
                                   doneOptionID: "done-option",
                                   doneOptionName: "已完成",
                                   undoneOptionID: "undone-option",
                                   undoneOptionName: "未完成",
                                   taskFieldName: "任务内容",
                                   dateFieldName: "所属日期",
                                   priorityFieldName: "优先级",
                                   doneFieldName: "完成状态",
                                   plannedDurationFieldChecked: true)
        let binding = ViewBinding(link: link, identity: identity, fieldMapping: mapping, viewName: "Today")
        let snapshotRepository = SnapshotRepository(rootDirectory: storageDirectory)
        try snapshotRepository.save(ViewSnapshot(fetchedAt: Date(),
                                                 items: [ProjectedTodo(id: "record-id",
                                                                       title: "Task",
                                                                       priority: "高",
                                                                       isDone: false,
                                                                       dateMilliseconds: 1_792_108_800_000,
                                                                       sourceOrder: 0)]),
                                   identity: identity,
                                   bindingID: binding.id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletionURLProtocol.self]
        let client = FeishuBitableClient(session: URLSession(configuration: configuration))
        let service = BitableBindingService(client: client,
                                            snapshotRepository: snapshotRepository)
        return (service, binding, identity)
    }

    private static let fieldsResponse = #"{"code":0,"data":{"items":[{"field_id":"task-id","field_name":"任务内容","type":1},{"field_id":"date-id","field_name":"所属日期","type":5},{"field_id":"priority-id","field_name":"优先级","type":3,"property":{"options":[{"id":"high","name":"高"}]}},{"field_id":"done-id","field_name":"完成状态","type":3,"property":{"options":[{"id":"done-option","name":"已完成"},{"id":"undone-option","name":"未完成"}]}}],"has_more":false},"msg":"success"}"#

    private static func recordResponse(status: String) -> String {
        #"{"code":0,"data":{"record":{"id":"record-id","fields":{"完成状态":"\#(status)"}}},"msg":"success"}"#
    }

    private static func recordsResponse(status: String) -> String {
        #"{"code":0,"data":{"items":[{"id":"record-id","fields":{"任务内容":"Task","所属日期":1792108800000,"优先级":"高","完成状态":"\#(status)"}}],"has_more":false},"msg":"success"}"#
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
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

private final class CompletionURLProtocol: URLProtocol {
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
